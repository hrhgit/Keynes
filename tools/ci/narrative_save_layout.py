"""Inventory literal Narrative archive keys and versions. Godot tests the returned values."""
from __future__ import annotations

from collections import Counter, defaultdict
import json
from pathlib import Path
import re
import subprocess

from cpp_source import COMMENTS, read_cpp_source
from guard_baselines import historical_file, previous_baseline

BASELINE = "tools/ci/narrative_save_layouts.json"
SOURCE = "gdext/src/runtime_narrative_save.cpp"
SCHEMAS = {"PKNarrativeRuntime", "PKStratumUnrest"}
LEXEMES = re.compile(COMMENTS.pattern + r"|::|==|[0-9][\w']*|\w+|\S")
CLOSE = {"{": "}", "[": "]", "(": ")"}
# These two queues are consumed within the day that creates them.
SAME_DAY = {"_independence_actions", "_notices"}
EXCHANGE = re.compile(r"\bstd\s*::\s*exchange\s*\(\s*(?:this\s*->\s*)?(_\w+)\s*,\s*\{\s*\}\s*\)")


def _lex(source: str):
    words, lines, closing, stack = [], [], {}, []
    line, last = 1, 0
    for match in LEXEMES.finditer(source):
        line += source.count("\n", last, match.start())
        word = match[0]
        if not word.startswith(("//", "/*")):
            index = len(words)
            if word in ("'", '"') or (word == "/" and source[match.start():].startswith("/*")):
                raise ValueError(f"{SOURCE}:{line}: unterminated comment or string")
            if word in CLOSE:
                stack.append(index)
            elif word in CLOSE.values():
                if not stack or CLOSE[words[stack[-1]]] != word:
                    raise ValueError(f"{SOURCE}:{line}: unmatched {word}")
                closing[stack.pop()] = index
            words.append(word)
            lines.append(line)
        line += word.count("\n")
        last = match.end()
    if stack:
        i = stack[-1]
        raise ValueError(f"{SOURCE}:{lines[i]}: unclosed {words[i]}")
    return words, lines, closing


def _function(words, lines, closing, name):
    for index, word in enumerate(words):
        if word != "RuntimeNarrative" or words[index + 1:index + 4] != ["::", name, "("]:
            continue
        start = closing[index + 3] + 1
        if words[start:start + 1] == ["const"]:
            start += 1
        if words[start:start + 1] == ["{"]:
            return range(start + 1, closing[start])
    raise ValueError(f"{SOURCE}:1: cannot find RuntimeNarrative::{name} definition")


# One C++ integer token (including its base, digit separators and type suffix).
INTEGER = re.compile(r"(0[xX][a-fA-F0-9]+|0[bB][01]+|0[0-7]*|[1-9][0-9]*)"
                     r"(?:[uU](?:ll|LL|[lLzZ])?|(?:ll|LL|[lLzZ])[uU]?)?")


def _value_end(words, closing, start, limit):
    end = start
    while end < limit and words[end] not in {";", ")", "}"}:
        end = closing.get(end, end) + 1
    return end


def _single_token(words, closing, start, end):
    while start < end and words[start] == "(" and closing[start] == end - 1:
        start, end = start + 1, end - 1
    return words[start] if end == start + 1 else ""


def _version(words, lines, closing, start, end):
    token = _single_token(words, closing, start, end)
    if token.isidentifier():
        # A named version may be a constant with a literal initializer.
        values = set()
        for i, name in enumerate(words):
            if name != token or words[i + 1:i + 2] != ["="]:
                continue
            j = i - 1
            while j >= 0 and words[j] not in {";", "{", "}"}:
                if words[j] in {"const", "constexpr"}:
                    values.add(_single_token(words, closing, i + 2, _value_end(words, closing, i + 2, len(words))))
                    break
                j -= 1
        token = values.pop() if len(values) == 1 else ""
    match = INTEGER.fullmatch(token.replace("'", ""))
    if match:
        literal = match[1]
        try:
            number = int(literal, 8 if literal.startswith("0") and literal.isdecimal() else 0)
            if number > 0:
                return number
        except ValueError:
            pass
    raise ValueError(f"{SOURCE}:{lines[start]}: cannot read positive integer version from "
                     f"{' '.join(words[start:end])}")


