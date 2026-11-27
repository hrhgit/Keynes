#!/usr/bin/env python3
"""Freeze cross-module DCWorldExt access and front-end live Economy reads.

Each call or exact binding-name string is one candidate. Count it only when its
receiver is world-like (a), or no production script defines that method (b).
This is a lexical guard, not GDScript type/alias inference. --audit shows the
precision breakdown and samples; --report shows the migration backlog.
--write-baseline creates the initial baseline or tightens an existing one.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from collections import Counter, defaultdict
from dataclasses import dataclass
from pathlib import Path, PurePosixPath

import world_ext_bindings as inventory
from guard_baselines import historical_file, previous_baseline

PROJECT = "Project/project-keynes"
BASELINE = "tools/ci/script_native_access_baseline.json"
LIVE_BASELINE = "tools/ci/script_live_access_baseline.json"
EXCLUDED = {"tests", "tmp", "addons", ".godot"}
FRONTEND_DIRS = ("scripts/ui/", "scripts/rendering/")
PLAYER_GAME = "scripts/game/player_game.gd"
FRONTEND_FILES = {PLAYER_GAME, "scripts/game/world_runtime_presentation.gd", "scripts/geography/world_clock.gd"}
ECONOMY_FACADES = {"_economy_facade", "_economy_runtime_facade"}
OWNER_TYPES = {"EconomyFacade": "facade", "MapGenerator": "generator", "DCWorldExt": "native"}
OWNER_FACTORIES = {"get_economy_facade": "facade", "get_generator": "generator"}
PROBE = "_economy_probe"
PROBE_DIGEST = "84804519a507373b76e384bed24ece558d67ed55a89e8ff8a0e14922e9d954b3"
HEARTBEAT_DIGEST = "cb8a83063319f379b22a32476218093aafbd5ea9e2d9e33569e4bd30c77be14d"
WORLD_NAME = re.compile(r"(?:^|_)(?:data_core_)?world_ext$|^_?ext$|^ext_obj$|^world$|^dc$")
# A single lexer keeps comments and quoted code out of call/func recognition.
LEX = re.compile(
    r'''(?P<comment>\#[^\n]*)|(?P<string>"""(?:\\.|(?!""")[\s\S])*"""|'''
    r"'''(?:\\.|(?!''')[\s\S])*'''|"
    r'''"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')|(?P<id>[A-Za-z_]\w*)|(?P<punct>[^\s])''')
REFLECTIVE = {"has_method", "call", "callv", "call_deferred"}


@dataclass(frozen=True)
class Token:
    kind: str
    value: str
    offset: int


@dataclass(frozen=True)
class Reference:
    file: str
    line: int
    name: str
    module: str
    kind: str
    receiver: str | None
    a: bool
    b: bool
    outside: bool
    source: str

    @property
    def counted(self) -> bool:
        return self.a or self.b


def tokenize(source: str) -> list[Token]:
    tokens = []
    for match in LEX.finditer(source):
        kind, value = match.lastgroup, match[0]
        if kind == "comment":
            continue
        if kind == "string":
            width = 3 if value.startswith(('"""', "'''")) else 1
            value = value[width:-width]
        tokens.append(Token(kind, value, match.start()))
    return tokens


def script_files(root: Path) -> list[Path]:
    project = root / PROJECT
    return sorted(p for p in project.rglob("*.gd")
                  if not EXCLUDED.intersection(p.relative_to(project).parts[:-1]))


def world_variables(tokens: list[Token]) -> set[str]:
    result = set()
    for i, token in enumerate(tokens):
        if token.kind != "id":
            continue
        # Declarations and function parameters, including self/member uses later.
        if [(t.kind, t.value) for t in tokens[i + 1:i + 3]] == [("punct", ":"), ("id", "DCWorldExt")]:
            result.add(token.value)
        j = i + 1
        if j < len(tokens) and tokens[j].value == ":":
            j += 1
            if j < len(tokens) and tokens[j].kind == "id":
                j += 1  # : Object =, : RefCounted =, or : DCWorldExt =
        if j >= len(tokens) or tokens[j].value != "=":
            continue
        rhs = tokens[j + 1:j + 6]
        if [(t.kind, t.value) for t in rhs] == [
                ("id", "ClassDB"), ("punct", "."), ("id", "instantiate"),
                ("punct", "("), ("string", "DCWorldExt")]:
            result.add(token.value)
    return result


def receiver(tokens: list[Token], start: int, end: int) -> str | None:
    """Terminal variable in a plain dotted path; never treat a call result as one."""
    part = tokens[start:end]
    if not part or any(t.kind != ("id" if i % 2 == 0 else "punct")
                       or (i % 2 and t.value != ".") for i, t in enumerate(part)):
        return None
    return part[-1].value if len(part) % 2 else None


def dot_receiver(tokens: list[Token], dot: int) -> str | None:
    start = dot - 1
    if start < 0 or tokens[start].kind != "id":
        return None
    while start >= 2 and tokens[start - 1].value == "." and tokens[start - 2].kind == "id":
        start -= 2
    return receiver(tokens, start, dot)


def candidates(tokens: list[Token], bindings: dict[str, str], *, probes: bool = True):
    # Stack entries: opening token, first argument start, argument number, first comma.
    stack: list[list[int]] = []
    for i, token in enumerate(tokens):
        if token.kind == "id" and token.value in bindings and i and i + 1 < len(tokens):
            if tokens[i - 1].value == "." and tokens[i + 1].value == "(":
                yield token, "call", dot_receiver(tokens, i - 1)
        if token.kind == "string" and token.value in bindings:
            target = None
            is_read = False
            if stack and tokens[stack[-1][0]].value == "(":
                opening, first, arg, first_comma = stack[-1]
                function = tokens[opening - 1].value if opening else ""
                if function in REFLECTIVE and arg == 0 and opening >= 2 and tokens[opening - 2].value == ".":
                    target = dot_receiver(tokens, opening - 2)
                    is_read = function != "has_method"
                elif function == "Callable" and arg == 1:
                    target = receiver(tokens, first, first_comma)
                    is_read = True
            if probes or is_read:
                yield token, "string", target
        if token.kind != "punct":
            continue
        if token.value in ("(", "[", "{"):
            stack.append([i, i + 1, 0, i + 1])
        elif token.value in (")", "]", "}") and stack:
            stack.pop()
        elif token.value == "," and stack:
            if stack[-1][2] == 0:
                stack[-1][3] = i  # Callable's receiver ends at its first comma.
            stack[-1][2] += 1


def _named_functions(tokens: list[Token]):
    starts = [i for i, token in enumerate(tokens[:-2])
              if token.kind == "id" and token.value == "func"
              and tokens[i + 1].kind == "id" and tokens[i + 2].value == "("]
    for start, end in zip(starts, starts[1:] + [len(tokens)]):
        yield tokens[start + 1].value, tokens[start:end]


def _owner_names(tokens: list[Token], inherited: dict, members: set[str] | None = None) -> dict:
    """Track GDScript declarations and the simple aliases used by presentation code."""
    names = inherited.copy()
    aliases = []
    for i, token in enumerate(tokens):
        if token.kind != "id" or (members is not None and token.value not in members):
            continue
        if i >= 2 and tokens[i - 1].value == "." and tokens[i - 2].value != "self":
            continue
        j = i + 1
        if j < len(tokens) and tokens[j].value == ":":
            j += 1
            if j < len(tokens) and tokens[j].kind == "id":
                if i and tokens[i - 1].value in {"var", "(", ","}:
                    names[token.value] = OWNER_TYPES.get(tokens[j].value)
                j += 1
        if j >= len(tokens) or tokens[j].value != "=" or tokens[j:j + 2][-1].value == "=":
            continue
        j += 1
        owner_type = OWNER_TYPES.get(tokens[j].value) if j < len(tokens) else None
        while j < len(tokens) and tokens[j].kind == "id":
            name = tokens[j].value
            origin = j
            j += 1
            called = [t.value for t in tokens[j:j + 2]] == ["(", ")"]
            if called:
                j += 2
            if j >= len(tokens) or tokens[j].value != ".":
                if called and name in OWNER_FACTORIES:
                    names[token.value] = OWNER_FACTORIES[name]
                    if (name == "get_economy_facade" and origin >= 2
                            and tokens[origin - 1].value == "." and tokens[origin - 2].kind == "id"):
                        names.setdefault(tokens[origin - 2].value, "generator")
                elif called and name == "new" and owner_type:
                    names[token.value] = owner_type
                elif not called:
                    aliases.append((token.value, name))
                break
            j += 1
    missing = {name: alias for name, alias in aliases if not names.get(name)}
    while missing:
        resolved = {name: names[alias] for name, alias in missing.items() if names.get(alias)}
        if not resolved:
            break
        names.update(resolved)
        missing = {name: alias for name, alias in missing.items() if name not in resolved}
    return names


def _live_reads(tokens: list[Token], inherited: dict):
    names = _owner_names(tokens, inherited)
    positions = {token.offset: i for i, token in enumerate(tokens)}
    for token, kind, target in candidates(tokens, {"report", "get_economy_report"}, probes=False):
        expected = {"facade"} if token.value == "report" else {"generator", "native"}
        if names.get(target) in expected:
            yield token
        elif kind == "call":
            i = positions[token.offset]
            chain = [t.value for t in tokens[max(0, i - 4):i]]
            if len(chain) == 4 and chain[1:] == ["(", ")", "."] and OWNER_FACTORIES.get(chain[0]) in expected:
                yield token


def _function_digest(source: str, function: list[Token]) -> str:
    # Comments and blank lines can come and go. Preserve indentation and which
    # tokens share a line, since both matter in GDScript.
    lines = []
    previous = -1
    for token in function:
        line_start = source.rfind("\n", 0, token.offset) + 1
        if line_start != previous:
            lines.append([source[line_start:token.offset]])
            previous = line_start
        lines[-1].append((token.kind, token.value))
    return hashlib.sha256(json.dumps(lines, ensure_ascii=False).encode()).hexdigest()


def _probe_references(function: list[Token]) -> list[Token]:
    callable_strings = {token for token, _, _ in candidates(function, {PROBE}, probes=False)}
    return [token for i, token in enumerate(function) if token.value == PROBE and (
        (token.kind == "id" and (i == 0 or function[i - 1].value != "func")) or token in callable_strings
    )]


def _approved_consumer(source: str, name: str, function: list[Token], reads: list[Token]) -> bool:
    if name != "_process" or len(reads) != 1:
        return False
    start = source.rfind("\n", 0, reads[0].offset)
    after_call = [token for token in function if token.offset > start]
    return _function_digest(source, after_call) == HEARTBEAT_DIGEST


def historical_live_baseline(root: Path, ref: str) -> dict:
    source = historical_file(root, ref, f"{PROJECT}/{PLAYER_GAME}")
    if source is None:
        return {}
    text = source.decode("utf-8-sig")
    functions = dict(_named_functions(tokenize(text)))
    owner, consumer = functions.get(PROBE, []), functions.get("_process", [])
    if (_function_digest(text, owner) == PROBE_DIGEST
            and _approved_consumer(text, "_process", consumer, _probe_references(consumer))):
        return {PLAYER_GAME: {PROBE: PROBE_DIGEST}}
    return {}


def frontend_live_read_violations(
    file: str, source: str, baseline: dict, tokens: list[Token] | None = None,
    *, used: set[tuple[str, str]] | None = None,
) -> list[str]:
    """Find known live reads, including the GDScript facade around the native call."""
    frontend = file in FRONTEND_FILES or file.startswith(FRONTEND_DIRS)
    legacy_probe = PROBE in baseline.get(PLAYER_GAME, {}) and PROBE in source
    if not frontend and not legacy_probe:
        return []
    tokens = tokenize(source) if tokens is None else tokens
    errors = []
    member_names = {tokens[i + 1].value for i, token in enumerate(tokens[:-1]) if token.value == "var"
                    and token.kind == "id" and re.fullmatch(r"(?:@\w+ +)*", source[
                        source.rfind("\n", 0, token.offset) + 1:token.offset])}
    inherited = {name: "facade" for name in ECONOMY_FACADES}
    inherited.update({name: "native" for name in world_variables(tokens)})
    inherited = _owner_names(tokens, inherited, member_names)
    functions = list(_named_functions(tokens))
    if legacy_probe and tokens:
        before = [token for token in tokens if not functions or token.offset < functions[0][1][0].offset]
        functions.insert(0, ("class body", before))
    for name, function in functions:
        if legacy_probe:
            calls = _probe_references(function)
            if calls and not (file == PLAYER_GAME and _approved_consumer(source, name, function, calls)):
                line = source.count("\n", 0, calls[0].offset) + 1
                errors.append(f"{PROJECT}/{file}:{line}: {name} uses the live {PROBE} outside the unchanged heartbeat log")
        reads = list(_live_reads(function, inherited)) if frontend else []
        if not reads:
            continue
        if baseline.get(file, {}).get(name) == _function_digest(source, function):
            if used is not None:
                used.add((file, name))
            continue
        for token in reads:
            line = source.count("\n", 0, token.offset) + 1
            errors.append(f"{PROJECT}/{file}:{line}: {name} reads the live Economy report; "
                          "read the published frame instead")
    return errors


def directory_errors(root: Path, table: dict) -> list[str]:
    dirs = table.get("script_dirs", {})
    problems = []
    for module in sorted(set(table["modules"]) | set(dirs)):
        entries = dirs.get(module)
        if module not in table["modules"] or not isinstance(entries, list) or not entries:
            problems.append(f"script_dirs: module {module} must have a nonempty path list and exist in modules")
            continue
        for entry in entries:
            path = PurePosixPath(entry)
            if path.is_absolute() or not path.parts or ".." in path.parts or entry != path.as_posix():
                problems.append(f"script_dirs: {module}: invalid project-relative path {entry}")
            elif not (root / PROJECT / entry).exists():
                problems.append(f"script_dirs: {module}: missing path {entry}")
    return problems


def allowed(file: str, module: str, dirs: dict[str, list[str]]) -> bool:
    path = PurePosixPath(file)
    matches = [(len(PurePosixPath(entry).parts), owner)
               for owner, entries in dirs.items() for entry in entries
               if path == PurePosixPath(entry) or PurePosixPath(entry) in path.parents]
    if not file.endswith("_facade.gd"):
        return any(owner == module for _, owner in matches)
    # Facades belong to the deepest registered directory, so bakers cannot inherit
    # visual's parent-directory permission. Shared directories require a module prefix.
    deepest = max((depth for depth, _ in matches), default=0)
    owners = {owner for depth, owner in matches if depth == deepest}
    if len(owners) > 1:
        owners = {owner for owner in owners if path.name.startswith(owner + "_")}
    return module in owners


def inspect(root: Path) -> tuple[list[Reference], list[str], int]:
    rows, problems = inventory.inventory(root)  # Single source of binding names/modules.
    table = inventory.load_table(root)
    problems.extend(directory_errors(root, table))
    if problems:
        return [], problems, 0
    bindings = {b["name"]: b["module"] for b in rows}
    live_path = root / LIVE_BASELINE
    live_baseline = json.loads(live_path.read_text(encoding="utf-8")) if live_path.exists() else {}
    if live_path.exists():
        previous = previous_baseline(root, LIVE_BASELINE, bootstrap=historical_live_baseline)
        problems.extend(live_baseline_violations(live_baseline, previous))
        if problems:
            return [], problems, 0
    sources = [(p, p.read_text(encoding="utf-8")) for p in script_files(root)]
    parsed = [(p, source, tokenize(source)) for p, source in sources]
    functions = {tokens[i + 1].value for _, _, tokens in parsed
                 for i, t in enumerate(tokens[:-2]) if t.kind == "id" and t.value == "func"
                 and tokens[i + 1].kind == "id" and tokens[i + 2].value == "("}
    refs = []
    used = set()
    for path, source, tokens in parsed:
        world = world_variables(tokens)
        lines = source.splitlines()
        project_file = path.relative_to(root / PROJECT).as_posix()
        problems.extend(frontend_live_read_violations(project_file, source, live_baseline, tokens, used=used))
        for token, kind, target in candidates(tokens, bindings):
            line = source.count("\n", 0, token.offset) + 1
            a = target is not None and (target in world or bool(WORLD_NAME.search(target)))
            b = token.value not in functions
            refs.append(Reference(path.relative_to(root).as_posix(), line, token.value,
                                  bindings[token.value], kind, target, a, b,
                                  not allowed(project_file, bindings[token.value], table["script_dirs"]),
                                  lines[line - 1].strip()))
    for file, names in live_baseline.items():
        for name in names:
            if (file, name) not in used:
                problems.append(f"{LIVE_BASELINE}: remove unused live read exception: {file}:{name}")
    return refs, problems, len(sources)


def measure(refs: list[Reference]) -> dict[str, dict[str, int]]:
    counts: dict[str, Counter] = defaultdict(Counter)
    for ref in refs:
        if ref.counted and ref.outside:
            counts[ref.file][ref.module] += 1
    return {file: dict(sorted(counts[file].items())) for file in sorted(counts)}


def baseline_errors(baseline: dict) -> list[str]:
    if not isinstance(baseline, dict):
        return ["baseline: expected a file/module/count map"]
    problems = []
    for file, modules in baseline.items():
        if not isinstance(modules, dict) or not modules:
            problems.append(f"baseline: {file}: expected nonempty module/count map")
            continue
        for module, count in modules.items():
            if type(count) is not int or count <= 0:
                problems.append(f"baseline: {file}/{module}: expected positive integer")
    return problems


def live_baseline_violations(baseline: dict, previous: dict | None) -> list[str]:
    if not isinstance(baseline, dict):
        return [f"{LIVE_BASELINE}: expected a file/function/hash map"]
    errors = []
    for file, functions in baseline.items():
        if not isinstance(functions, dict) or not functions:
            errors.append(f"{LIVE_BASELINE}: expected function hashes for {file}")
            continue
        for name, digest in functions.items():
            if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
                errors.append(f"{LIVE_BASELINE}: invalid hash for {file}:{name}")
            elif previous is not None and previous.get(file, {}).get(name) != digest:
                errors.append(f"{LIVE_BASELINE}: live read exception added or changed: {file}:{name}")
    return errors


def violations(current: dict, baseline: dict) -> list[str]:
    return [f"{file}: {module}: {count} > baseline {baseline.get(file, {}).get(module, 0)}"
            for file, modules in current.items() for module, count in modules.items()
            if count > baseline.get(file, {}).get(module, 0)]


def reductions(current: dict, baseline: dict) -> list[str]:
    return [f"{file}: {module}: {count} -> {current.get(file, {}).get(module, 0)}"
            for file, modules in baseline.items() for module, count in modules.items()
            if current.get(file, {}).get(module, 0) < count]


def report(current: dict, modules: dict) -> None:
    print("script native access report (cross-module references):")
    for module in modules:
        files = [(file, counts[module]) for file, counts in current.items() if module in counts]
        print(f"{module}: {len(files)} files, {sum(count for _, count in files)} references")
        for file, count in sorted(files, key=lambda row: (-row[1], row[0]))[:5]:
            print(f"  {count:4} {file}")


def audit(refs: list[Reference]) -> None:
    counts = Counter((r.a, r.b) for r in refs)
    print(f"precision: {len(refs)} candidates; a=yes {sum(r.a for r in refs)}, a=no {sum(not r.a for r in refs)}; "
          f"b=yes {sum(r.b for r in refs)}, b=no {sum(not r.b for r in refs)}")
    print(f"counted: a-only {counts[True, False]}, b-only {counts[False, True]}, "
          f"both {counts[True, True]}; excluded: neither {counts[False, False]}")
    # Round-robin by decision/receiver/module/kind gives diverse, reproducible samples.
    for counted, title in ((True, "counted"), (False, "excluded")):
        buckets: dict[tuple, list[Reference]] = defaultdict(list)
        for ref in refs:
            if ref.counted == counted:
                buckets[(ref.a, ref.b, ref.receiver or "", ref.module, ref.kind)].append(ref)
        sample = []
        while buckets and len(sample) < 10:
            for decision in ((True, False), (False, True), (True, True), (False, False)):
                key = next((key for key in buckets if key[:2] == decision), None)
                if key is not None:
                    rows = buckets.pop(key)
                    sample.append(rows.pop(0))
                    if rows:
                        buckets[key] = rows
                    if len(sample) == 10:
                        break
        print(f"{title} samples ({len(sample)}):")
        for ref in sample:
            print(f"  {ref.file}:{ref.line} [{ref.module}/{ref.kind}; receiver={ref.receiver}; "
                  f"a={int(ref.a)} b={int(ref.b)}; outside={int(ref.outside)}] {ref.source}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=inventory.ROOT)
    parser.add_argument("--report", action="store_true")
    parser.add_argument("--audit", action="store_true")
    parser.add_argument("--write-baseline", action="store_true")
    args = parser.parse_args()
    try:
        refs, problems, files = inspect(args.root)
        current = measure(refs)
        path = args.root / BASELINE
        if path.exists():
            baseline = json.loads(path.read_text(encoding="utf-8"))
            problems.extend(baseline_errors(baseline))
        elif args.write_baseline:
            baseline = {}
        else:
            baseline = {}
            problems.append(f"missing {BASELINE}; use --write-baseline for initial capture")
        previous = previous_baseline(args.root, BASELINE)
        if not problems and previous is not None:
            problems.extend(baseline_errors(previous))
            if not problems:
                proposed = baseline if path.exists() else current
                problems.extend(f"{BASELINE}: cannot increase historical native access allowance: {change}"
                                for change in violations(proposed, previous))
        if not problems:
            if path.exists() or not args.write_baseline:
                problems.extend(violations(current, baseline))
            if not problems and args.write_baseline:
                path.write_text(json.dumps(current, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
                print(f"wrote {BASELINE} (initial capture or tightening only)")
            elif not args.write_baseline:
                for reduction in reductions(current, baseline):
                    print(f"can tighten baseline: {reduction}")
        if args.report:
            report(current, inventory.load_table(args.root)["modules"])
        if args.audit:
            audit(refs)
        for problem in problems:
            print(problem, file=sys.stderr)
        print(f"script native access guard: {files} scripts; {sum(r.counted for r in refs)} native references; "
              f"{len(current)} files / {sum(map(len, current.values()))} file-module pairs / "
              f"{sum(sum(m.values()) for m in current.values())} cross-module references; {len(problems)} problems")
        return int(bool(problems))
    except (OSError, ValueError, TypeError, KeyError, subprocess.CalledProcessError) as error:
        print(f"script native access guard: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
