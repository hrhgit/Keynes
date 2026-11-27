import copy
import json
from pathlib import Path
import unittest

import narrative_save_layout as layout

ROOT = Path(__file__).resolve().parents[2]
CAPTURE = (ROOT / layout.SOURCE).read_text(encoding="utf-8")
RUNTIME = (ROOT / layout.RUNTIME).read_text(encoding="utf-8")
BASELINE = json.loads((ROOT / layout.BASELINE).read_text(encoding="utf-8"))
FINAL_RETURN = "    return out.duplicate(true);"
PULSE_FIELD = '    out["last_fact_event_id"] = _last_fact;'
VALIDATION = "    const String error = checkpoint_error(archive);"


def replace_once(source: str, before: str, after: str) -> str:
    if source.count(before) != 1:
        raise AssertionError(f"fixture must identify one source statement: {before}")
    return source.replace(before, after, 1)


def capture_refusals(source: str) -> list[str]:
    try:
        return layout.layout_violations(layout.archive_shapes(source), BASELINE, BASELINE)
    except ValueError as error:
        return [str(error)]


class NarrativeCaptureContracts(unittest.TestCase):
    def test_erased_key_is_absent_from_the_returned_archive(self):
        source = replace_once(CAPTURE, FINAL_RETURN,
                              '    out.erase("pending_choice");\n' + FINAL_RETURN)
        errors = capture_refusals(source)
        self.assertTrue(any("pending_choice" in error for error in errors), errors)

    def test_erasing_a_key_while_using_the_result_is_still_a_write(self):
        for statement in ('const bool removed = out.erase("pending_choice");',
                          'if (out.erase("pending_choice")) { log_cleanup(); }'):
            with self.subTest(statement=statement):
                source = replace_once(CAPTURE, FINAL_RETURN, f"    {statement}\n" + FINAL_RETURN)
                errors = capture_refusals(source)
                self.assertTrue(any("pending_choice" in error for error in errors), errors)

    def test_a_required_field_cannot_depend_on_a_branch(self):
        for condition in ("_last_fact >= 0", "false"):
            with self.subTest(condition=condition):
                for punctuation in ("{", ""):
                    statement = PULSE_FIELD.strip()
                    if punctuation:
                        statement = f"{{ {statement} }}"
                    source = replace_once(CAPTURE, PULSE_FIELD, f"    if ({condition}) {statement}")
                    errors = capture_refusals(source)
                    self.assertTrue(any("last_fact_event_id" in error for error in errors), errors)

    def test_nested_archive_returned_with_a_missing_field_is_rejected(self):
        source = replace_once(CAPTURE, FINAL_RETURN,
                              '    unrest.erase("sequence");\n' + FINAL_RETURN)
        errors = capture_refusals(source)
        self.assertTrue(any("sequence" in error for error in errors), errors)

    def test_a_record_erase_changes_the_stored_record_shape(self):
        write = '        row["source_event_id"] = text(item.source);'
        source = replace_once(CAPTURE, write, write + '\n        row.erase("source_event_id");')
        self.assertTrue(any("source_event_id" in error for error in capture_refusals(source)))

    def test_returning_a_different_dictionary_cannot_pass_on_old_writes(self):
        source = replace_once(CAPTURE, FINAL_RETURN, "    return Dictionary();")
        self.assertTrue(capture_refusals(source))

    def test_returning_a_shadowed_dictionary_cannot_pass_on_outer_writes(self):
        source = replace_once(CAPTURE, FINAL_RETURN, "    { Dictionary out;\n" + FINAL_RETURN + "\n    }")
        self.assertTrue(capture_refusals(source))

    def test_a_different_early_return_cannot_hide_required_fields(self):
        source = replace_once(CAPTURE, PULSE_FIELD,
                              "    if (_pending_choice.is_empty()) return out;\n" + PULSE_FIELD)
        self.assertTrue(capture_refusals(source))

    def test_both_branches_write_the_required_field(self):
        source = replace_once(CAPTURE, PULSE_FIELD, """
    if (_last_fact >= 0) {
        out["last_fact_event_id"] = _last_fact;
    } else {
        out["last_fact_event_id"] = -1;
    }""")
        self.assertEqual(capture_refusals(source), [])


class NarrativeInstallContracts(unittest.TestCase):
    def test_cannot_write_live_state_before_archive_can_be_rejected(self):
        for statement in ("++_seed;", "_seed++;", "--_seed;", "_seed += 1;", "_pool[0] = {};",
                          "std::swap(_seed, replacement);", "auto old = std::move(_pool);",
                          "this->_seed <<= 1;", "++_pool.at(0).id;"):
            with self.subTest(statement=statement):
                source = replace_once(RUNTIME, VALIDATION, f"    {statement}\n" + VALIDATION)
                self.assertTrue(layout._install_violations(source))

    def test_cannot_write_live_state_after_validation_while_candidate_can_be_rejected(self):
        before = "    if (decoded._country == 0) return false;"
        source = replace_once(RUNTIME, before, "    ++_seed;\n" + before)
        self.assertTrue(layout._install_violations(source))

    def test_can_read_live_fields_and_mutate_local_candidate(self):
        before = "    if (decoded._country == 0) return false;"
        source = replace_once(RUNTIME, before,
                              "    if (_seed == 1) ++decoded._seed;\n" + before)
        self.assertEqual(layout._install_violations(source), [])

    def test_read_only_container_queries_and_exchange_source_are_allowed(self):
        before = "    if (decoded._country == 0) return false;"
        for statement in ("if (_pending_choice.is_empty()) ++decoded._seed;",
                          "const auto total = 3 + +_seed;",
                          "std::exchange(decoded._seed, _seed);"):
            with self.subTest(statement=statement):
                source = replace_once(RUNTIME, before, f"    {statement}\n" + before)
                self.assertEqual(layout._install_violations(source), [])


class NarrativeVersionContracts(unittest.TestCase):
    def test_only_currently_written_version_may_be_added_to_history(self):
        schema = "PKNarrativeRuntime"
        source = replace_once(CAPTURE, '    out["version"] = 1;', '    out["version"] = 3;')
        shapes = layout.archive_shapes(source)
        baseline = copy.deepcopy(BASELINE)
        baseline[schema]["3"] = shapes[schema][1]
        self.assertEqual(layout.layout_violations(shapes, baseline, BASELINE), [])
        baseline[schema]["2"] = ["invented_field", "schema"]
        errors = layout.layout_violations(shapes, baseline, BASELINE)
        self.assertTrue(any("version 2" in error for error in errors), errors)


if __name__ == "__main__":
    unittest.main()
