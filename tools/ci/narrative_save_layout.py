"""Guard the versioned dictionaries and drained queues of the Narrative save."""
from __future__ import annotations

from collections import Counter
from dataclasses import dataclass
import json
from pathlib import Path
import re
import subprocess

from cpp_source import COMMENTS, read_cpp_source
from guard_baselines import historical_file, previous_baseline

BASELINE = "tools/ci/narrative_save_layouts.json"
SOURCE = "gdext/src/runtime_narrative_save.cpp"
CHECKPOINT = "gdext/src/runtime_narrative_checkpoint.cpp"
RUNTIME = "gdext/src/runtime_narrative.cpp"
DICTIONARIES = {"out": "PKNarrativeRuntime", "unrest": "PKStratumUnrest"}
HEADER_FIELDS = {("out", "schema"), ("out", "version")}
# A single AI request, its optional reply, and the multi-request representation
# use different fields. Pending settings are absent when there are no updates.
OPTIONAL_FIELDS = {("out", key) for key in
                   ("pending_ai_reply", "pending_ai_requests", "pending_ai_settings")}
TOKENS = re.compile(COMMENTS.pattern + r"|[A-Za-z_]\w*|\d+|\+\+|--|<<=|>>=|[+\-*/%&|^]=|\S")
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
        if ";" not in tokens[i + 4:start]:
            return tokens[start + 1:_closing(tokens, start)]
    raise ValueError(f"missing body for RuntimeNarrative::{name}")


PAIRS = {"(": ")", "[": "]", "{": "}"}


def _closing(tokens: list[str], start: int) -> int:
    stack = [PAIRS[tokens[start]]]
    for index in range(start + 1, len(tokens)):
        token = tokens[index]
        if token in PAIRS:
            stack.append(PAIRS[token])
        elif token == stack[-1]:
            stack.pop()
            if not stack:
                return index
    raise ValueError(f"unclosed {tokens[start]} in Narrative source")


def _until(tokens: list[str], start: int, ends: set[str]) -> int:
    index = start
    while index < len(tokens) and tokens[index] not in ends:
        index = _closing(tokens, index) + 1 if tokens[index] in PAIRS else index + 1
    return index


def _version(expression: list[str], tokens: list[str]) -> int:
    if len(expression) != 1:
        return 0
    value = expression[0]
    if value.isdecimal():
        return int(value)
    definitions = re.findall(
        rf"\bconstexpr (?:\w+ )+{re.escape(value)} = (\d+) ;", " ".join(tokens))
    return int(definitions[0]) if len(definitions) == 1 else 0


def _assignments(body: list[str]):
    for i in range(len(body) - 5):
        receiver, bracket, key, close, equals, value = body[i:i + 6]
        if bracket == "[" and key.startswith('"') and close == "]" and equals == "=" and value != "=":
            yield i, receiver, key[1:-1], body[i + 5:_until(body, i + 5, {';'})]
        elif body[i + 1:i + 4] == [".", "set", "("] and i + 6 < len(body):
            key, comma = body[i + 4:i + 6]
            if comma == "," and key.startswith('"'):
                yield i, receiver, key[1:-1], body[i + 6:_closing(body, i + 3)]


@dataclass(frozen=True)
class _Field:
    values: frozenset[tuple[str, ...]]
    required: bool = True


_Fields = dict[tuple[str, str], _Field]
_Return = tuple[list[str], _Fields, bool]


def _combine_paths(left: _Fields | None, right: _Fields | None) -> _Fields | None:
    if left is None or right is None:
        return left if right is None else right
    absent = _Field(frozenset(), required=False)
    joined = {}
    for key in left.keys() | right.keys():
        a, b = left.get(key, absent), right.get(key, absent)
        joined[key] = _Field(a.values | b.values, a.required and b.required)
    return joined


def _statement_end(body: list[str], start: int) -> int:
    token = body[start]
    if token == "{":
        return _closing(body, start) + 1
    if token in {"if", "while", "for"}:
        opening = start + (2 if body[start + 1:start + 2] == ["constexpr"] else 1)
        end = _statement_end(body, _closing(body, opening) + 1)
        if token == "if" and body[end:end + 1] == ["else"]:
            return _statement_end(body, end + 1)
        return end
    return _until(body, start, {";"}) + 1


def _single_statement(body: list[str], start: int) -> tuple[list[str], int]:
    stop = _statement_end(body, start)
    if body[start] == "{":
        return body[start + 1:stop - 1], stop
    return body[start:stop], stop


