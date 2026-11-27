#!/usr/bin/env python3
"""Regenerate the two text manifests in memory and compare their bytes."""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path, PurePosixPath

import world_ext_bindings as bindings
from guard_baselines import previous_baseline

PROJECT = "Project/project-keynes"
BAKE = f"{PROJECT}/tools/loading_catalog_bake.gd"
CACHE = f"{PROJECT}/scripts/game/loading_catalog_cache.gd"
BASELINE = "tools/ci/generated_manifests_baseline.json"
BAKE_COMMAND = "godot --headless --path Project/project-keynes --script res://tools/prebake_loading_catalogs.gd"


def validate_binding_manifest_bytes(actual: bytes, current_bindings: list[dict]) -> list[str]:
    if actual == bindings.manifest_bytes(current_bindings):
        return []
    return [f"{bindings.MANIFEST}: bytes differ from regenerated bindings; "
            "run python tools/ci/world_ext_bindings.py --write-manifest"]


def _catalog_recipe(root: Path) -> tuple[tuple[str, ...], set[str], str]:
    # Read the producer's literal directory/extension lists so updating the
    # bake's source set also updates the static check.
    bake = (root / BAKE).read_text(encoding="utf-8")
    cache = (root / CACHE).read_text(encoding="utf-8")
    directories = re.search(r"(?m)^\tfor dir in (\[[^\n]+\]):\n\t\t_collect_sources\(dir, files\)$", bake)
    extensions = re.search(r"(?m)^\t\tif name\.get_extension\(\) in (\[[^\n]+\]):$", bake)
    output = re.search(r'(?m)^const DIRECTORY := "res://([\w/]+)/"$', cache)
    encoding = re.search(r'file\.store_string\(JSON\.stringify\(files,\s*"\\t",\s*true\)\)', bake)
    if not all((directories, extensions, output, encoding)):
        raise ValueError(f"{BAKE}: unrecognized catalog source-list generator")
    directories_list = json.loads(directories[1])
    extensions_list = json.loads(extensions[1])
    if not directories_list or any(
        not isinstance(value, str) or not re.fullmatch(r"res://[\w/]+", value)
        for value in directories_list
    ):
        raise ValueError(f"{BAKE}: invalid source directories")
    if not extensions_list or any(
        not isinstance(value, str) or not re.fullmatch(r"\w+", value)
        for value in extensions_list
    ):
        raise ValueError(f"{BAKE}: invalid source extensions")
    return tuple(value[6:].rstrip("/") + "/" for value in directories_list), set(extensions_list), output[1]


def _catalog_fingerprints(root: Path, directories: tuple[str, ...], extensions: set[str],
                          output: str) -> dict[str, str]:
    files = subprocess.check_output(
        ["git", "ls-files", "-z", "--", *(f"{PROJECT}/{path}" for path in directories)], cwd=root,
    ).decode("utf-8").split("\0")
    fingerprints = {}
    for file in filter(None, files):
        relative = PurePosixPath(file).relative_to(PROJECT)
        if (relative.is_relative_to(output)
            or relative.suffix[1:] not in extensions
            or any(part.startswith(".") for part in relative.parts)):
            continue
        fingerprints[f"res://{relative}"] = hashlib.sha256((root / file).read_bytes()).hexdigest()
    return fingerprints


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
    root = parser.parse_args().root
    baselined = []
    try:
        current, errors = bindings.inventory(root)
        errors.extend(validate_binding_manifest_bytes((root / bindings.MANIFEST).read_bytes(), current))
        directories, extensions, output = _catalog_recipe(root)
        catalog = f"{PROJECT}/{output}/sources.json"
        fingerprints = _catalog_fingerprints(root, directories, extensions, output)
        baseline = _historical_catalog_sources(root)
        previous = previous_baseline(root, BASELINE)
        if previous is not None:
            errors.extend(f"{BASELINE}: new or changed historical entry: {path}"
                          for path, hashes in baseline.items() if previous.get(path) != hashes)
        differences, baselined = validate_catalog_manifest_bytes((root / catalog).read_bytes(), fingerprints, baseline)
        errors.extend(f"{catalog}: {difference}" for difference in differences)
        if differences:
            errors.append(f"regenerate the loading catalog with: {BAKE_COMMAND}")
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        errors = [str(error)]
    for difference in baselined:
        print(f"catalog sources baseline: {difference}")
    for error in errors:
        print(error, file=sys.stderr)
    print(f"generated manifests: {len(errors)} violations, {len(baselined)} historical mismatches")
    return int(bool(errors))


if __name__ == "__main__":
    sys.exit(main())
