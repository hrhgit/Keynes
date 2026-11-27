#!/usr/bin/env python3
"""Regenerate the two text manifests in memory and compare their bytes."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path, PurePosixPath

import world_ext_bindings as bindings
from guard_baselines import historical_file, previous_baseline

PROJECT = "Project/project-keynes"
BAKE = f"{PROJECT}/tools/loading_catalog_bake.gd"
CACHE = f"{PROJECT}/scripts/game/loading_catalog_cache.gd"
BASELINE = "tools/ci/generated_manifests_baseline.json"
BAKE_COMMAND = "godot --headless --path Project/project-keynes --script res://tools/prebake_loading_catalogs.gd"
NATIVE_BINDING_SOURCE = "res://data/native_binding_manifest.json"
COLLECTOR = re.compile(r"^static\s+func\s+_collect_sources\s*\(")
SOURCE_TOKEN = re.compile(r'"(?:\\.|[^"\\])*"|#.*|\w+|->|:=|==|[^\s]')
# The Python walk below mirrors these steps. Accept formatting and local-name
# changes and read the extension list from the collector itself.
COLLECTOR_SHAPE = re.compile(
    r'static func _collect_sources \( (?P<directory>\w+) : String , (?P<files>\w+) : Dictionary \) -> void :\n'
    r'1 if (?P=directory) == Cache \. DIRECTORY \. trim_suffix \( "/" \) :\n'
    r'2 return\n'
    r'1 var (?P<access>\w+) (?:: DirAccess )?:?= DirAccess \. open \( (?P=directory) \)\n'
    r'1 if (?P=access) == null :\n'
    r'2 return\n'
    r'1 for (?P<file>\w+) in (?P=access) \. get_files \( \) :\n'
    r'2 if (?P=file) \. get_extension \( \) in (?P<extensions>\[ .* \]) :\n'
    r'3 var (?P<path>\w+) (?:: String )?:?= (?P=directory) \+ "/" \+ (?P=file)\n'
    r'3 (?P=files) \[ (?P=path) \] = FileAccess \. get_sha256 \( (?P=path) \)\n'
    r'1 for (?P<child>\w+) in (?P=access) \. get_directories \( \) :\n'
    r'2 _collect_sources \( (?P=directory) \+ "/" \+ (?P=child) , (?P=files) \)'
)


def validate_binding_manifest_bytes(actual: bytes, current_bindings: list[dict]) -> list[str]:
    if actual == bindings.manifest_bytes(current_bindings):
        return []
    return [f"{bindings.MANIFEST}: bytes differ from regenerated bindings; "
            "run python tools/ci/world_ext_bindings.py --write-manifest"]


def _catalog_recipe(root: Path) -> tuple[tuple[str, ...], set[str], str]:
    return _recipe_from_text((root / BAKE).read_text(encoding="utf-8"),
                             (root / CACHE).read_text(encoding="utf-8"))


def validate_catalog_collector(bake: str) -> set[str]:
    """Read the extension set only after checking the actual collector body."""
    collector = []
    indentation = [0]
    for line in bake.splitlines():
        if not collector and not COLLECTOR.match(line):
            continue
        code = " ".join(token[0] for token in SOURCE_TOKEN.finditer(line)
                        if not token[0].startswith("#"))
        if not collector:
            collector.append(code)
            continue
        if not code:
            continue
        expanded = line.expandtabs(4)
        indent = len(expanded) - len(expanded.lstrip())
        if not indent:
            break
        if indent > indentation[-1]:
            indentation.append(indent)
        while indent < indentation[-1]:
            indentation.pop()
        if indent != indentation[-1]:
            break
        collector.append(f"{len(indentation) - 1} {code}")
    shape = COLLECTOR_SHAPE.fullmatch("\n".join(collector))
    if not shape:
        raise ValueError(f"{BAKE}: _collect_sources changed; keep the static catalog walk in sync")
    extensions = json.loads(shape["extensions"])
    if not extensions or any(
        not isinstance(value, str) or not re.fullmatch(r"\w+", value) for value in extensions
    ):
        raise ValueError(f"{BAKE}: invalid source extensions")
    return set(extensions)


def _recipe_from_text(bake: str, cache: str) -> tuple[tuple[str, ...], set[str], str]:
    # Read the producer's literal directory/extension lists so updating the
    # bake's source set also updates the static check.
    directories = re.search(r"(?m)^\tfor dir in (\[[^\n]+\]):\n\t\t_collect_sources\(dir, files\)$", bake)
    output = re.search(r'(?m)^const DIRECTORY := "res://([\w/]+)/"$', cache)
    encoding = re.search(r'file\.store_string\(JSON\.stringify\(files,\s*"\\t",\s*true\)\)', bake)
    if not all((directories, output, encoding)):
        raise ValueError(f"{BAKE}: unrecognized catalog source-list generator")
    directories_list = json.loads(directories[1])
    if not directories_list or any(
        not isinstance(value, str) or not re.fullmatch(r"res://[\w/]+", value)
        for value in directories_list
    ):
        raise ValueError(f"{BAKE}: invalid source directories")
    directories = tuple(value[6:].rstrip("/") + "/" for value in directories_list)
    return directories, validate_catalog_collector(bake), output[1]


def _catalog_fingerprints(root: Path, directories: tuple[str, ...], extensions: set[str],
                          output: str) -> dict[str, str]:
    files = subprocess.check_output(
        ["git", "ls-files", "-t", "--stage", "-z", "--", *(f"{PROJECT}/{path}" for path in directories)], cwd=root,
    ).decode("utf-8").split("\0")
    fingerprints = {}
    for entry in filter(None, files):
        metadata, file = entry.split("\t", 1)
        relative = PurePosixPath(file).relative_to(PROJECT)
        if (relative.is_relative_to(output)
            or relative.suffix[1:] not in extensions
            or any(part.startswith(".") for part in relative.parts)):
            continue
        tag, mode, object_id, stage = metadata.split()
        if stage != "0":
            raise ValueError(f"{file}: unresolved source in the Git index")
        try:
            source = (root / file).read_bytes()
        except FileNotFoundError:
            if tag != "S" or mode not in {"100644", "100755"}:
                raise
            # Sparse checkout can omit a tracked source when the bake adds
            # an extension. Use the same filters as a regular checkout.
            source = subprocess.check_output(
                ["git", "cat-file", "--filters", f"--path={file}", object_id], cwd=root,
            )
        fingerprints[f"res://{relative}"] = hashlib.sha256(source).hexdigest()
    return fingerprints


def catalog_baseline_at(root: Path, ref: str) -> dict[str, list[str]]:
    """Recover only the original native-binding fingerprint mismatch from Git."""
    bake = historical_file(root, ref, BAKE)
    cache = historical_file(root, ref, CACHE)
    binding_manifest = historical_file(root, ref, bindings.MANIFEST)
    if bake is None or cache is None or binding_manifest is None:
        return {}
    directories, extensions, output = _recipe_from_text(bake.decode("utf-8"), cache.decode("utf-8"))
    if "data/" not in directories or "json" not in extensions:
        return {}
    catalog = historical_file(root, ref, f"{PROJECT}/{output}/sources.json")
    if catalog is None:
        return {}
    recorded = json.loads(catalog)
    expected = hashlib.sha256(binding_manifest).hexdigest()
    value = recorded.get(NATIVE_BINDING_SOURCE) if isinstance(recorded, dict) else None
    if isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value) and value != expected:
        return {NATIVE_BINDING_SOURCE: [value, expected]}
    return {}


def validate_catalog_manifest_bytes(actual: bytes, fingerprints: dict[str, str],
                                    exceptions: dict[str, list[str]]) -> tuple[list[str], list[str]]:
    """Return errors and the exact historical mismatches still present."""
    try:
        recorded = json.loads(actual)
    except ValueError as error:
        return [f"invalid JSON: {error}"], []
    if not isinstance(recorded, dict):
        return ["catalog source manifest must be a JSON object"], []
    errors = []
    baselined = []
    expected = fingerprints.copy()
    for source, hashes in exceptions.items():
        if recorded.get(source) == hashes[0] and fingerprints.get(source) == hashes[1]:
            expected[source] = hashes[0]
            baselined.append(f"{source}: recorded {hashes[0]}, actual {hashes[1]}")
        else:
            errors.append(f"{source}: historical mismatch changed; remove its entry from {BASELINE}")
    for source in sorted(recorded.keys() - expected.keys()):
        errors.append(f"{source}: extra entry in catalog sources")
    for source in sorted(expected.keys() - recorded.keys()):
        errors.append(f"{source}: missing from catalog sources")
    for source in sorted(expected.keys() & recorded.keys()):
        if recorded[source] != expected[source]:
            errors.append(f"{source}: recorded {recorded[source]}, actual {fingerprints[source]}")
    regenerated = json.dumps(expected, ensure_ascii=False, indent="\t", sort_keys=True).encode("utf-8")
    if not errors and actual != regenerated:
        errors.append("bytes differ from regenerated catalog sources")
    return errors, baselined


def _historical_catalog_sources(root: Path) -> dict[str, list[str]]:
    table = json.loads((root / BASELINE).read_bytes())
    if not isinstance(table, dict) or any(
        not path.startswith("res://")
        or not isinstance(hashes, list)
        or len(hashes) != 2
        or hashes[0] == hashes[1]
        or any(not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value) for value in hashes)
        for path, hashes in table.items()
    ):
        raise ValueError(f"{BASELINE}: expected an exact pair of different SHA-256 digests per source")
    return table


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=bindings.ROOT)
    parser.add_argument("--require-clean-catalog", action="store_true",
                        help="fail if the editor would reject even a known stale catalog fingerprint")
    args = parser.parse_args()
    root = args.root
    baselined = []
    catalog = ""
    try:
        current, errors = bindings.inventory(root)
        errors.extend(validate_binding_manifest_bytes((root / bindings.MANIFEST).read_bytes(), current))
        directories, extensions, output = _catalog_recipe(root)
        catalog = f"{PROJECT}/{output}/sources.json"
        fingerprints = _catalog_fingerprints(root, directories, extensions, output)
        baseline = _historical_catalog_sources(root)
        previous = previous_baseline(root, BASELINE, catalog_baseline_at)
        if previous is not None:
            errors.extend(f"{BASELINE}: new or changed historical entry: {path}"
                          for path, hashes in baseline.items() if previous.get(path) != hashes)
        differences, baselined = validate_catalog_manifest_bytes((root / catalog).read_bytes(), fingerprints, baseline)
        errors.extend(f"{catalog}: {difference}" for difference in differences)
        if differences:
            errors.append(f"regenerate the loading catalog with: {BAKE_COMMAND}")
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        errors = [str(error)]
    if baselined:
        message = "The editor will reject this prebaked catalog because of known stale fingerprints."
        if os.environ.get("GITHUB_ACTIONS") == "true":
            print(f"::warning file={catalog}::{message}")
        print(f"WARNING: {message} Regenerate with: {BAKE_COMMAND}", file=sys.stderr)
        for difference in baselined:
            print(f"catalog sources baseline: {difference}", file=sys.stderr)
        if args.require_clean_catalog:
            errors.append(f"{catalog}: --require-clean-catalog requires every fingerprint to match")
    for error in errors:
        print(error, file=sys.stderr)
    print(f"generated manifests: {len(errors)} violations, {len(baselined)} historical mismatches")
    return int(bool(errors))


if __name__ == "__main__":
    sys.exit(main())