_DICTIONARY_MUTATORS = {"erase", "clear", "set", "get_or_add", "merge", "assign", "make_read_only"}


def _apply_dictionary_methods(fields: _Fields, tokens: list[str], names: set[str]) -> bool:
    """Apply direct dictionary methods even where their result is used."""
    found = False
    i = 0
    while i < len(tokens):
        name = tokens[i]
        if name == "{":
            i = _closing(tokens, i) + 1  # A lambda's statements are not evaluated here.
            continue
        if (name in names and tokens[i + 1:i + 2] == ["."] and tokens[i + 3:i + 4] == ["("]
                and tokens[i + 2] in _DICTIONARY_MUTATORS):
            stop = _closing(tokens, i + 3)
            arguments = tokens[i + 4:stop]
            method = tokens[i + 2]
            found = True
            if method == "erase" and len(arguments) == 1 and arguments[0].startswith('"'):
                fields.pop((name, arguments[0][1:-1]), None)
            elif method == "clear" and not arguments:
                for key in list(fields):
                    if key[0] == name:
                        del fields[key]
            elif method == "set" and arguments[:1] and arguments[0].startswith('"') and arguments[1:2] == [","]:
                fields[name, arguments[0][1:-1]] = _Field(frozenset({tuple(arguments[2:])}))
            else:
                raise ValueError(f"cannot determine returned Narrative fields after {' '.join(tokens[i:stop + 1])}")
            i = stop + 1
        else:
            i += 1
    return found


def _write_dictionary(fields: _Fields, statement: list[str], names: set[str]) -> None:
    if not statement:
        return
    if statement[0] == "Dictionary" and len(statement) > 1 and statement[1] in names:
        if any(key[0] == statement[1] for key in fields):
            raise ValueError(f"capture shadows the populated {statement[1]} dictionary")
        return
    calls = _apply_dictionary_methods(fields, statement, names)
    name = statement[0]
    if name not in names or (calls and statement[1:2] == ["."]):
        return
    assignment = next(_assignments(statement), None)
    if assignment is not None and assignment[0] == 0:
        _, _, key, value = assignment
        fields[name, key] = _Field(frozenset({tuple(value)}))
        return
    if statement[1:] in (["=", "{", "}", ";"], ["=", "Dictionary", "(", ")", ";"],
                          ["=", "Dictionary", "{", "}", ";"]):
        for key in list(fields):
            if key[0] == name:
                del fields[key]
        return
    raise ValueError(f"cannot determine returned Narrative fields after {' '.join(statement)}")


def _follow_dictionaries(body: list[str], state: _Fields, names: set[str],
                         returns: list[_Return], header_only: bool = False) -> _Fields | None:
    """Follow the direct dictionary edits down both branches of a capture."""
    state = state.copy()
    i = 0
    while i < len(body):
        token = body[i]
        if token == "{":
            block, i = _single_statement(body, i)
            state = _follow_dictionaries(block, state, names, returns, header_only)
        elif token in {"if", "for", "while"}:
            opening = i + (2 if body[i + 1:i + 2] == ["constexpr"] else 1)
            end = _closing(body, opening)
            condition = body[opening + 1:end]
            affected = state.copy()
            if _apply_dictionary_methods(affected, condition, names):
                # A short-circuited condition may skip an edit. Either result
                # must preserve every required key.
                state = _combine_paths(affected, state)
            block, i = _single_statement(body, end + 1)
            header_return = token == "if" and condition == ["_country", "=", "=", "0"]
            taken = _follow_dictionaries(block, state, names, returns, header_only or header_return)
            if token == "if" and body[i:i + 1] == ["else"]:
                otherwise, i = _single_statement(body, i + 1)
                state = _follow_dictionaries(otherwise, state, names, returns, header_only)
            state = _combine_paths(taken, state)
        else:
            stop = _statement_end(body, i)
            if token == "return":
                returns.append((body[i + 1:stop - 1], state, header_only))
                return None
            _write_dictionary(state, body[i:stop], names)
            i = stop
        if state is None:
            break
    return state


def _returns_dictionary(expression: list[str], name: str) -> bool:
    if expression == [name]:
        return True
    return (expression[:4] == [name, ".", "duplicate", "("]
            and _closing(expression, 3) == len(expression) - 1)


