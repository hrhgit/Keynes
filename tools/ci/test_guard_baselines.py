from pathlib import Path
import subprocess
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch

from guard_baselines import previous_baseline

ROOT = Path(__file__).resolve().parents[2]


class BaselineHistory(unittest.TestCase):
    def test_first_registration_rejects_debt_without_base_evidence(self):
        with patch("guard_baselines.subprocess.run"), \
             patch("guard_baselines.subprocess.check_output", return_value=b""):
            with patch.dict("os.environ", {"KEYNES_GUARD_BASE_REF": "base"}):
                self.assertEqual(previous_baseline(ROOT, "new_baseline.json"), {})

    def test_first_registration_only_uses_problems_from_comparison_commit(self):
        with patch("guard_baselines.subprocess.check_output", return_value=b""):
            with patch.dict("os.environ", {"KEYNES_GUARD_BASE_REF": "base"}):
                def observed_at_base(folder, ref):
                    self.assertEqual((folder, ref), (ROOT, "base"))
                    return {"problem already on base": 1}

                self.assertEqual(previous_baseline(ROOT, "new_baseline.json", observed_at_base),
                                 {"problem already on base": 1})

    def test_directory_only_fixture_does_not_inherit_an_unrelated_comparison(self):
        with TemporaryDirectory() as tmp, patch.dict("os.environ", {"KEYNES_GUARD_BASE_REF": "base"}):
            self.assertIsNone(previous_baseline(Path(tmp), "new_baseline.json"))

    def test_manual_ci_compares_to_first_parent_instead_of_itself(self):
        workflow = ROOT / ".github/workflows/runtime-checks.yml"
        lines = workflow.read_text(encoding="utf-8")
        prelude = lines.split("        run: |\n", 1)[1].split("          status=0", 1)[0]
        with TemporaryDirectory() as tmp:
            git = Path(tmp) / "git"
            git.write_text('#!/bin/sh\n'
                           'case "$1" in\n'
                           '  rev-parse) printf "%s\\n" parent;;\n'
                           '  cat-file) exit 0;;\n'
                           '  *) exit 99;;\n'
                           'esac\n', encoding="utf-8")
            git.chmod(0o755)
            for base, expected in (("", "parent"), ("head", "parent"), ("0" * 40, "parent"), ("pr-base", "pr-base")):
                with self.subTest(base=base):
                    completed = subprocess.run(
                        ["bash", "-e", "-c", prelude + 'printf "%s" "$KEYNES_GUARD_BASE_REF"'],
                        env={"PATH": f"{tmp}:/usr/bin:/bin", "KEYNES_GUARD_BASE_REF": base, "GITHUB_SHA": "head"},
                        capture_output=True, text=True, check=True,
                    )
                    self.assertEqual(completed.stdout, expected)


if __name__ == "__main__":
    unittest.main()
