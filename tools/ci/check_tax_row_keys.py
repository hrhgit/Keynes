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
SCALAR = (r"(?:std\s*::\s*)?(?:u?int(?:8|16|32|64)_t|size_t|ptrdiff_t|"
          r"(?:signed\s+|unsigned\s+)?(?:short|int|long(?:\s+long)?|char)|signed|unsigned|bool)")
TYPE_NAME = r"(?:[A-Za-z_]\w*\s*::\s*)*[A-Za-z_]\w*"
KEY_TYPE = rf"(?:{SCALAR}|{TYPE_NAME})"
CXX_ALIAS = re.compile(
    rf"\busing\s+(?P<alias>\w+)\s*=\s*(?P<type>{KEY_TYPE})\s*;"
    rf"|\btypedef\s+(?P<old_type>{KEY_TYPE})\s+(?P<typedef>\w+)\s*;"
)
CACHE = re.compile(
    rf"\b(?:using\s+(?P<alias>\w+)\s*=\s*)?(?:std\s*::\s*)?(?:unordered_map|map)"
    rf"\s*<\s*(?P<key>{KEY_TYPE})\s*,\s*(?P<value>[\w:]+)"
    r"(?:\s*,\s*[^;{}]*?)?\s*>\s*(?P<name>\w+)?\s*(?=[;{=])"
)
ROW = re.compile(r"(?:^|_)rows?(?:_|$)|Rows?(?:[A-Z]|$)")
DEFAULT_ROWS = re.compile(r"tax.*default.*row")
ID_VALUE = re.compile(r"(?i:(?:^|_)(?:id|handle)$)|(?:Id|ID|Handle)$")
ID_LITERAL = r"(?:0[xX][0-9a-fA-F]+|[0-9]+)[uUlL]*"
ID_EXPRESSION = re.compile(rf"([A-Za-z_]\w*(?:\s*(?:\.|->)\s*[A-Za-z_]\w*)*|{ID_LITERAL})\s*(?=[,\])}}])")
INSERT_PAIR = re.compile(
    r"(?:\{|(?:std\s*::\s*)?(?:make_pair\s*\(|pair\s*(?:<[^<>{}]+>\s*)?\{))\s*"
)
PACKING = re.compile(r"<<|>>|(?<!\|)\|(?!\|)|(?<!&)&(?!&)")
LEGACY_CACHE = "settlement_default_rows"
LEGACY_PATH = "gdext/src/economy_runtime_country_epoch_capture_tax_rows.inc"
LEGACY_SELECTOR = (
    "row_number=display_only?display_default_rows[std::make_tuple(country,kind,base_rate,base_mode)]"
    ":settlement_default_rows[settlement_key];"
)
LEGACY_CALLS = (
    "ensure_default_row(country,kind,resolved_rate,resolved_mode,display_only);",
    "compile_cell_policy(cell,false);",
    "compile_cell_policy(cell,false);",
    "compile_cell_policy(cell,true);",
)


def _identity(name: str, declaration: str, code: str) -> str:
    evidence = [declaration]
    if name == LEGACY_CACHE:
        # The one existing exception is tied to both the scalar map and the
        # exact field packing used at its access site. The caller also checks
        # the settlement-only route before this identity can use the baseline.
        evidence.extend(re.findall(r"\bsettlement_key\s*=\s*[^;]+;", code))
        evidence.extend(re.findall(r"\bsettlement_default_rows\s*\[[^\]]+\]", code))
    normalized = "\n".join(re.sub(r"\s+", "", part) for part in evidence)
    return hashlib.sha256(normalized.encode("utf-8")).hexdigest()


def _integer_aliases(code: str) -> set[str]:
    alias_types = {match["alias"] or match["typedef"]: match["type"] or match["old_type"]
                   for match in CXX_ALIAS.finditer(code)}
    aliases = set()
    while True:
        recognized = {alias for alias, key in alias_types.items()
                      if re.fullmatch(SCALAR, key) or key in aliases}
        if recognized == aliases:
            return aliases
        aliases = recognized