def _returned_fields(capture: list[str]) -> _Fields:
    returns: list[_Return] = []
    fallthrough = _follow_dictionaries(capture, {}, set(DICTIONARIES), returns)
    fields = None
    for expression, path, header_only in returns:
        if not _returns_dictionary(expression, "out"):
            raise ValueError(f"{SOURCE}: capture must return the populated out dictionary")
        # An unconfigured runtime is allowed to return the header on this path.
        if header_only and set(path) == HEADER_FIELDS and all(item.required for item in path.values()):
            continue
        fields = _combine_paths(fields, path)
    if fallthrough is not None or fields is None:
        raise ValueError(f"{SOURCE}: capture must return the full Narrative archive")
    nested = fields.get(("out", "stratum_unrest"))
    if nested is None or not nested.required or nested.values != {("unrest",)}:
        raise ValueError(f"{SOURCE}: returned archive must include the populated stratum_unrest dictionary")
    uncertain = sorted(key for key, field in fields.items() if not field.required and key not in OPTIONAL_FIELDS)
    if uncertain:
        raise ValueError(f"{SOURCE}: required fields may be absent from the returned archive: "
                         + ", ".join(key for _, key in uncertain))
    return fields


def _record_fields(body: list[str]) -> dict[str, list[str]]:
    """Read record keys as they leave their local scope, including erasures."""
    archives = {schema: [] for schema in DICTIONARIES.values()}
    schema = DICTIONARIES["out"]
    scopes = []
    for i, token in enumerate(body[:-2]):
        if token == "{":
            scopes.append(_closing(body, i))
        elif token == "}":
            scopes.pop()
        if token != "Dictionary" or body[i + 2] != ";":
            continue
        name = body[i + 1]
        if name in DICTIONARIES:
            schema = DICTIONARIES[name]
            continue
        block = body[i + 3:scopes[-1] if scopes else len(body)]
        if not any(receiver == name for _, receiver, _, _ in _assignments(block)):
            continue  # Dynamic map keys are not named record fields.
        returns: list[_Return] = []
        fields = _follow_dictionaries(block, {}, {name}, returns)
        for expression, path, _ in returns:
            if _returns_dictionary(expression, name):
                fields = _combine_paths(fields, path)
        if not fields:
            continue
        missing = sorted(key for (_, key), field in fields.items() if not field.required)
        if missing:
            raise ValueError(f"{SOURCE}: required record fields may be absent: {', '.join(missing)}")
        archives[schema].append(f"record[{','.join(sorted(key for _, key in fields))}]")
    return archives


def archive_shapes(source: str) -> dict[str, tuple[int, list[str]]]:
    tokens = _tokens(source)
    capture = _body(tokens, "capture")
    fields = _returned_fields(capture)
    records = _record_fields(capture)
    result = {}
    for name, schema in DICTIONARIES.items():
        keys = {key: field.values for (receiver, key), field in fields.items() if receiver == name}
        if keys.get("schema") != {(json.dumps(schema),)} or "version" not in keys:
            raise ValueError(f"{schema} missing literal schema tag or version")
        versions = keys.pop("version")
        version = _version(list(next(iter(versions))), tokens) if len(versions) == 1 else 0
        if version <= 0:
            raise ValueError(f"{schema} must write a positive integer version")
        result[schema] = version, sorted([*keys, *records[schema]])
    return result


def historical_narrative_layout(root: Path, ref: str) -> dict:
    source = historical_file(root, ref, SOURCE)
    if source is None:
        return {}
    return {schema: {str(version): keys} for schema, (version, keys) in
            archive_shapes(source.decode("utf-8-sig")).items()}


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
        if previous is not None:
            old_latest = max(map(int, old_history), default=0)
            for tag in sorted(history.keys() - old_history.keys(), key=int):
                if int(tag) <= old_latest:
                    errors.append(f"{BASELINE}: {schema} version {tag} precedes the existing version {old_latest}")
                elif int(tag) != version:
                    errors.append(f"{BASELINE}: cannot add {schema} version {tag}; "
                                  f"capture writes version {version}")
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


def _statements(body: list[str]):
    """Yield complete statements and control blocks in the current scope."""
    start = index = 0
    while index < len(body):
        token = body[index]
        if token in PAIRS:
            index = _closing(body, index)
            if token == "{":
                yield body[start:index + 1]
                start = index + 1
        elif token == ";":
            yield body[start:index + 1]
            start = index + 1
        index += 1


