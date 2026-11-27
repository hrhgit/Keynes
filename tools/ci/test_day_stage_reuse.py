"""Test the same-day stage guard with the PR #11 revisit shapes."""

import unittest

from check_day_stage_reuse import HOST, MODIFIER_OWNER, SRC, ROOT, stage_reuse_violations
from cpp_source import read_cpp_source


WITHOUT_REUSE = """
    uint32_t terminal = 0;
    for (const auto &packet : day_commands) {
        gameplay_event_commands.push_back(packet);
        ++terminal;
    }
    _gameplay_effect_generation.fetch_add(1, std::memory_order_release);
    return true;
"""


def gameplay_sources(body):
    return {
        HOST: """
            std::array<RuntimeModuleDescriptor<StageFunction>, 1> modules{{
                {&NativeSimulationHost::stage_gameplay_effect},
            }};
        """,
        "native_simulation_stage_gameplay_effect.cpp": """
            bool NativeSimulationHost::stage_gameplay_effect(
                DayExecution &day, RuntimeDomainPlan &stage) {
            """ + body + "}",
    }


def production_sources():
    directory = ROOT / SRC
    paths = [directory / HOST, directory / MODIFIER_OWNER, *directory.glob("native_simulation_stage_*.cpp")]
    return {path.name: read_cpp_source(path) for path in paths}


class DayStageReuseTests(unittest.TestCase):
    def test_rejects_old_gameplay_effect_body(self):
        errors = stage_reuse_violations(gameplay_sources(WITHOUT_REUSE))
        self.assertEqual(len(errors), 1)
        self.assertIn("must return through day.reuse_completed(stage)", errors[0])

    def test_rejects_a_comment_or_ignored_call_in_place_of_reuse(self):
        for line in ("// if (day.reuse_completed(stage)) return true;",
                     "day.reuse_completed(stage);"):
            with self.subTest(line=line):
                self.assertTrue(stage_reuse_violations(gameplay_sources(line + "\n" + WITHOUT_REUSE)))

    def test_rejects_reuse_after_mutation_or_in_an_unrelated_branch(self):
        reused = "if (day.reuse_completed(stage)) return true;"
        for body in (
            WITHOUT_REUSE.replace("return true;", reused + "\nreturn true;"),
            "if (unrelated) {\n" + reused + "\n}\n" + WITHOUT_REUSE,
            "if (unrelated)\n" + reused + "\n" + WITHOUT_REUSE,
        ):
            with self.subTest(body=body):
                errors = stage_reuse_violations(gameplay_sources(body))
                self.assertEqual(len(errors), 1)
                self.assertIn("before repeating stage work", errors[0])

    def test_requires_retaining_the_result(self):
        errors = stage_reuse_violations(gameplay_sources(
            "if (day.reuse_completed(stage)) return true;\n" + WITHOUT_REUSE
        ))
        self.assertEqual(len(errors), 1)
        self.assertIn("must retain its completed stage", errors[0])

    def test_economy_rejects_unreachable_retention(self):
        sources = production_sources()
        self.assertEqual(stage_reuse_violations(sources), [])
        name = "native_simulation_stage_economy.cpp"
        target = "day.remember_completed(stage);\n        return true;"
        self.assertIn(target, sources[name])
        for replacement in (
            "if (false) { day.remember_completed(stage); }\n        return true;",
            "if (false) day.remember_completed(stage);\n        return true;",
            "return true;\n        day.remember_completed(stage);",
        ):
            with self.subTest(retention=replacement):
                changed = {**sources, name: sources[name].replace(target, replacement, 1)}
                self.assertTrue(any("must retain its completed stage" in error
                                    for error in stage_reuse_violations(changed)))

    def test_economy_accepts_reusing_the_result_through_a_local_variable(self):
        sources = production_sources()
        name = "native_simulation_stage_economy.cpp"
        target = "if (day.reuse_completed(stage)) {"
        self.assertIn(target, sources[name])
        sources[name] = sources[name].replace(
            target, "const bool reused = day.reuse_completed(stage);\n        if (reused) {", 1)
        self.assertEqual(stage_reuse_violations(sources), [])

    def test_accepts_guard_that_allows_genuinely_late_orders(self):
        body = """
            if (previously_completed && latest_order == day.progress.gameplay_submit_order)
                return day.reuse_completed(stage);
            if (!previously_completed) process_original_orders();
            gameplay_event_commands.push_back(new_packet);
            day.remember_completed(stage);
            return true;
        """
        self.assertEqual(stage_reuse_violations(gameplay_sources(body)), [])

    def test_rejects_modifier_plan_that_reapplies_same_day_deliveries(self):
        source = {
            HOST: """
                std::array<RuntimeModuleDescriptor<StageFunction>, 1> modules{{
                    {&NativeSimulationHost::stage_modifier},
                }};
            """,
            "native_simulation_stage_modifier.cpp": """
                bool NativeSimulationHost::stage_modifier(DayExecution &day, RuntimeDomainPlan &stage) {
                    return execute_modifier_worker_stage();
                }
            """,
            MODIFIER_OWNER: """
                bool RuntimeModifierPodAuthority::plan_day(int64_t day) {
                    _next = _current;
                    for (const auto &item : ordered) {
                        apply_command(_next, item.command, day, ack, changed, command_error);
                    }
                    return true;
                }
            """,
        }
        errors = stage_reuse_violations(source)
        self.assertEqual(len(errors), 1)
        self.assertIn("does not preserve same-day delivery receipts", errors[0])

    def test_modifier_cannot_clear_receipts_before_installing_its_plan(self):
        sources = production_sources()
        self.assertEqual(stage_reuse_violations(sources), [])
        target = "_current = std::move(_next);"
        self.assertIn(target, sources[MODIFIER_OWNER])
        changed = {**sources, MODIFIER_OWNER: sources[MODIFIER_OWNER].replace(
            target, "_next.day_receipts.clear();\n        " + target, 1)}
        self.assertTrue(any("does not preserve same-day delivery receipts" in error
                            for error in stage_reuse_violations(changed)))

    def test_rejects_missing_registered_definition(self):
        sources = gameplay_sources(WITHOUT_REUSE)
        errors = stage_reuse_violations({HOST: sources[HOST]})
        self.assertEqual(len(errors), 1)
        self.assertIn("no readable definition for registered day stage", errors[0])


if __name__ == "__main__":
    unittest.main()
