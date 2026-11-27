import unittest

from check_test_strictness import _test_file, validate_test_diff


# e28ca09b0: the old 30×20 map lacked an eligible opening route with natural flint.
SEED_BEFORE = """\
var config := NewGameConfig.create_default()
config.base.map_width = 30
config.base.map_height = 20
config.base.initial_seed = 20260718
await host.generate_world(20260718)
"""
SEED_AFTER = """\
var config := NewGameConfig.create_default()
config.base.map_width = 40
config.base.map_height = 28
config.base.initial_seed = 20260727
config.base.num_continents = 2
await host.generate_world(int(config.base.initial_seed))
"""


class TestStrictness(unittest.TestCase):
    def test_rejects_comparison_relaxed_from_exact_day_to_bounds(self):
        findings = validate_test_diff("assert(day == 3)\n", "assert(day >= 0)\n")
        self.assertTrue(findings, "the wider comparison accepts incorrect days")

    def test_rejects_assertions_moved_into_dead_branches(self):
        for after in ("if false:\n    assert(day == 3)\n",
                      "if (false) {\nassert(day == 3)\n}\n",
                      "if (false)\n{\nassert(day == 3)\n}\n",
                      "if (false) assert(day == 3);\n"):
            with self.subTest(after=after):
                self.assertTrue(validate_test_diff("assert(day == 3)\n", after))

    def test_assertion_in_else_remains_reachable(self):
        before = "if (ready) {\n    prepare();\n} else {\n    assert(day == 3);\n}\n"
        self.assertEqual(validate_test_diff(before, before.replace("(ready)", "(false)")), [])

    def test_assertion_after_a_same_line_false_branch_remains_reachable(self):
        for before in (
            "if (ready) {\n    prepare();\n} else { CHECK(day == 3); }\n",
            "if (ready) { prepare(); } else { CHECK(day == 3); }\n",
        ):
            with self.subTest(before=before):
                self.assertEqual(validate_test_diff(before, before.replace("(ready)", "(false)")), [])

    def test_rejects_multiline_assertion_whose_expected_value_becomes_actual(self):
        before = "self.assertEqual(\n    sample.day,\n    expected_day,\n)\n"
        after = before.replace("expected_day", "sample.day")
        self.assertTrue(validate_test_diff(before, after))

    def test_compares_literal_timeout_expressions(self):
        before = "const TIMEOUT_MSEC := 1000\n"
        self.assertTrue(validate_test_diff(before, "const TIMEOUT_MSEC := 1000 * 10\n"))
        self.assertEqual(validate_test_diff(before, "const TIMEOUT_MSEC := 250 * 4\n"), [])
        self.assertTrue(validate_test_diff("auto timeout = 1000U;", "auto timeout = 1000U * 10U;"))
        self.assertTrue(validate_test_diff(before, "const TIMEOUT_MSEC := (1000) * (5 + 5)\n"))

    def test_timeout_consumes_a_changed_constant_even_if_the_call_is_unchanged(self):
        before = "const DEFAULT := 1000\nrun_check(timeout=DEFAULT)\n"
        self.assertTrue(validate_test_diff(before, before.replace("1000", "2000")))

    def test_compares_named_seed_constants(self):
        before = "const DEFAULT := 12\nconst ALTERNATE := 13\nconfig.initial_seed = DEFAULT\n"
        self.assertTrue(validate_test_diff(before, before.replace("seed = DEFAULT", "seed = ALTERNATE")))
        equivalent = before.replace("ALTERNATE := 13", "ALTERNATE := 12")
        self.assertEqual(validate_test_diff(equivalent, equivalent.replace("seed = DEFAULT", "seed = ALTERNATE")), [])

    def test_equivalent_attempt_and_retry_counts(self):
        before = "run_check(retries=2)\n"
        self.assertEqual(validate_test_diff(before, "run_check(max_attempts=3)\n"), [])
        self.assertTrue(validate_test_diff(before, "run_check(max_attempts=4)\n"))
        self.assertEqual(validate_test_diff(before, "run_check(maxAttempts=3)\n"), [])
        self.assertEqual(validate_test_diff("RETRIES = 2\n", "MAX_ATTEMPTS = 3\n"), [])

    def test_inline_marker_does_not_approve_adjacent_weakening(self):
        before = "assert(day == 3)\nassert(price == 50)\n"
        after = "assert(day >= 0) # test-guard[assertion]: The day is checked on replay\nassert(price >= 0)\n"
        self.assertEqual([line for line, _ in validate_test_diff(before, after)], [2])

    def test_historical_seed_edit_needs_local_reason(self):
        self.assertEqual(validate_test_diff(SEED_BEFORE, SEED_AFTER), [
            (4, "seed change in initial_seed: 20260718 -> 20260727"),
        ])
        marked = SEED_AFTER.replace("20260727", "20260727 # test-guard[seed]: Opening route needs natural flint")
        self.assertEqual(validate_test_diff(SEED_BEFORE, marked), [])

    def test_removing_a_check_cannot_be_hidden_by_rewriting_its_neighbour(self):
        before = '_expect("day retained", actual == 2)\n_expect("record present",\n    records.size() == 1)\n'
        after = '_expect("day retained", actual == expected_day)\n'
        self.assertEqual(validate_test_diff(before, after), [(1, "removed assertion _expect (old line 2)")])
        reason = '# test-guard[assertion]: Record cardinality is asserted by the replay case\n'
        self.assertEqual(validate_test_diff(before, reason + after), [])

    def test_moving_a_multiline_check_preserves_it(self):
        claim = '_expect("record present",\n    records.size() == 1)\n'
        before = claim + 'report()\nreport_again()\nfinalize()\n'
        after = 'report()\nreport_again()\nfinalize()\n' + claim
        self.assertEqual(validate_test_diff(before, after), [])

    def test_higher_tolerance_timeouts_and_retry_counts(self):
        before = """\
const SAVE_POLL_TIMEOUT_MSEC := 5000
var deadline := Time.get_ticks_msec() + 1000
_expect("stable", abs(actual - expected) <= 0.001)
self.assertAlmostEqual(x, y, places=7)
run_check(retries=0)
"""
        after = """\
const SAVE_POLL_TIMEOUT_MSEC := 8000
var deadline := Time.get_ticks_msec() + 2000
_expect("stable", abs(actual - expected) <= 0.01)
self.assertAlmostEqual(x, y, places=5)
run_check(retries=2)
retry(run_other_check)
"""
        findings = validate_test_diff(before, after)
        self.assertEqual([line for line, _ in findings], [1, 2, 3, 4, 5, 6])
        self.assertEqual(validate_test_diff(after, before), [])

    def test_reason_must_be_in_a_new_comment_of_the_right_kind(self):
        before = 'TIMEOUT = 2  # test-guard[timeout]: Existing adjustment\n'
        for after in (
            'TIMEOUT = 3  # test-guard[timeout]: Existing adjustment\n',
            'TIMEOUT = 3  # test-guard[seed]: Wrong kind\n',
            'TIMEOUT = 3  # test-guard[timeout]:   \n',
            'TIMEOUT = 3\nprint("# test-guard[timeout]: A string is not a comment")\n',
        ):
            with self.subTest(after=after):
                self.assertTrue(validate_test_diff(before, after))
        prior_marker = '# test-guard[timeout]: Existing adjustment\n'
        self.assertTrue(validate_test_diff(prior_marker + 'TIMEOUT = 2\n', prior_marker + 'TIMEOUT = 3\n'))
        self.assertEqual(validate_test_diff('TIMEOUT = 2\n', prior_marker + 'TIMEOUT = 3\n'), [])

    def test_literals_inside_comments_and_strings_are_ignored(self):
        before = '# assert(0)\nmessage = "timeout = 3"\n'
        after = 'message = "timeout = 30; retry(x)"\nassert completed\n'
        self.assertEqual(validate_test_diff(before, after), [])

    def test_multiline_examples_do_not_count_as_test_changes(self):
        before = 'fixture = """\nTIMEOUT = 1000\n"""\n/*\nassert(result);\n*/\n'
        after = 'fixture = """\nTIMEOUT = 2000\n"""\n/*\nexpected fixture\n*/\n'
        self.assertEqual(validate_test_diff(before, after), [])

    def test_asserting_true_removes_a_check(self):
        for before, after in (
            ('assert(result);', 'assert(true);'),
            ('assert result', 'assert True'),
            ('_expect("same day", day == 2)', '_expect("same day", true)'),
        ):
            with self.subTest(after=after):
                self.assertIn("removed assertion", validate_test_diff(before, after)[0][1])

    def test_cpp_timeouts_and_retry_switch(self):
        before = 'auto deadline = 1000U;\nauto timeout = std::chrono::seconds(1);\nretry_on_failure = False\n'
        after = 'auto deadline = 2000U;\nauto timeout = std::chrono::milliseconds(500);\nretry_on_failure = True\n'
        self.assertEqual([line for line, _ in validate_test_diff(before, after)], [1, 3])

    def test_native_selftests_are_in_scope(self):
        self.assertTrue(_test_file("gdext/src/runtime_climate_physics_selftest.cpp"))
        self.assertTrue(_test_file("gdext/src/native_simulation_host_economy_revisit_selftest.inc"))
        self.assertFalse(_test_file("gdext/src/runtime_climate_physics.cpp"))


if __name__ == "__main__":
    unittest.main()
