"""Read existing baseline entries at the CI-verified comparison commit."""
from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path
from typing import Callable


def historical_file(root: Path, ref: str, path: str) -> bytes | None:
    """Read bytes from the comparison commit; only an absent path returns None."""
    lookup = subprocess.check_output(["git", "ls-tree", "--name-only", ref, "--", path], cwd=root)
    if not lookup:
        return None
    return subprocess.check_output(["git", "show", f"{ref}:{path}"], cwd=root)


def previous_baseline(
    root: Path, path: str, bootstrap: Callable[[Path, str], dict] | None = None,
) -> dict | None:
    """Use committed history, or reconstruct allowed initial entries from that same commit."""
    if not (root / ".git").exists():  # A directory-only test fixture has no commit to compare.
        return None
    base = os.environ.get("KEYNES_GUARD_BASE_REF")
    if not base:
        comparison = subprocess.run(
            ["git", "merge-base", "HEAD", "origin/master"], cwd=root, capture_output=True, text=True,
        )
        if comparison.returncode:
            comparison = subprocess.run(
                ["git", "rev-parse", "--verify", "HEAD^"], cwd=root, capture_output=True, text=True,
            )
        if comparison.returncode:
            raise ValueError("no guard comparison commit; set KEYNES_GUARD_BASE_REF")
        base = comparison.stdout.strip()
    content = historical_file(root, base, path)
    if content is not None:
        baseline = json.loads(content)
    else:
        baseline = bootstrap(root, base) if bootstrap else {}
    if not isinstance(baseline, dict):
        raise ValueError(f"{path}: expected an object at {base}")
    return baseline