def archive_shapes(source: str, *, legacy_records=False) -> dict[str, tuple[int, list[str]]]:
    words, lines, closing = _lex(source)
    body = _function(words, lines, closing, "capture")
    # Each local Dictionary declaration owns its literal key writes, including
    # writes inside a nested block. Do not interpret their RHS or branch paths.
    scopes = [{}]
    fields = defaultdict(set)
    headers = {}
    versions = defaultdict(set)
    # The first baseline also froze row signatures from the original writer.
    # Reconstruct that metadata only at a base commit without a baseline file.
    # Current versions freeze section keys; runtime fixtures exercise row values.
    current_schema = None
    owners = {}
    for i in body:
        word = words[i]
        if word == "{":
            scopes.append({})
        elif word == "}":
            scopes.pop()
        elif ((word == "Dictionary" and words[i + 2:i + 3] in ([";"], ["{"], ["="]))
              or (word == "auto" and words[i + 2:i + 4] == ["=", "Dictionary"])):
            scopes[-1][words[i + 1]] = i
            if legacy_records:
                owners[i] = current_schema
        elif (word in {"if", "while", "for"} and words[i + 1:i + 2] == ["("]
              and words[closing[i + 1] + 1:closing[i + 1] + 2] == ["}"]):
            raise ValueError(f"{SOURCE}:{lines[i]}: {word} is missing its statement")
        if words[i + 1:i + 2] == ["["] and words[i + 3:i + 5] == ["]", "="]:
            key, rhs = words[i + 2], i + 5
        elif words[i + 1:i + 4] == [".", "set", "("] and words[i + 5:i + 6] == [","]:
            key, rhs = words[i + 4], i + 6
        else:
            continue
        local = next((scope[word] for scope in reversed(scopes) if word in scope), None)
        if local is None or not key.startswith('"'):
            continue
        if rhs >= body.stop or words[rhs] in {";", ")", "}"}:
            raise ValueError(f"{SOURCE}:{lines[i]}: missing value for {key}")
        key = key[1:-1]
        fields[local].add(key)
        if key == "schema" and words[rhs].strip('"') in SCHEMAS:
            current_schema = words[rhs].strip('"')
            headers[local] = current_schema
        if key == "version":
            versions[local].add((rhs, _value_end(words, closing, rhs, body.stop)))

    result = {}
    for local, schema in headers.items():
        numbers = {_version(words, lines, closing, start, end) for start, end in versions[local]}
        if len(numbers) != 1:
            raise ValueError(f"{SOURCE}:{lines[local]}: {schema} requires one positive integer version")
        records = ["record[" + ",".join(sorted(keys)) + "]" for idx, keys in fields.items()
                   if legacy_records and idx not in headers and owners.get(idx) == schema]
        result[schema] = numbers.pop(), sorted([*(fields[local] - {"version"}), *records])
    if result.keys() != SCHEMAS:
        line = lines[body.start - 1]
        raise ValueError(f"{SOURCE}:{line}: missing Narrative section tag: {', '.join(sorted(SCHEMAS - result.keys()))}")
    return result


def historical_narrative_layout(root: Path, ref: str) -> dict:
    source = historical_file(root, ref, SOURCE)
    if source is None:
        return {}
    return {schema: {str(version): keys} for schema, (version, keys) in
            archive_shapes(source.decode("utf-8-sig"), legacy_records=True).items()}