def _field_writes(capture: list[str]):
    for (receiver, key), field in sorted(_returned_fields(capture).items()):
        for value in sorted(field.values):
            yield receiver, key, list(value)


_READ_KEY = re.compile(r'\b(state|unrest) (?:\. get \(|\[) "([^"]+)"')
_MEMBER = re.compile(r'_\w+')
_INTEGER = re.compile(r'(?:u?int(?:8|16|32|64)_t|int|long|short|size_t)')


def _expression_type(tokens: list[str]) -> str | None:
    """Recognize the explicit Variant types whose mismatch is decidable here."""
    if not tokens:
        return None
    head = tokens[0]
    if head.startswith('"') or head in {"String", "StringName"}:
        return "STRING"
    if head in {"true", "false"}:
        return "BOOL"
    if head in {"Dictionary", "Array"}:
        return head.upper()
    scalar = tokens[2] if tokens[:2] == ["static_cast", "<"] and len(tokens) > 2 else head
    if _INTEGER.fullmatch(scalar):
        return "INT"
    if scalar in {"float", "double"}:
        return "FLOAT"
    number = tokens[1:] if head in {"-", "+"} else tokens
    if number and number[0].isdecimal() and (len(number) == 1 or number[1] == "."):
        return "FLOAT" if "." in number else "INT"
    return None


def _reader_types(checkpoint: list[str]) -> dict[tuple[str, str], str]:
    expected = {}
    for index, token in enumerate(checkpoint[:-4]):
        if token != "fields" or checkpoint[index + 1] != "(":
            continue
        match = re.fullmatch(
            r'(archive|unrest) , "[^"]*" , Variant : : (\w+) , \{ (.*?) \}',
            " ".join(checkpoint[index + 2:_closing(checkpoint, index + 1)]),
        )
        if match:
            receiver = "out" if match[1] == "archive" else "unrest"
            expected.update({(receiver, key): match[2] for key in re.findall(r'"([^"]+)"', match[3])})
    return expected


def _scalar_member(tokens: list[str]) -> str | None:
    if len(tokens) == 1 and _MEMBER.fullmatch(tokens[0]):
        return tokens[0]
    if tokens[:2] == ["static_cast", "<"] and tokens[-3:-2] == ["("] and tokens[-1:] == [")"]:
        return _scalar_member(tokens[-2:-1])
    return None


def _restore_fields(restore: list[str]) -> dict[str, list[set[tuple[str, str]]]]:
    fields: dict[str, list[set[tuple[str, str]]]] = {}
    helpers = set(re.findall(
        r'const auto (\w+) = \[ & \] \( const char \* (\w+) \) \{ return [^;{}]*'
        r'state \. get \( \2 [^;{}]* ; \}', " ".join(restore)))
    helper_names = {name for name, _ in helpers}
    aliases: dict[str, set[tuple[str, str]]] = {}
    for statement in _statements(restore):
        split = _until(statement, 0, {"=", ";"})
        if not 0 < split < len(statement) or statement[split] != "=" or statement[-1] != ";":
            continue
        name = statement[split - 1]
        declaration = statement[:split - 1]
        if declaration and declaration[0] not in {"const", "auto", "int64_t", "int32_t", "Dictionary", "Array", "bool"}:
            continue
        expression = statement[split + 1:-1]
        value = " ".join(expression)
        sources = {("out" if receiver == "state" else receiver, key)
                   for receiver, key in _READ_KEY.findall(value)}
        if (helper_call := re.fullmatch(r'(\w+) \( "([^"]+)" \)', value)) and helper_call[1] in helper_names:
            sources.add(("out", helper_call[2]))
        for alias in set(expression) & aliases.keys():
            sources.update(aliases[alias])
        if not declaration and _MEMBER.fullmatch(name):
            fields.setdefault(name, []).append(sources)
        else:
            aliases[name] = sources
    return fields


