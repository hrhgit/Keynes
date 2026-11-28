#!/usr/bin/env python3
"""Require separate key fields for Economy tax default-row caches."""

import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

from check_cpp_deps import code_only


ROOT = Path(__file__).resolve().parents[2]
BASELINE = Path("tools/ci/tax_row_keys_baseline.json")
SRC = Path("gdext/src")
# Match uses of map keys. A map declaration by itself says nothing about
# whether callers pack fields or use a genuine scalar ID.
INTEGER = r"(?:std::)?(?:u?int(?:8|16|32|64)_t|size_t)|(?:(?:unsigned|signed)\s+)?(?:char|int|short|long(?:\s+long)?)|unsigned|signed"
TYPEDEF = re.compile(r"\busing\s+(\w+)\s*=\s*([\w: ]+)\s*;|\btypedef\s+([\w: ]+)\s+(\w+)\s*;")
MAP = re.compile(
    r"\b(?:using\s+(?P<alias>\w+)\s*=\s*)?(?:std::)?(?:unordered_map|map)"
    r"\s*<\s*(?P<key>[\w: ]+)\s*,[^;{}]+>\s*(?P<name>\w+)?\s*[;{=]"
)
ACCESS = re.compile(
    r"\b(?P<table>\w+)\s*(?:\[|\.\s*(?P<method>at|count|contains|find|"
    r"insert|emplace|emplace_hint|try_emplace|insert_or_assign|lower_bound|"
    r"upper_bound)\s*\()"
)
INSERT_PAIR = re.compile(
    r"\s*(?:\{|(?:std\s*::\s*)?(?:make_pair\s*\(|pair\s*(?:<[^<>{}]+>\s*)?\{))\s*"
)
ROW = re.compile(r"row", re.IGNORECASE)
DEFAULT_ROWS = re.compile(r"tax.*default.*row")
LEGACY_CACHE = "settlement_default_rows"
LEGACY_PATH = "gdext/src/economy_runtime_country_epoch_capture_tax_rows.inc"


def _scalar_tables(codes) -> set[str]:
    aliases = {name or other: (source or old).strip() for code in codes
               for name, source, old, other in TYPEDEF.findall(code)}
    integers = set()
    while True:
        known = {alias for alias, target in aliases.items()
                 if re.fullmatch(INTEGER, target) or target in integers}
        if known == integers:
            break
        integers = known
    tables = set()
    for code in codes:
        for declaration in MAP.finditer(code):
            key = declaration["key"].strip()
            if key not in integers and not re.fullmatch(INTEGER, key):
                continue
            if declaration["name"]:
                tables.add(declaration["name"])
            if declaration["alias"]:
                name = re.escape(declaration["alias"])
                for unit in codes:
                    tables.update(re.findall(rf"\b{name}\s+(\w+)\s*[;{{=]", unit))
    return tables


def _legacy_identity(code: str) -> str:
    # Preserve the checked-in fingerprint of the declaration and key bits.
    # Which cells reach this cache is tested by the settlement regression.
    declaration = re.search(r"std::unordered_map\s*<[^;]+>\s*settlement_default_rows\s*(?=;)", code)
    if not declaration:
        return ""
    evidence = [declaration[0], *re.findall(r"\bsettlement_key\s*=\s*[^;]+;", code),
                *re.findall(r"\bsettlement_default_rows\s*\[[^\]]+\]", code)]
    normalized = "\n".join(re.sub(r"\s+", "", part) for part in evidence)
    return hashlib.sha256(normalized.encode("utf-8")).hexdigest()


DELIMITERS = re.compile(r"[(){}\[\],;]")


def _arguments(code: str, start: int, closing: str) -> list[str] | None:
    """Read the arguments at a cache use, keeping nested expressions intact."""
    argument_start = start
    stack = []
    arguments = []
    for token in DELIMITERS.finditer(code, start):
        value = token[0]
        end = token.start()
        if value in "([{":
            stack.append({"(": ")", "[": "]", "{": "}"}[value])
        elif value in ")]}":
            if stack:
                if stack.pop() != value:
                    return None
            elif value == closing:
                arguments.append(code[argument_start:end].strip())
                return arguments
            else:
                return None
        elif value == ";":
            if "}" not in stack:
                return None
        elif not stack:
            arguments.append(code[argument_start:end].strip())
            argument_start = end + 1
    return None


def _key_expression(code: str, access: re.Match) -> str | None:
    method = access["method"]
    args = _arguments(code, access.end(), ")" if method else "]")
    if args is None:
        return None
    if not args[0]:
        return "" if method == "emplace" else None
    if method == "emplace_hint":
        return args[1] if len(args) >= 2 else None
    if method == "insert":
        pair = INSERT_PAIR.match(code, access.end())
        if pair:
            closing = ")" if pair[0].strip().endswith("(") else "}"
            members = _arguments(code, pair.end(), closing)
            return members[0] if members else None
        # An iterator range or pair variable provides no direct key expression.
        return ""
    return args[0]


def _packed_expression(code: str, access: re.Match, key: str) -> str:
    if re.fullmatch(r"\w+", key):
        # Inspect the immediately preceding definition of this key. Normal
        # C++ direct-list initializers and ordinary assignments share a case.
        name = re.escape(key)
        definitions = re.compile(
            rf"\b{name}\s*(?:=(?!=)\s*([^;{{}}]+);|\{{([^;{{}}]+)\}}\s*;)",
        ).finditer(code, 0, access.start())
        for definition in definitions:
            between = code[definition.end():access.start()]
            # Nested blocks may use this definition. Leaving the block
            # that declared it ends its lifetime, including in another function.
            nested = 0
            for brace in re.finditer(r"[{}]", between):
                nested += 1 if brace[0] == "{" else -1
                if nested < 0:
                    break
            else:
                key = definition[1] or definition[2]
    return key if "," not in key and "<<" in key and re.search(r"(?<!\|)\|(?!\|)", key) else ""


