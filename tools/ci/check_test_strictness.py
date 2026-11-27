#!/usr/bin/env python3
"""Find review-worthy changes to test checks and fixtures in a Git diff."""

from __future__ import annotations

import argparse
from collections import Counter, defaultdict
from dataclasses import dataclass
from decimal import Decimal
from difflib import SequenceMatcher
import os
from pathlib import Path, PurePosixPath
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]
LITERAL_OR_COMMENT = re.compile(
    r'"""[\s\S]*?"""|\'\'\'[\s\S]*?\'\'\'|/\*[\s\S]*?\*/'
    r'|"(?:\\.|[^"\\\n])*"|\'(?:\\.|[^\'\\\n])*\'|(?P<comment>//[^\n]*|\#[^\n]*)'
)
ASSERTION = re.compile(
    r"\b(?:_?(?:assert(?:[A-Z]\w*|_\w+)?|expect(?:_\w+)?)|static_assert|(?:ASSERT|REQUIRE|CHECK)(?:_\w+)?)\s*\("
)
DEFINITION = re.compile(r"\b(?:func|def|void|bool)\s+$")
NUMBER = (
    r"[+-]?(?:0[xX][0-9a-fA-F_]+|(?:[0-9][0-9_]*(?:\.[0-9_]*)?|\.[0-9][0-9_]*)(?:[eE][+-]?[0-9_]+)?)"
    r"(?:[fF]|[uUlL]+)?(?![\w.])"
)
ASSIGNMENT = re.compile(
    rf"\b(?P<key>[a-zA-Z_]\w*)\s*(?::\s*[\w.\[\]]+\s*)?:?=(?!=)\s*"
    rf"(?:Time\.get_ticks_(?P<clock>msec|usec)\(\)\s*\+\s*"
    rf"|std::chrono::(?P<duration>microseconds|milliseconds|seconds)\()?"
    rf"(?P<value>{NUMBER})"
)
SEED_CALL = re.compile(rf"\b(?P<key>seed|generate_world|srand|manual_seed)\s*\(\s*(?P<value>{NUMBER})")
ABS_LIMIT = re.compile(rf"\b(?:abs|absf|fabs)\s*\([^()]*\)\s*<=?\s*(?P<value>{NUMBER})")
RETRY_CALL = re.compile(r"\b(?:retry|rerun|retrying|Retry)\s*\(")
RETRY_LOOP = re.compile(rf"\bfor\s+_?(?:attempt|retry)\s+in\s+range\(\s*(?P<value>{NUMBER})\s*\)")
RETRY_SWITCH = re.compile(r"\b(?P<key>\w+)\s*:?=(?!=)\s*(?P<value>true|false|True|False)\b")
MARKER = re.compile(r"\s*test-guard\[(assertion|seed|timeout|tolerance|retry)\]:\s*(\S.*)")
TO_MILLISECONDS = {"seconds": 1000, "microseconds": Decimal("0.001"), "usec": Decimal("0.001")}


@dataclass(frozen=True)
class Line:
    code: str
    marker: tuple[str, str] | None


def _source_lines(raw: list[str]) -> list[Line]:
    source = "\n".join(raw)
    masked = []
    markers = {}
    end = 0
    for token in LITERAL_OR_COMMENT.finditer(source):
        masked.append(source[end:token.start()])
        if token["comment"]:
            marker = MARKER.fullmatch(token["comment"].lstrip("/#").rstrip())
            if marker:
                markers[source.count("\n", 0, token.start())] = marker.groups()
        masked.append(re.sub(r"[^\n]", " ", token.group()))
        end = token.end()
    masked.append(source[end:])
    lines = "".join(masked).split("\n")
    return [Line(lines[i], markers.get(i)) for i in range(len(raw))]


