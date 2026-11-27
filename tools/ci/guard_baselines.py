"""Read existing baseline entries at the CI-verified comparison commit."""
from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path


def previous_baseline(root: Path, path: str) -> dict | None:
    base = os.environ.get("KEYNES_GUARD_BASE_REF")
    if not base:
        comparison = subprocess.run(
            ["git", "merge-base", "HEAD", "origin/master"], cwd=root, capture_output=True, text=True,
        )
        if comparison.returncode:
            return None  # An isolated fixture or checkout without origin/master.
        base = comparison.stdout.strip()
    lookup = subprocess.check_output(["git", "ls-tree", "--name-only", base, "--", path], cwd=root)
    if not lookup:
        return None  # The baseline is introduced on this branch.
    content = subprocess.check_output(["git", "show", f"{base}:{path}"], cwd=root)
    baseline = json.loads(content)
    if not isinstance(baseline, dict):
        raise ValueError(f"{path}: expected an object at {base}")
    return baseline
