"""Guard the versioned dictionaries and drained queues of the Narrative save."""
from __future__ import annotations

from collections import Counter
import json
from pathlib import Path
import re

from cpp_source import COMMENTS, read_cpp_source
from guard_baselines import previous_baseline

BASELINE = "tools/ci/narrative_save_layouts.json"
SOURCE = "gdext/src/runtime_narrative_save.cpp"
DICTIONARIES = {"out": "PKNarrativeRuntime", "unrest": "PKStratumUnrest"}
TOKENS = re.compile(COMMENTS.pattern + r"|[A-Za-z_]\w*|\d+|\S")
EXCHANGES = re.compile(r"\bstd : : exchange \( (_\w+) , \{ \} \)")
# These have consumers in stage_narrative before the current day commits.
SAME_DAY = {"_independence_actions", "_notices"}


def _tokens(source: str) -> list[str]:
    return [match[0] for match in TOKENS.finditer(source) if not match[0].startswith(("//", "/*"))]


def _body(tokens: list[str], name: str) -> list[str]:
    for i in range(len(tokens) - 3):
        if tokens[i:i + 4] != ["RuntimeNarrative", ":", ":", name]:
            continue
        start = tokens.index("{", i + 4)
        depth = 1
        for end in range(start + 1, len(tokens)):
            depth += int(tokens[end] == "{") - int(tokens[end] == "}")
            if depth == 0:
                return tokens[start + 1:end]
    raise ValueError(f"missing body for RuntimeNarrative::{name}")


def _version(value: str, tokens: list[str]) -> int:
    if value.isdecimal():
        return int(value)
    definitions = re.findall(
        rf"\bconstexpr (?:\w+ )+{re.escape(value)} = (\d+) ;", " ".join(tokens))
    return int(definitions[0]) if len(definitions) == 1 else 0


def _assignments(body: list[str]):
    for i in range(len(body) - 5):
        receiver, bracket, key, close, equals, value = body[i:i + 6]
        if bracket == "[" and key.startswith('"') and close == "]" and equals == "=" and value != "=":
            yield i, receiver, key[1:-1], value
        elif body[i + 1:i + 4] == [".", "set", "("] and i + 6 < len(body):
            key, comma, value = body[i + 4:i + 7]
            if comma == "," and key.startswith('"'):
                yield i, receiver, key[1:-1], value


def _record_fields(body: list[str], assignments: list[tuple]) -> dict[str, list[str]]:
    """Group literal fields by their record and the archive being written."""
    archives = {schema: [] for schema in DICTIONARIES.values()}
    sections = iter(sorted(assignments, reverse=True))
    assignment = next(sections, None)
    # Walk backwards to collect fields until we reach their Dictionary declaration.
    current: dict[str, set[str]] = {}
    schema = DICTIONARIES["unrest"]
    for i in range(len(body) - 1, -1, -1):
        if assignment is not None and assignment[0] == i:
            _, receiver, key, _ = assignment
            if receiver not in DICTIONARIES:
                current.setdefault(receiver, set()).add(key)
            assignment = next(sections, None)
        if body[i] != "Dictionary" or body[i + 2:i + 3] != [";"]:
            continue
        name = body[i + 1]
        fields = current.pop(name, set())
        if fields:
            archives[schema].append(f"record[{','.join(sorted(fields))}]")
        if name == "unrest":
            schema = DICTIONARIES["out"]
    return archives


def archive_shapes(source: str) -> dict[str, tuple[int, list[str]]]:
    tokens = _tokens(source)
    capture = _body(tokens, "capture")
    assignments = list(_assignments(capture))
    records = _record_fields(capture, assignments)
    result = {}
    for name, schema in DICTIONARIES.items():
        keys = {key: value for _, receiver, key, value in assignments if receiver == name}
        if keys.get("schema") != json.dumps(schema) or "version" not in keys:
            raise ValueError(f"{schema} missing literal schema tag or version")
        version = _version(keys.pop("version"), tokens)
        if version <= 0:
            raise ValueError(f"{schema} must write a positive integer version")
        result[schema] = version, sorted([*keys, *records[schema]])
    return result


def layout_violations(shapes: dict, baseline: dict, previous: dict | None = None) -> list[str]:
    errors = []
    if not isinstance(baseline, dict) or set(baseline) != set(DICTIONARIES.values()):
        return [f"{BASELINE}: expected the two Narrative section tags"]
    for schema, (version, keys) in shapes.items():
        history = baseline[schema]
        if not isinstance(history, dict) or not history or any(
            not tag.isdecimal() or str(int(tag)) != tag or int(tag) <= 0
            or not isinstance(fields, list) or not all(isinstance(field, str) for field in fields)
            or fields != sorted(fields)
            for tag, fields in history.items()
        ):
            errors.append(f"{BASELINE}: invalid layout history for {schema}")
            continue
        old_history = (previous or {}).get(schema, {})
        for tag, old_keys in old_history.items():
            if history.get(tag) != old_keys:
                errors.append(f"{BASELINE}: cannot remove or rewrite {schema} version {tag}")
        if old_history:
            old_latest = max(map(int, old_history))
            for tag in history.keys() - old_history.keys():
                if int(tag) <= old_latest:
                    errors.append(f"{BASELINE}: {schema} version {tag} precedes the existing version {old_latest}")
        latest = max(map(int, history))
        if version != latest:
            errors.append(f"{SOURCE}: {schema} writes version {version}, latest layout is {latest}; "
                          "append the layout for a new version or restore the current version")
            continue
        expected = history[str(version)]
        if keys != expected:
            added = ", ".join(sorted((Counter(keys) - Counter(expected)).elements()))
            removed = ", ".join(sorted((Counter(expected) - Counter(keys)).elements()))
            errors.append(f"{SOURCE}: {schema} version {version} changed serialized fields "
                          f"(added: {added or 'none'}; removed: {removed or 'none'}); "
                          "bump the version and append the new layout")
    return errors


def drained_state_violations(save_source: str, implementations: list[tuple[str, str]]) -> list[str]:
    """Require capture and decode for Narrative members taken with std::exchange."""
    save_tokens = _tokens(save_source)
    capture = set(_body(save_tokens, "capture"))
    restore = set(_body(save_tokens, "decode_checkpoint"))
    errors = []
    for path, source in implementations:
        # Strip strings as well as comments so examples cannot stand in for code.
        code = " ".join(token for token in _tokens(source) if not token.startswith(('"', "'", 'R"')))
        for member in sorted(set(EXCHANGES.findall(code)) - SAME_DAY):
            if member not in capture or member not in restore:
                errors.append(f"{path}: drained Narrative state {member} is missing from "
                              "checkpoint capture or restore")
    return errors


def narrative_violations(root: Path) -> list[str]:
    try:
        save_source = read_cpp_source(root / SOURCE)
        baseline = json.loads((root / BASELINE).read_text(encoding="utf-8"))
        previous = previous_baseline(root, BASELINE)
        errors = layout_violations(archive_shapes(save_source), baseline, previous)
        owners = sorted((root / "gdext/src").glob("runtime_narrative*.cpp"))
        return errors + drained_state_violations(
            save_source, [(path.relative_to(root).as_posix(), read_cpp_source(path)) for path in owners])
    except (OSError, ValueError, TypeError, KeyError) as error:
        return [f"Narrative save layout: {error}"]