def _assertions(lines: list[Line], raw: list[str], start: int, end: int):
    for index in range(start, end):
        code = lines[index].code
        if re.match(r"\s*assert\s+(?!\()\S", code):
            if not re.fullmatch(r"\s*assert\s+(?:True|true)\s*", code):
                yield index, "assert", raw[index].strip()
        for claim in ASSERTION.finditer(code):
            if DEFINITION.search(code[:claim.start()]):
                continue
            # Use the full argument list to recognize a moved multiline assertion.
            depth = 1
            signature = []
            arguments = []
            for followup in range(index, len(lines)):
                begin = claim.end() if followup == index else 0
                characters = lines[followup].code[begin:]
                for offset, character in enumerate(characters, begin):
                    if character == "(":
                        depth += 1
                    elif character == ")":
                        depth -= 1
                        if depth == 0:
                            signature.append(raw[followup][begin:offset].strip())
                            arguments.append(lines[followup].code[begin:offset].strip())
                            break
                else:
                    signature.append(raw[followup][begin:].strip())
                    arguments.append(lines[followup].code[begin:].strip())
                    continue
                break
            name = claim.group().split("(")[0].strip()
            condition = " ".join(arguments).strip()
            always_true = re.fullmatch(r"(?:true|True)", condition) and name in {"assert", "assertTrue", "CHECK", "REQUIRE"}
            always_expected = re.fullmatch(r",\s*(?:true|True)", condition) and name in {"_expect", "expect"}
            if always_true or always_expected:
                continue
            yield index, name, " ".join(signature)


def _number(value: str) -> Decimal:
    value = value.replace("_", "").rstrip("uUlL")
    return Decimal(int(value, 16)) if value.lower().lstrip("+-").startswith("0x") else Decimal(value.rstrip("fF"))


def _setting_kind(key: str) -> str | None:
    name = re.sub(r"(?<=[a-z])(?=[A-Z])", "_", key).lower().strip("_")
    words = set(name.split("_"))
    if name == "seed" or name.endswith("_seed"):
        return "seed"
    if words & {"timeout", "deadline"}:
        return "timeout"
    if words & {"epsilon", "tolerance"} or name in {"delta", "abs_tol", "rel_tol", "atol", "rtol", "places"}:
        return "tolerance"
    if words & {"retry", "retries"} or name in {"attempts", "max_attempts"}:
        return "retry"
    return None


def _settings(lines: list[Line], start: int, end: int):
    settings = defaultdict(list)
    for index in range(start, end):
        code = lines[index].code
        for assignment in ASSIGNMENT.finditer(code):
            key, value = assignment.group("key", "value")
            kind = _setting_kind(key)
            if kind:
                amount = _number(value)
                if key == "places":
                    amount = -amount
                elif key in {"attempts", "max_attempts"}:
                    amount -= 1
                elif kind == "timeout":
                    amount *= TO_MILLISECONDS.get(assignment["duration"] or assignment["clock"], 1)
                settings[kind, key].append((index, amount))
        for switch in RETRY_SWITCH.finditer(code):
            key, value = switch.group("key", "value")
            if _setting_kind(key) == "retry":
                settings["retry", key].append((index, Decimal(value.lower() == "true")))
        for pattern, kind, default_key in (
            (SEED_CALL, "seed", ""), (ABS_LIMIT, "tolerance", "abs comparison"),
            (RETRY_LOOP, "retry", "attempt loop"),
        ):
            for match in pattern.finditer(code):
                key = match.groupdict().get("key", default_key)
                amount = _number(match["value"]) - (1 if kind == "retry" else 0)
                settings[kind, key].append((index, amount))
        for retry in RETRY_CALL.finditer(code):
            if not DEFINITION.search(code[:retry.start()]):
                settings["retry", "retry call"].append((index, Decimal(1)))
    return settings


def _has_marker(markers: dict[int, str], index: int, kind: str) -> bool:
    return kind in (markers.get(index), markers.get(index - 1))


