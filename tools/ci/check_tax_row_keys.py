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
CACHE = re.compile(
    rf"\b(?:using\s+(?P<alias>\w+)\s*=\s*)?(?:std\s*::\s*)?(?:unordered_map|map)"
    rf"\s*<\s*(?P<key>{SCALAR})\s*,\s*(?P<value>[\w:]+)"
    r"(?:\s*,\s*[^;{}]*?)?\s*>\s*(?P<name>\w+)?\s*(?=[;{=])"
)
ROW = re.compile(r"(?:^|_)rows?(?:_|$)|Rows?(?:[A-Z]|$)")
DEFAULT_ROWS = re.compile(r"tax.*default.*row")
LEGACY_CACHE = "settlement_default_rows"
LEGACY_PATH = "gdext/src/economy_runtime_country_epoch_capture_tax_rows.inc"


def _identity(name: str, declaration: str, code: str) -> str:
    evidence = [declaration]
    if name == LEGACY_CACHE:
        # The one existing exception is tied to both the scalar map and the
        # exact field packing used at its access site. Copying it, changing
        # the packed expression or changing its use consumes no exception.
        evidence.extend(re.findall(r"\bsettlement_key\s*=\s*[^;]+;", code))
        evidence.extend(re.findall(r"\bsettlement_default_rows\s*\[[^\]]+\]", code))
    normalized = "\n".join(re.sub(r"\s+", "", part) for part in evidence)
    return hashlib.sha256(normalized.encode("utf-8")).hexdigest()


def _scalar_caches(path: str, source: str):
    code = code_only(source)
    default_row_scope = DEFAULT_ROWS.search(Path(path).stem)
    for declaration in CACHE.finditer(code):
        name = declaration["alias"] or declaration["name"]
        if name and (default_row_scope or ROW.search(name) or ROW.search(declaration["value"])):
            line = code.count("\n", 0, declaration.start()) + 1
            yield line, name, _identity(name, declaration[0], code)


def tax_row_key_violations(sources: dict[str, str], baseline: dict[str, list[str]]) -> tuple[list[str], dict[str, list[str]]]:
    errors = []
    retained = {}
    for path, source in sorted(sources.items()):
        allowed = Counter(baseline.get(path, []))
        for line, name, identity in _scalar_caches(path, source):
            if allowed[identity]:
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
                      if name == LEGACY_CACHE]
        if len(identities) == 1:
            return {LEGACY_PATH: identities}
    return {}


def _baseline_growth(baseline: dict[str, list[str]], base: dict[str, list[str]]) -> list[str]:
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
        errors.extend(_baseline_growth(baseline, _base_baseline(args.root, base)))
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
