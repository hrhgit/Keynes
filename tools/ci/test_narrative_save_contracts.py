"""Static checks only describe the fields and versions written in capture()."""
import copy
import json
from pathlib import Path
import unittest

import narrative_save_layout as layout
from test_frontend_and_save_guards import SAVE_SOURCE, SAVE_BASELINE

ROOT = Path(__file__).resolve().parents[2]


class NarrativeCaptureContracts(unittest.TestCase):
    def test_equivalent_capture_forms_preserve_layout(self):
        source = SAVE_SOURCE.replace('out["version"] = 1;', 'out["version"] = 1;\n    if (_country == 0) return out;')
        expected = layout.archive_shapes(source)
        for original, alternative in (
            ("_country == 0", "!_country"),
            ("Dictionary out;", "auto out = Dictionary{};"),
            ('out["stratum_unrest"] = unrest;', 'out["stratum_unrest"] = unrest.duplicate(true);'),
        ):
            with self.subTest(alternative=alternative):
                self.assertIn(original, source)
                self.assertEqual(layout.archive_shapes(source.replace(original, alternative)), expected)

    def test_renamed_archive_still_requires_a_version_for_new_fields(self):
        source = SAVE_SOURCE.replace("out", "archive").replace("unrest[", "disorder[").replace(
            "Dictionary unrest;", "Dictionary disorder;").replace("= unrest;", "= disorder;")
        changed = source.replace('disorder["schema"]', 'disorder["next_day_cleanup"] = clears;\n    disorder["schema"]')
        errors = layout.layout_violations(layout.archive_shapes(changed), SAVE_BASELINE)
        self.assertTrue(any("next_day_cleanup" in error for error in errors), errors)

    def test_incomplete_capture_reports_the_control_line(self):
        source = SAVE_SOURCE.replace("return out.duplicate(true);", "if (_country)")
        line = next(i for i, text in enumerate(source.splitlines(), 1) if "if (_country)" in text)
        with self.assertRaisesRegex(ValueError, rf"{layout.SOURCE}:{line}:"):
            layout.archive_shapes(source)

    def test_version_literal_forms_and_complete_initializer(self):
        write = 'out["version"] = 1;'
        for value in ("1U", "(1)", "((1ull))", "0x1L", "01", "0b1u", "kVersion"):
            with self.subTest(value=value):
                source = "constexpr unsigned kVersion = (1U);\n" + SAVE_SOURCE.replace(write, f'out["version"] = {value};')
                self.assertEqual(layout.archive_shapes(source), layout.archive_shapes(SAVE_SOURCE))
        for expression in ("1 + 2", "(1 + 2)", "1U << 1", "make_version()"):
            with self.subTest(expression=expression):
                source = SAVE_SOURCE.replace(write, f'out["version"] = {expression};')
                line = next(i for i, text in enumerate(source.splitlines(), 1) if expression in text)
                with self.assertRaisesRegex(ValueError, rf"{layout.SOURCE}:{line}:"):
                    layout.archive_shapes(source)
        source = SAVE_SOURCE.replace(write, 'out.set("version", (1UL));')
        self.assertEqual(layout.archive_shapes(source), layout.archive_shapes(SAVE_SOURCE))

    def test_only_currently_written_version_may_be_added_to_history(self):
        # Fixed, independent historical inputs keep this valid after production upgrades.
        schema = "PKNarrativeRuntime"
        for next_version in (2, 3):
            source = SAVE_SOURCE.replace('out["version"] = 1;', f'out["version"] = {next_version};')
            shapes = layout.archive_shapes(source)
            baseline = copy.deepcopy(SAVE_BASELINE)
            baseline[schema][str(next_version)] = shapes[schema][1]
            self.assertEqual(layout.layout_violations(shapes, baseline, SAVE_BASELINE), [])
        baseline[schema]["2"] = ["invented_field", "schema"]
        errors = layout.layout_violations(shapes, baseline, SAVE_BASELINE)
        self.assertTrue(any("version 2" in error for error in errors), errors)

    def test_moving_record_construction_between_section_headers_changes_no_archive_keys(self):
        record = 'Dictionary row; row["def_dict"] = event; pool.push_back(row.duplicate(true));'
        def before(declaration):
            return SAVE_SOURCE.replace(declaration, record + "\n    " + declaration)
        self.assertEqual(layout.archive_shapes(before("Dictionary unrest;")),
                         layout.archive_shapes(before('unrest["needs_player_recovery"]')))

    def test_old_record_metadata_is_frozen_but_new_versions_do_not_declare_it(self):
        schema = "PKNarrativeRuntime"
        old = copy.deepcopy(SAVE_BASELINE)
        old[schema]["1"].insert(0, "record[archived]")
        shapes = layout.archive_shapes(SAVE_SOURCE)
        self.assertEqual(layout.layout_violations(shapes, old, old), [])
        self.assertTrue(layout.layout_violations(shapes, SAVE_BASELINE, old))
        shapes[schema] = (2, shapes[schema][1])
        current = copy.deepcopy(old)
        current[schema]["2"] = shapes[schema][1]
        self.assertEqual(layout.layout_violations(shapes, current, old), [])
        current[schema]["2"] = sorted([*shapes[schema][1], "record[inferred]"])
        self.assertTrue(any("legacy record" in e for e in layout.layout_violations(shapes, current, old)))

    def test_malformed_history_is_a_diagnostic(self):
        shapes = layout.archive_shapes(SAVE_SOURCE)
        errors = layout.layout_violations(shapes, SAVE_BASELINE, {"PKNarrativeRuntime": []})
        self.assertTrue(any(layout.BASELINE + ":1:" in error for error in errors), errors)

    def test_current_snapshot_matches_its_own_version(self):
        source = (ROOT / layout.SOURCE).read_text(encoding="utf-8")
        baseline = json.loads((ROOT / layout.BASELINE).read_text(encoding="utf-8"))
        self.assertEqual(layout.layout_violations(layout.archive_shapes(source), baseline), [])
        # test-guard[assertion]: 分支、复制和恢复后的值由运行时逐字段、逐字节核对，拒绝后的状态由原生自检核对。


if __name__ == "__main__":
    unittest.main()
