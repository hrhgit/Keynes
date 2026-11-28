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
INPUTS = f"{PROJECT}/tools/loading_catalog_sources.json"
CATALOG_DIR = "data/loading_catalog_v1"
CATALOG = f"{PROJECT}/{CATALOG_DIR}/sources.json"
BASELINE = "tools/ci/generated_manifests_baseline.json"
BAKE_COMMAND = "godot --headless --path Project/project-keynes --script res://tools/prebake_loading_catalogs.gd"
NATIVE_BINDING_SOURCE = "res://data/native_binding_manifest.json"


def validate_binding_manifest_bytes(actual: bytes, current_bindings: list[dict]) -> list[str]:
    if actual == bindings.manifest_bytes(current_bindings):
        return []
    return [f"{bindings.MANIFEST}: bytes differ from regenerated bindings; "
            "run python tools/ci/world_ext_bindings.py --write-manifest"]


def parse_catalog_inputs(source: str) -> tuple[tuple[str, ...], set[str]]:
    """Read the same declarative source list that the Godot baker loads."""
    try:
        inputs = json.loads(source)
    except json.JSONDecodeError as error:
        raise ValueError(f"{INPUTS}:{error.lineno}: {error.msg}") from error
    if not isinstance(inputs, dict):
        raise ValueError(f"{INPUTS}:1: expected a JSON object")
    for key in ("directories", "extensions"):
        values = inputs.get(key)
        if key == "directories":
            pattern = r"res://[^/]+(?:/[^/]+)*"
        else:
            pattern = r"[^./\s]+"
        if not isinstance(values, list) or not values or any(
            not isinstance(value, str) or not re.fullmatch(pattern, value)
            or (key == "directories" and any(part in {".", ".."} for part in value[6:].split("/")))
            for value in values
        ):
            key_offset = source.find(json.dumps(key))
            line = source.count("\n", 0, max(0, key_offset)) + 1
            raise ValueError(f"{INPUTS}:{line}: expected a nonempty list of source {key}")
    directories = tuple(value[6:] + "/" for value in inputs["directories"])
    return directories, set(inputs["extensions"])


def _catalog_recipe(root: Path) -> tuple[tuple[str, ...], set[str], str]:
    directories, extensions = parse_catalog_inputs((root / INPUTS).read_text(encoding="utf-8"))
    return directories, extensions, CATALOG_DIR


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
    binding_manifest = historical_file(root, ref, bindings.MANIFEST)
    catalog = historical_file(root, ref, CATALOG)
    if binding_manifest is None or catalog is None:
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
