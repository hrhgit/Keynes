#!/usr/bin/env python3
"""Find review-worthy changes to test checks and fixtures in a Git diff."""

from __future__ import annotations

import argparse
import ast
from collections import Counter, defaultdict
from dataclasses import dataclass
from decimal import Decimal
from difflib import SequenceMatcher
import os
import operator
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
NAME = r"[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*"
EXPRESSION_TOKEN = re.compile(rf"\s*(?:{NUMBER}|{NAME}|[()+*/-])")
ASSIGNMENT = re.compile(
    rf"\b(?P<key>[a-zA-Z_]\w*)\s*(?::\s*[\w.\[\]]+\s*)?:?=(?!=)\s*"
    rf"(?:Time\.get_ticks_(?P<clock>msec|usec)\(\)\s*\+\s*"
    rf"|std::chrono::(?P<duration>microseconds|milliseconds|seconds)\()?"
)
SEED_CALL = re.compile(r"\b(?P<key>seed|generate_world|srand|manual_seed)\s*\(\s*")
ABS_LIMIT = re.compile(r"\b(?:abs|absf|fabs)\s*\([^()]*\)\s*<=?\s*")
RETRY_CALL = re.compile(r"\b(?:retry|rerun|retrying|Retry)\s*\(")
RETRY_LOOP = re.compile(rf"\bfor\s+_?(?:attempt|retry)\s+in\s+range\(\s*(?P<value>{NUMBER})\s*\)")
RETRY_SWITCH = re.compile(r"\b(?P<key>\w+)\s*:?=(?!=)\s*(?P<value>true|false|True|False)\b")
MARKER = re.compile(r"\s*test-guard\[(assertion|seed|timeout|tolerance|retry)\]:\s*(\S.*)")
TO_MILLISECONDS = {"seconds": 1000, "microseconds": Decimal("0.001"), "usec": Decimal("0.001")}
FALSE_BRANCH = re.compile(
    r"^\s*if\s*(?:constexpr\s*)?\(\s*(?:[Ff]alse|0)\s*\)\s*(?P<braced>.*)$"
    r"|^\s*if\s+(?:[Ff]alse|0)\s*(?P<indented>:.*)$"
)
COMPARISON = re.compile(rf"^\s*(?:,\s*)?(?P<left>{NAME})\s*(?P<op>==|<=|>=|<|>)\s*(?P<right>{NUMBER})\s*(?:,.*)?$")
SELF_COMPARISON = re.compile(rf"^(?:,\s*)?(?P<actual>{NAME})\s*==\s*(?P=actual)\s*(?:,.*)?$")
SELF_EQUAL = re.compile(rf"^(?P<actual>{NAME})\s*,\s*(?P=actual)\s*(?:,.*)?$")
ARITHMETIC_OPERATORS = {ast.Add: operator.add, ast.Sub: operator.sub, ast.Mult: operator.mul, ast.Div: operator.truediv}


@dataclass(frozen=True)
class Line:
    code: str
    marker: tuple[str, str] | None


@dataclass(frozen=True)
class Assertion:
    start: int
    end: int
    name: str
    signature: str
    condition: str

    @property
    def identity(self) -> tuple[str, str]:
        return self.name, self.signature

    def touches(self, start: int, end: int) -> bool:
        return self.start < end and self.end >= start


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


def _braced_prefix(code: str, depth: int) -> tuple[int, int]:
    for brace in re.finditer(r"[{}]", code):
        depth += 1 if brace[0] == "{" else -1
        if not depth:
            return brace.end(), depth  # Any code after the brace remains reachable.
    return len(code), depth


def _disabled_lines(lines: list[Line]) -> dict[int, int]:
    """Find the disabled prefix of each affected line for literal-false branches."""
    disabled = {}
    indentation = None
    braces = 0
    next_statement = False
    for index, line in enumerate(lines):
        code = line.code
        if not code.strip():
            continue
        indent = len(code) - len(code.lstrip())
        if indentation is not None and indent <= indentation:
            indentation = None
        if braces or indentation is not None or next_statement:
            if braces or (next_statement and code.lstrip().startswith("{")):
                disabled[index], braces = _braced_prefix(code, braces)
            else:
                disabled[index] = len(code)
            next_statement = False
            continue
        branch = FALSE_BRANCH.match(code)
        if branch:
            disabled[index] = len(code)
            body = branch["indented"] or branch["braced"]
            if body.startswith(":"):
                if not body[1:].strip():
                    indentation = indent
            elif body.startswith("{"):
                end, braces = _braced_prefix(body, 0)
                disabled[index] = branch.start("braced") + end
            elif not body:
                next_statement = True
    return disabled