def layout_violations(shapes: dict, baseline: dict, previous: dict | None = None) -> list[str]:
    errors = []
    if previous is not None and not isinstance(previous, dict):
        return [f"{BASELINE}:1: expected a history object at the comparison commit"]
    if not isinstance(baseline, dict) or set(baseline) != SCHEMAS:
        return [f"{BASELINE}:1: expected the two Narrative section tags"]
    for schema, (version, keys) in shapes.items():
        history = baseline[schema]
        old_history = (previous or {}).get(schema, {})
        if not history or any(not isinstance(section, dict) or any(
                not isinstance(tag, str) or not re.fullmatch("[1-9][0-9]*", tag)
                or not isinstance(fields, list) or not all(isinstance(field, str) for field in fields)
                or fields != sorted(fields) for tag, fields in section.items())
                for section in (history, old_history)):
            errors.append(f"{BASELINE}:1: invalid layout history for {schema}")
            continue
        for tag, old_keys in old_history.items():
            if history.get(tag) != old_keys:
                errors.append(f"{BASELINE}: cannot remove or rewrite {schema} version {tag}")
        if previous is not None:
            old_latest = max(old_history, key=lambda tag: (len(tag), tag), default="0")
            for tag in sorted(history.keys() - old_history.keys()):
                if (len(tag), tag) <= (len(old_latest), old_latest):
                    errors.append(f"{BASELINE}: {schema} version {tag} precedes the existing version {old_latest}")
                elif tag != str(version):
                    errors.append(f"{BASELINE}: cannot add {schema} version {tag}; "
                                  f"capture writes version {version}")
        for tag, entries in history.items():
            if tag not in old_history and previous is not None and any(k.startswith("record[") for k in entries):
                errors.append(f"{BASELINE}:1: new {schema} version {tag} cannot contain legacy record metadata")
        latest = max(history, key=lambda tag: (len(tag), tag))
        if str(version) != latest:
            errors.append(f"{SOURCE}: {schema} writes version {version}, latest layout is {latest}; "
                          "append the layout for a new version or restore the current version")
            continue
        expected = [name for name in history[str(version)] if not name.startswith("record[")]
        if keys != expected:
            added = ", ".join(sorted((Counter(keys) - Counter(expected)).elements()))
            removed = ", ".join(sorted((Counter(expected) - Counter(keys)).elements()))
            errors.append(f"{SOURCE}: {schema} version {version} changed serialized fields "
                          f"(added: {added or 'none'}; removed: {removed or 'none'}); "
                          "bump the version and append the new layout")
    return errors


def drained_state_violations(save_source: str, implementations: list[tuple[str, str]]) -> list[str]:
    """Catch a new day-crossing queue wholly omitted from capture or decode."""
    words, lines, closing = _lex(save_source)
    mentions = [set(words[i] for i in _function(words, lines, closing, name))
                for name in ("capture", "decode_checkpoint")]
    errors = []
    for path, source in implementations:
        code = COMMENTS.sub(lambda m: "\n" * m[0].count("\n") + " ", source)
        for match in EXCHANGE.finditer(code):
            member = match[1]
            if member not in SAME_DAY and not all(member in section for section in mentions):
                line = code.count("\n", 0, match.start()) + 1
                errors.append(f"{path}:{line}: drained Narrative state {member} is missing from "
                              "checkpoint capture or restore")
    return errors


def narrative_violations(root: Path) -> list[str]:
    try:
        source = read_cpp_source(root / SOURCE)
        baseline = json.loads((root / BASELINE).read_text(encoding="utf-8"))
        previous = previous_baseline(root, BASELINE, bootstrap=historical_narrative_layout)
        errors = layout_violations(archive_shapes(source), baseline, previous)
        owners = sorted((root / "gdext/src").glob("runtime_narrative*.cpp"))
        return errors + drained_state_violations(source, [
            (path.relative_to(root).as_posix(), read_cpp_source(path)) for path in owners])
    except json.JSONDecodeError as error:
        return [f"{BASELINE}:{error.lineno}: {error.msg}"]
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        return [str(error)]