def _roundtrip_violations(save_source: str, checkpoint_source: str) -> list[str]:
    tokens = _tokens(save_source)
    capture = _body(tokens, "capture")
    restore = _restore_fields(_body(tokens, "decode_checkpoint"))
    expected = _reader_types(_body(_tokens(checkpoint_source), "checkpoint_error"))
    restored_fields = {field for assignments in restore.values() for sources in assignments for field in sources}
    errors = []
    for receiver, key, value in _field_writes(capture):
        field = receiver, key
        actual_type = _expression_type(value)
        reader_type = expected.get(field)
        if actual_type and reader_type and actual_type != reader_type and (actual_type, reader_type) != ("INT", "FLOAT"):
            errors.append(f"{SOURCE}: {key} is saved as {actual_type} but checkpoint validation expects {reader_type}")
        member = _scalar_member(value)
        if member is not None and (member not in restore or any(field not in sources for sources in restore[member])):
            errors.append(f"{SOURCE}: {member} must be restored from its saved field {key}")
        elif field in restored_fields and (value[0].startswith('"') or len(value) == 1 and
                                          (value[0].isdecimal() or value[0] in {"true", "false"})):
            errors.append(f"{SOURCE}: {key} is restored into runtime state but is saved as a literal")
    return errors


def _live_member(body: list[str], index: int) -> bool:
    if not _MEMBER.fullmatch(body[index]):
        return False
    if body[index - 3:index] == ["this", "-", ">"]:
        return True
    return body[index - 1:index] != ["."] and body[index - 2:index] != ["-", ">"]


def _direct_live_writes(body: list[str]) -> set[str]:
    """Recognize direct writes through the live RuntimeNarrative, including C++ updates."""
    writes = set()
    updates = {"++", "--"}
    compound = {"+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<=", ">>="}
    queries = {"at", "back", "begin", "contains", "count", "empty", "end", "find", "front",
               "get", "has", "is_empty", "keys", "size", "values"}
    for i, name in enumerate(body):
        if not _live_member(body, i):
            continue
        opening = i - 3 if body[i - 3:i] == ["this", "-", ">"] else i
        end = i + 1
        while end < len(body):
            if body[end] == "[":
                end = _closing(body, end) + 1
            elif body[end] == "." and end + 1 < len(body):
                method = body[end + 1]
                end += 2
                if body[end:end + 1] == ["("] and method in queries:
                    end = _closing(body, end) + 1
            elif body[end:end + 2] == ["-", ">"] and end + 2 < len(body):
                end += 3
            else:
                break
        after = body[end] if end < len(body) else ""
        prefix_update = opening > 0 and body[opening - 1] in updates
        assignment = after == "=" and body[end + 1:end + 2] != ["="]
        if prefix_update or assignment or after in updates | compound or after == "(":
            writes.add(name)

    # Conventional library helpers also modify the objects passed by reference.
    for i in range(len(body) - 1):
        helper = body[i]
        if helper not in {"swap", "exchange", "move"} or body[i + 1] != "(":
            continue
        stop = _closing(body, i + 1)
        arg = i + 2
        while arg < stop:
            end = _until(body, arg, {",", ")"})
            receiver = arg + 3 if body[arg:arg + 3] == ["this", "-", ">"] else arg
            if receiver < end and _live_member(body, receiver):
                writes.add(body[receiver])
            if helper != "swap":
                break
            arg = end + 1
    return writes


def _install_violations(runtime_source: str) -> list[str]:
    body = _body(_tokens(runtime_source), "configure")
    statements = list(_statements(body))
    steps = [" ".join(step) for step in statements]
    checked = None
    candidate = None
    decoded = False
    installed = False
    for index, step in enumerate(steps):
        if not checked and (match := re.fullmatch(r'(?:const )?(?:auto|String) (\w+) = checkpoint_error \( archive \) ;', step)):
            check = re.escape(match[1])
            if index + 1 < len(steps) and re.match(rf'if \( ! {check} \. is_empty \( \) \) \{{', steps[index + 1]):
                block = statements[index + 1]
                failures = list(_statements(block[block.index("{") + 1:-1]))
                if failures and failures[-1] == ["return", "false", ";"]:
                    checked = match[1]
        elif checked and not candidate and (match := re.fullmatch(r'RuntimeNarrative (\w+) (?:;|\{ \})', step)):
            candidate = match[1]
        elif candidate and step == f"{candidate} . decode_checkpoint ( archive ) ;":
            decoded = True
        elif (decoded and step == f"* this = std : : move ( {candidate} ) ;"
              and steps[index + 1:] == ["return true ;"]):
            installed = True
    implementation = " ".join(body)
    if writes := _direct_live_writes(body):
        return [f"{RUNTIME}: configure writes live state before installation: {', '.join(sorted(writes))}"]
    if (installed and implementation.count("decode_checkpoint (") == 1
            and implementation.count("* this") == 1 and implementation.count("return true ;") == 1):
        return []
    return [f"{RUNTIME}: configure must validate the archive, decode into a local candidate, "
            "then install that candidate once before reporting success"]