def _assertions(lines: list[Line], raw: list[str], disabled: dict[int, int]):
    for index, line in enumerate(lines):
        prefix = disabled.get(index, 0)
        code = " " * prefix + line.code[prefix:]
        bare = re.match(r"\s*assert\s+(?!\()(\S.*)", code)
        if bare and not re.match(r"\s*(?:true|True)(?:\s*,|\s*$)", bare[1]) and not SELF_COMPARISON.fullmatch(bare[1]):
            yield Assertion(index, index, "assert", raw[index].strip(), bare[1].strip())
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
            compares_itself = (
                name in {"assert", "assertTrue", "CHECK", "REQUIRE", "_expect", "expect"}
                and SELF_COMPARISON.fullmatch(condition)
            ) or (
                name in {"assertEqual", "assertAlmostEqual", "ASSERT_EQ", "CHECK_EQ", "REQUIRE_EQ"}
                and SELF_EQUAL.fullmatch(condition)
            )
            if always_true or always_expected or compares_itself:
                continue
            yield Assertion(index, followup, name, " ".join(signature), condition)


def _number(value: str) -> Decimal:
    value = value.replace("_", "").rstrip("uUlL")
    return Decimal(int(value, 16)) if value.lower().lstrip("+-").startswith("0x") else Decimal(value.rstrip("fF"))


def _wider_comparison(before: Assertion, after: Assertion) -> bool:
    old, new = COMPARISON.fullmatch(before.condition), COMPARISON.fullmatch(after.condition)
    if not old or not new or old["left"] != new["left"] or new["op"] == "==":
        return False
    prior, limit = _number(old["right"]), _number(new["right"])
    old_op, new_op = old["op"], new["op"]
    if old_op == "==":
        return {"<": operator.lt, "<=": operator.le, ">": operator.gt, ">=": operator.ge}[new_op](prior, limit)
    if old_op[0] != new_op[0]:
        return False
    return (limit > prior if new_op[0] == "<" else limit < prior) or (
        limit == prior and len(new_op) > len(old_op)
    )


def _constant_value(value: str, constants: dict[str, Decimal]) -> Decimal | None:
    if re.fullmatch(NUMBER, value):
        return _number(value)
    # Parsing an expression does not execute it. Accept only numeric literals,
    # previously defined constants, and the four arithmetic operations.
    def evaluate(node: ast.expr) -> Decimal:
        if isinstance(node, ast.Constant) and type(node.value) in (int, float):
            return Decimal(str(node.value))
        if isinstance(node, ast.Name):
            return constants[node.id]
        if isinstance(node, ast.UnaryOp) and isinstance(node.op, (ast.UAdd, ast.USub)):
            result = evaluate(node.operand)
            return -result if isinstance(node.op, ast.USub) else result
        if isinstance(node, ast.BinOp) and type(node.op) in ARITHMETIC_OPERATORS:
            return ARITHMETIC_OPERATORS[type(node.op)](evaluate(node.left), evaluate(node.right))
        raise ValueError("not a constant numeric expression")

    # Bring C++ literal suffixes into the expression grammar without touching
    # operators, constant names, or trailing F characters in hexadecimal values.
    def without_suffix(match: re.Match) -> str:
        literal = match[0].rstrip("uUlL")
        return literal if literal.lower().lstrip("+-").startswith("0x") else literal.rstrip("fF")

    try:
        expression = re.sub(rf"(?<![\w.]){NUMBER}", without_suffix, value)
        return evaluate(ast.parse(expression, mode="eval").body)
    except (ArithmeticError, KeyError, SyntaxError, ValueError):
        return None


def _expression_at(line: str, start: int) -> str:
    """Read the right-hand side up to the enclosing delimiter."""
    end = start
    depth = 0
    while token := EXPRESSION_TOKEN.match(line, end):
        value = token[0].strip()
        if value == ")" and not depth:
            break
        depth += int(value == "(") - int(value == ")")
        end = token.end()
    return "" if depth else line[start:end].strip()


def _constants(lines: list[Line]) -> dict[str, Decimal]:
    constants = {}
    for line in lines:
        assignment = ASSIGNMENT.search(line.code)
        if not assignment:
            continue
        key = assignment["key"]
        prefix = line.code[:assignment.start()].strip()
        if (key.isupper() and not prefix) or re.search(r"\b(?:const|constexpr)\b", prefix):
            amount = _constant_value(_expression_at(line.code, assignment.end()), constants)
            if amount is not None:
                constants[key] = amount
    return constants


def _setting_name(name: str) -> str:
    return re.sub(r"(?<=[a-z])(?=[A-Z])", "_", name).lower().strip("_")


def _setting_kind(name: str) -> str | None:
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