def _legacy_settlement_only(code: str) -> bool:
    selector = re.search(r"\brow_number\s*=\s*[^;]+;", code)
    if not selector or re.sub(r"\s+", "", selector[0]) != LEGACY_SELECTOR:
        return False
    calls = re.findall(r"\b(?:ensure_default_row|compile_cell_policy)\s*\([^;{}]+\)\s*;", code)
    # The packed cache is declared once and used only by that selector.
    return len(re.findall(rf"\b{LEGACY_CACHE}\b", code)) == 2 and tuple(
        re.sub(r"\s+", "", call) for call in calls
    ) == LEGACY_CALLS


def _single_id_index(name: str, code: str) -> bool:
    """Recognize tables whose observed lookup and insertion keys are IDs."""
    accesses = re.compile(
        rf"\b{re.escape(name)}\s*(?:\[\s*|\.\s*"
        r"(?P<method>at|count|contains|find|insert|emplace|try_emplace|insert_or_assign|lower_bound|upper_bound)"
        r"\s*\(\s*)"
    )
    seen_key = False
    for access in accesses.finditer(code):
        start = access.end()
        if access["method"] == "insert":
            # Standard insert takes a pair. Keep the lookup exemption tied to
            # the inserted key as well, regardless of what the table is named.
            pair = INSERT_PAIR.match(code, start)
            if not pair:
                return False
            start = pair.end()
        expression = ID_EXPRESSION.match(code, start)
        if not expression:
            return False
        seen_key = True
        key = expression[1]
        if re.fullmatch(ID_LITERAL, key):
            continue
        if not ID_VALUE.search(re.split(r"\.|->", key)[-1].strip()):
            return False
        for definition in re.finditer(rf"\b{re.escape(key)}\s*=(?!=)\s*([^;]+);", code):
            if PACKING.search(definition[1]):
                return False
    return seen_key


def _scalar_caches(path: str, source: str):
    code = code_only(source)
    default_row_scope = DEFAULT_ROWS.search(Path(path).stem)
    aliases = _integer_aliases(code)
    for declaration in CACHE.finditer(code):
        key = declaration["key"]
        if not re.fullmatch(SCALAR, key) and key not in aliases:
            continue
        name = declaration["alias"] or declaration["name"]
        if (name and (default_row_scope or ROW.search(name) or ROW.search(declaration["value"]))
                and not _single_id_index(name, code)):
            line = code.count("\n", 0, declaration.start()) + 1
            identity = _identity(name, declaration[0], code)
            if name == LEGACY_CACHE and not _legacy_settlement_only(code):
                identity = None
            yield line, name, identity


def tax_row_key_violations(sources: dict[str, str], baseline: dict[str, list[str]]) -> tuple[list[str], dict[str, list[str]]]:
    errors = []
    retained = {}
    for path, source in sorted(sources.items()):
        allowed = Counter(baseline.get(path, []))
        for line, name, identity in _scalar_caches(path, source):
            if identity is not None and allowed[identity]:
                allowed[identity] -= 1
                retained.setdefault(path, []).append(identity)
            else:
                errors.append(f"{path}:{line}: {name} uses a scalar tax row key; keep country, kind, amount and mode as separate key fields")
    return errors, retained


def _git(root: Path, *args: str) -> str:
    return subprocess.check_output(["git", *args], cwd=root, encoding="utf-8").strip()


def _base_baseline(root: Path, base: str) -> dict[str, list[str]]:
    if _git(root, "ls-tree", "--name-only", base, "--", BASELINE.as_posix()):
        return json.loads(_git(root, "show", f"{base}:{BASELINE.as_posix()}"))
    # First introduction: only the known settlement cache already on the
    # base can be registered. Subsequent changes compare to the base file.
    if _git(root, "ls-tree", "--name-only", base, "--", LEGACY_PATH):
        source = _git(root, "show", f"{base}:{LEGACY_PATH}")
        identities = [key for _, name, key in _scalar_caches(LEGACY_PATH, source)
                      if name == LEGACY_CACHE and key is not None]
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
    baseline_path = args.root / BASELINE
    baseline = json.loads(baseline_path.read_text(encoding="utf-8"))
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