def validate_test_diff(before: str, after: str) -> list[tuple[int, str]]:
    """Return review-worthy edits as (new line number, explanation)."""
    old_raw, new_raw = before.splitlines(), after.splitlines()
    old, new = _source_lines(old_raw), _source_lines(new_raw)
    edits = [(a, b, c, d) for tag, a, b, c, d in SequenceMatcher(
        None, old_raw, new_raw, autojunk=False).get_opcodes() if tag != "equal"]
    old_markers = Counter(line.marker for line in old if line.marker)
    markers = {}
    for index, line in enumerate(new):
        if line.marker:
            if old_markers[line.marker]:
                old_markers[line.marker] -= 1
            else:
                markers[index] = line.marker[0]
    removed = list(_assertions(old, old_raw, 0, len(old)))
    added = list(_assertions(new, new_raw, 0, len(new)))
    remaining = Counter((name, args) for _, name, args in removed)
    replacements = Counter((name, args) for _, name, args in added)
    remaining, replacements = remaining - replacements, replacements - remaining
    findings = []

    for a, b, c, d in edits:
        removed_here = []
        for index, name, args in removed:
            if a <= index < b and remaining[name, args]:
                remaining[name, args] -= 1
                removed_here.append((index, name))
        replacement_count = 0
        for index, name, args in added:
            if c <= index < d and replacements[name, args]:
                replacements[name, args] -= 1
                replacement_count += 1
        if not _has_marker(markers, c, "assertion"):
            for index, name in removed_here[replacement_count:]:
                findings.append((c + 1, f"removed assertion {name} (old line {index + 1})"))

        previous = _settings(old, a, b)
        for (kind, key), values in _settings(new, c, d).items():
            old_values = previous[kind, key]
            for offset, (index, amount) in enumerate(values):
                prior = old_values[offset][1] if offset < len(old_values) else None
                if kind == "retry":
                    flagged = amount > (prior if prior is not None else 0)
                else:
                    flagged = prior is not None and (amount != prior if kind == "seed" else amount > prior)
                if flagged and not _has_marker(markers, index, kind):
                    detail = f"{prior} -> {amount}" if prior is not None else str(amount)
                    findings.append((index + 1, f"{kind} change in {key}: {detail}"))
    return sorted(findings)


def _test_file(path: str) -> bool:
    parts = PurePosixPath(path).parts
    name = parts[-1]
    return PurePosixPath(path).suffix in {".gd", ".cpp", ".h", ".inc", ".py"} and (
        "tests" in parts[:-1] or name.startswith("test_")
        or re.search(r"_(?:self_?)?tests?(?:_|\.)", name) is not None
    )


def _git(root: Path, *args: str) -> str:
    return subprocess.check_output(["git", *args], cwd=root, text=True, encoding="utf-8")


def _file_diffs(root: Path, base: str):
    entries = iter(_git(root, "diff", "--name-status", "-z", "--find-renames", base, "--").split("\0")[:-1])
    for status in entries:
        old = next(entries)
        new = next(entries) if status.startswith("R") else old
        if not (_test_file(old) or _test_file(new)):
            continue
        before = "" if status == "A" else _git(root, "show", f"{base}:{old}")
        if status == "D":
            after = ""
        elif (root / new).is_file():
            after = (root / new).read_text(encoding="utf-8")
        else:  # The CI checkout may omit the test's directory.
            after = _git(root, "show", f":{new}")
        yield new, before, after


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", default=os.getenv("KEYNES_GUARD_BASE_REF"), help="Git commit to compare against")
    args = parser.parse_args()
    try:
        base = (_git(ROOT, "rev-parse", "--verify", "--end-of-options", f"{args.base}^{{commit}}") if args.base else
                _git(ROOT, "merge-base", "HEAD", "origin/master")).strip()
        count = 0
        for path, before, after in _file_diffs(ROOT, base):
            for line, explanation in validate_test_diff(before, after):
                print(f"{path}:{line}: {explanation}")
                count += 1
    except (OSError, UnicodeError, subprocess.CalledProcessError) as error:
        print(f"test strictness: cannot read the test diff: {error}")
        return 1
    print(f"test strictness: {count} unmarked change(s) against {base[:12]}")
    return bool(count)


if __name__ == "__main__":
    raise SystemExit(main())