def _reachable(tokens: list[str]) -> list[str]:
    """Ignore obvious dead branches when looking for archive data movement."""
    result = []
    index = 0
    while index < len(tokens):
        if tokens[index] == "if":
            start = index + 1
            if tokens[start:start + 1] == ["constexpr"]:
                start += 1
            if tokens[start:start + 1] == ["("]:
                end = _closing(tokens, start)
                if tokens[start + 1:end] in (["false"], ["0"]) and end + 1 < len(tokens):
                    dead = end + 1
                    index = (_closing(tokens, dead) if tokens[dead] == "{" else _until(tokens, dead, {";"})) + 1
                    continue
        result.append(tokens[index])
        index += 1
    return result


def _captured_queue_fields(capture: list[str], member: str) -> set[tuple[str, str]]:
    packed = {member}
    for index, token in enumerate(capture[:-1]):
        if token != "for" or capture[index + 1] != "(":
            continue
        end = _closing(capture, index + 1)
        header = capture[index + 2:end]
        if len(header) < 3 or header[-2:] != [":", member] or end + 1 >= len(capture):
            continue
        stop = _closing(capture, end + 1) if capture[end + 1] == "{" else _until(capture, end + 1, {";"})
        item = re.escape(header[-3])
        packed.update(re.findall(
            rf'\b(\w+) \. (?:push_back|append) \( {item} \)', " ".join(capture[end + 1:stop])))
    return {(receiver, key) for receiver, key, value in _field_writes(capture)
            if (len(value) == 1 and value[0] in packed) or value == ["encode_records", "(", member, ")"]}


def _restores_queue(restore: list[str], member: str, fields: set[tuple[str, str]]) -> bool:
    if not fields:
        return False
    code = " ".join(restore)
    for receiver, key in fields:
        reader = "state" if receiver == "out" else receiver
        read = rf'\b{reader} (?:\. get \(|\[) "{re.escape(key)}"'
        aliases = set(re.findall(rf'\b(\w+) = [^;]*?{read}', code))
        writes = re.findall(rf'\b{member} (?:=|\. (?:push_back|emplace_back|assign|insert) \() ([^;]+) ;', code)
        if any(re.search(read, write) or any(re.search(rf'\b{re.escape(alias)}\b', write) for alias in aliases)
               for write in writes):
            return True
        callback = re.search(
            rf'\bdecode_records \( {read} [^;]* Dictionary & (\w+) \) \{{ [^}}]*'
            rf'\b{member} \. (?:push_back|emplace_back) \( ([^;]+) ;', code)
        if callback and re.search(rf'\b{re.escape(callback[1])}\b', callback[2]):
            return True
    return False


def drained_state_violations(save_source: str, implementations: list[tuple[str, str]]) -> list[str]:
    """Require capture and decode for Narrative members taken with std::exchange."""
    save_tokens = _tokens(save_source)
    capture = _reachable(_body(save_tokens, "capture"))
    restore = _reachable(_body(save_tokens, "decode_checkpoint"))
    errors = []
    for path, source in implementations:
        # Strip strings as well as comments so examples cannot stand in for code.
        code = " ".join(token for token in _tokens(source) if not token.startswith(('"', "'", 'R"')))
        for member in sorted(set(EXCHANGES.findall(code)) - SAME_DAY):
            if not _restores_queue(restore, member, _captured_queue_fields(capture, member)):
                errors.append(f"{path}: drained Narrative state {member} is missing from "
                              "checkpoint capture or restore")
    return errors


def narrative_violations(root: Path) -> list[str]:
    try:
        save_source = read_cpp_source(root / SOURCE)
        baseline = json.loads((root / BASELINE).read_text(encoding="utf-8"))
        previous = previous_baseline(root, BASELINE, bootstrap=historical_narrative_layout)
        errors = layout_violations(archive_shapes(save_source), baseline, previous)
        errors.extend(_roundtrip_violations(save_source, read_cpp_source(root / CHECKPOINT)))
        errors.extend(_install_violations(read_cpp_source(root / RUNTIME)))
        owners = sorted((root / "gdext/src").glob("runtime_narrative*.cpp"))
        return errors + drained_state_violations(
            save_source, [(path.relative_to(root).as_posix(), read_cpp_source(path)) for path in owners])
    except (OSError, ValueError, TypeError, KeyError, subprocess.CalledProcessError) as error:
        return [f"Narrative save layout: {error}"]