def _packed_uses(path: str, code: str, tables: set[str]):
    default_rows = DEFAULT_ROWS.search(Path(path).stem)
    for access in ACCESS.finditer(code):
        name = access["table"]
        if name not in tables:
            continue
        key = _key_expression(code, access)
        line = code.count("\n", 0, access.start()) + 1
        if key is None:
            yield line, name, None, "incomplete map access"
            continue
        packed = _packed_expression(code, access, key)
        # Other policy tables pair two complete 32-bit IDs. The historical
        # amount/mode packing is recognizable even when all names change.
        if packed and (default_rows or ROW.search(name) or packed.count("<<") >= 2):
            identity = _legacy_identity(code) if path == LEGACY_PATH and name == LEGACY_CACHE else None
            yield line, name, identity, ""


def tax_row_key_violations(sources: dict[str, str], baseline: dict[str, list[str]]) -> tuple[list[str], dict[str, list[str]]]:
    errors = []
    retained = {}
    codes = {path: code_only(source) for path, source in sources.items()}
    tables = _scalar_tables(codes.values())
    for path, code in sorted(codes.items()):
        allowed = Counter(baseline.get(path, []))
        for line, name, identity, problem in _packed_uses(path, code, tables):
            if problem:
                errors.append(f"{path}:{line}: {problem} for {name}")
            elif identity is not None and allowed[identity]:
                allowed[identity] -= 1
                retained.setdefault(path, []).append(identity)
            else:
                errors.append(f"{path}:{line}: {name} uses a scalar tax row key; keep country, kind, amount and mode as separate key fields")
    return errors, retained


def _git(root: Path, *args: str) -> str:
    return subprocess.check_output(["git", *args], cwd=root, encoding="utf-8").strip()


def _read_baseline(content: str) -> dict[str, list[str]]:
    try:
        data = json.loads(content)
    except json.JSONDecodeError as exc:
        raise ValueError(f"{BASELINE}:{exc.lineno}: {exc.msg}") from exc
    if not isinstance(data, dict):
        raise ValueError(f"{BASELINE}:1: expected an object mapping source paths to fingerprints")
    for path, keys in data.items():
        if (not isinstance(keys, list) or not all(isinstance(key, str)
                and re.fullmatch(r"[0-9a-f]{64}", key) for key in keys)):
            pos = content.find(json.dumps(path))
            line = content.count("\n", 0, max(0, pos)) + 1
            raise ValueError(f"{BASELINE}:{line}: expected fingerprint strings for {path}")
    return data


def _base_baseline(root: Path, base: str) -> dict[str, list[str]]:
    if _git(root, "ls-tree", "--name-only", base, "--", BASELINE.as_posix()):
        return _read_baseline(_git(root, "show", f"{base}:{BASELINE.as_posix()}"))
    # First introduction: only the known settlement cache already on the
    # base can be registered. Subsequent changes compare to the base file.
    if _git(root, "ls-tree", "--name-only", base, "--", LEGACY_PATH):
        source = _git(root, "show", f"{base}:{LEGACY_PATH}")
        code = code_only(source)
        identities = [key for _, name, key, _ in _packed_uses(LEGACY_PATH, code, {LEGACY_CACHE})
                      if name == LEGACY_CACHE and key]
        if len(identities) == 1:
            return {LEGACY_PATH: identities}
    return {}


def validate_tax_row_baseline(baseline: dict[str, list[str]], base: dict[str, list[str]]) -> list[str]:
    """Report entries absent from the comparison commit or repeated more often."""
    return [f"{BASELINE}: cannot add baseline entries for {path}"
            for path, keys in sorted(baseline.items())
            if Counter(keys) - Counter(base.get(path, []))]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--base", default=os.environ.get("KEYNES_GUARD_BASE_REF"))
    parser.add_argument("--ratchet", action="store_true", help="remove resolved entries from the baseline")
    args = parser.parse_args()
    try:
        return _run(args)
    except (ValueError, OSError, subprocess.CalledProcessError) as exc:
        print(str(exc))
        return 1


def _run(args) -> int:
    baseline_path = args.root / BASELINE
    baseline = _read_baseline(baseline_path.read_text(encoding="utf-8"))
    sources = {path.relative_to(args.root).as_posix(): path.read_text(encoding="utf-8")
               for path in (args.root / SRC).glob("economy*tax*")
               if path.suffix in {".cpp", ".h", ".inc"}}
    errors, retained = tax_row_key_violations(sources, baseline)
    base = args.base
    if not base and (args.root / ".git").exists():
        base = _git(args.root, "merge-base", "HEAD", "origin/master")
    if base:
        errors.extend(validate_tax_row_baseline(baseline, _base_baseline(args.root, base)))
    if not errors and retained != baseline:
        if args.ratchet:
            baseline_path.write_text(json.dumps(retained, indent=2) + "\n", encoding="utf-8")
        else:
            errors.append(f"{BASELINE}: remove resolved entries with --ratchet")
    print(f"tax row keys: {len(sources)} files, {sum(map(len, retained.values()))} baseline entries, {len(errors)} violations")
    for error in errors:
        print(error)
    return int(bool(errors))


if __name__ == "__main__":
    raise SystemExit(main())