def _settings(lines: list[Line], start: int, end: int, constants: dict[str, Decimal]):
    settings = defaultdict(list)
    for index in range(start, end):
        code = lines[index].code
        for assignment in ASSIGNMENT.finditer(code):
            key = assignment["key"]
            name = _setting_name(key)
            kind = _setting_kind(name)
            value = _expression_at(code, assignment.end()) if kind else ""
            amount = _constant_value(value, constants) if kind else None
            if kind == "seed" and amount is None and re.fullmatch(NAME, value):
                amount = value
            if amount is not None:
                if name == "places":
                    amount = -amount
                elif name in {"attempts", "max_attempts"}:
                    amount -= 1
                elif kind == "timeout":
                    amount *= TO_MILLISECONDS.get(assignment["duration"] or assignment["clock"], 1)
                if kind == "retry" and name in {"retries", "attempts", "max_attempts"}:
                    key = "retry count"
                settings[kind, key].append((index, amount))
        for switch in RETRY_SWITCH.finditer(code):
            key, value = switch.group("key", "value")
            if _setting_kind(_setting_name(key)) == "retry":
                settings["retry", key].append((index, Decimal(value.lower() == "true")))
        for pattern, kind, default_key in (
            (SEED_CALL, "seed", ""), (ABS_LIMIT, "tolerance", "abs comparison"),
            (RETRY_LOOP, "retry", "attempt loop"),
        ):
            for match in pattern.finditer(code):
                key = match.groupdict().get("key", default_key)
                value = match["value"] if kind == "retry" else _expression_at(code, match.end())
                amount = _constant_value(value, constants)
                if amount is None and kind == "seed" and re.fullmatch(NAME, value):
                    amount = value
                if amount is not None:
                    settings[kind, key].append((index, amount - 1 if kind == "retry" else amount))
        for retry in RETRY_CALL.finditer(code):
            if not DEFINITION.search(code[:retry.start()]):
                settings["retry", "retry call"].append((index, Decimal(1)))
    return settings


def _has_marker(markers: dict[int, tuple[str, bool]], index: int, kind: str) -> bool:
    own = markers.get(index)
    return (own is not None and own[0] == kind) or markers.get(index - 1) == (kind, True)


def _settings_findings(previous, revised, markers):
    for (kind, key), values in revised.items():
        old_values = previous[kind, key]
        for offset, (index, amount) in enumerate(values):
            prior = old_values[offset][1] if offset < len(old_values) else None
            if kind == "retry":
                flagged = amount > (prior if prior is not None else 0)
            else:
                flagged = prior is not None and (amount != prior if kind == "seed" else amount > prior)
            if flagged and not _has_marker(markers, index, kind):
                detail = f"{prior} -> {amount}" if prior is not None else str(amount)
                yield index + 1, f"{kind} change in {key}: {detail}"


def validate_test_diff(before: str, after: str) -> list[tuple[int, str]]:
    """Return review-worthy edits as (new line number, explanation)."""
    old_raw, new_raw = before.splitlines(), after.splitlines()
    old, new = _source_lines(old_raw), _source_lines(new_raw)
    opcodes = SequenceMatcher(None, old_raw, new_raw, autojunk=False).get_opcodes()
    edits = [(a, b, c, d) for tag, a, b, c, d in opcodes if tag != "equal"]
    old_markers = Counter(line.marker for line in old if line.marker)
    markers = {}
    for index, line in enumerate(new):
        if line.marker:
            if old_markers[line.marker]:
                old_markers[line.marker] -= 1
            else:
                markers[index] = (line.marker[0], not line.code.strip())
    old_disabled, new_disabled = _disabled_lines(old), _disabled_lines(new)
    removed = list(_assertions(old, old_raw, old_disabled))
    added = list(_assertions(new, new_raw, new_disabled))
    remaining = Counter(assertion.identity for assertion in removed)
    replacements = Counter(assertion.identity for assertion in added)
    remaining, replacements = remaining - replacements, replacements - remaining
    old_constants, new_constants = _constants(old), _constants(new)
    findings = []

    for a, b, c, d in edits:
        removed_here = []
        for assertion in removed:
            if assertion.touches(a, b) and remaining[assertion.identity]:
                remaining[assertion.identity] -= 1
                removed_here.append(assertion)
        added_here = []
        for assertion in added:
            if assertion.touches(c, d) and replacements[assertion.identity]:
                replacements[assertion.identity] -= 1
                added_here.append(assertion)
        for prior, revised in zip(removed_here, added_here):
            start = max(c, revised.start)
            if _wider_comparison(prior, revised) and not any(
                _has_marker(markers, line, "assertion") for line in range(start, min(d, revised.end + 1))
            ):
                findings.append((start + 1, f"weakened assertion {prior.name} (old line {prior.start + 1})"))
        for assertion in removed_here[len(added_here):]:
            relocated = min(c + max(0, assertion.start - a), max(c, d - 1))
            if not _has_marker(markers, relocated, "assertion"):
                findings.append((relocated + 1, f"removed assertion {assertion.name} (old line {assertion.start + 1})"))

        previous = _settings(old, a, b, old_constants)
        findings.extend(_settings_findings(previous, _settings(new, c, d, new_constants), markers))
    # A braced condition can change while the assertion line itself stays the same.
    for tag, a, b, c, d in opcodes:
        if tag != "equal":
            continue
        if old_constants != new_constants:
            previous = _settings(old, a, b, old_constants)
            findings.extend(_settings_findings(previous, _settings(new, c, d, new_constants), markers))
        for assertion in removed:
            index = c + assertion.start - a
            if a <= assertion.start < b and index in new_disabled and remaining[assertion.identity]:
                remaining[assertion.identity] -= 1
                if not _has_marker(markers, index, "assertion"):
                    findings.append((index + 1, f"disabled assertion {assertion.name} (old line {assertion.start + 1})"))
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
