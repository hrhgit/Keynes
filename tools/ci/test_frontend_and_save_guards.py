import copy
from contextlib import redirect_stderr, redirect_stdout
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

import check_script_native_access as script_access
import narrative_save_layout as layout

PLAYER_GAME = "scripts/game/player_game.gd"
UNREST_FILE = "gdext/src/runtime_narrative_unrest.cpp"
ROOT = Path(__file__).resolve().parents[2]

# The live diagnostic on master. f2762d2c7 adds the calendar input below.
HEARTBEAT = """func _economy_probe() -> Dictionary:
	var out := {"eco_day": -1, "graph": false}
	if _runtime_host == null or not _runtime_host.has_method("get_generator"):
		return out
	var generator = _runtime_host.get_generator()
	if generator == null:
		return out
	if generator.has_method("runtime_graph_active"):
		out["graph"] = bool(generator.runtime_graph_active())
	if generator.has_method("get_economy_facade"):
		var facade = generator.get_economy_facade()
		if facade != null and facade.has_method("report"):
			var report: Dictionary = facade.report()
			out["eco_day"] = int(report.get("newest_state_day", -1))
	return out
"""
CALENDAR_BASELINE = {
    PLAYER_GAME: {"_economy_probe": "84804519a507373b76e384bed24ece558d67ed55a89e8ff8a0e14922e9d954b3"},
}
LIVE_DAY = '\t\t\tout["eco_day"] = int(report.get("newest_state_day", -1))\n'
HISTORICAL_CALENDAR = HEARTBEAT.replace(
    LIVE_DAY, LIVE_DAY + '\t\t\tif _world_clock != null:\n'
    '\t\t\t\t_world_clock.set_economy_settled_day(int(out["eco_day"]))\n',
)
PUBLISHED_CALENDAR = """func _update_calendar(publication: Dictionary) -> void:
	_world_clock.set_economy_settled_day(int(publication["economy_day"]))
"""

# The queue introduced by 66cf634e5 is taken in the next day's prepare stage.
HISTORICAL_DRAIN = """std::vector<int32_t> RuntimeNarrative::take_independence_clears() {
    return std::exchange(_independence_clears, {});
}
"""

# Relevant portions of the version-1 capture and restore. The historical change
# above comes with no edits to either function.
SAVE_SOURCE = """Dictionary RuntimeNarrative::capture() const {
    Dictionary out;
    out["schema"] = "PKNarrativeRuntime";
    out["version"] = 1;
    Dictionary unrest;
    unrest["schema"] = "PKStratumUnrest";
    unrest["version"] = 1;
    unrest["needs_player_recovery"] = _recover_unrest;
    out["stratum_unrest"] = unrest;
    return out.duplicate(true);
}

void RuntimeNarrative::decode_checkpoint(const Dictionary &state) {
    const auto unrest = record_or_empty(state.get("stratum_unrest", Variant()));
    _recover_unrest = unrest.get("needs_player_recovery", true);
}
"""
SAVE_BASELINE = {
    "PKNarrativeRuntime": {"1": ["schema", "stratum_unrest"]},
    "PKStratumUnrest": {"1": ["needs_player_recovery", "schema"]},
}


def unversioned_last_city_capture():
    return SAVE_SOURCE.replace('    out["stratum_unrest"] = unrest;',
        '    Array clears;\n'
        '    for (const int32_t cell : _independence_clears) clears.push_back(cell);\n'
        '    unrest["pending_independence_clears"] = clears;\n'
        '    out["stratum_unrest"] = unrest;',
    ).replace('    _recover_unrest = unrest.get("needs_player_recovery", true);',
        '    _recover_unrest = unrest.get("needs_player_recovery", true);\n'
        '    const Array clears = unrest.get("pending_independence_clears", Array());\n'
        '    for (int64_t i = 0; i < clears.size(); ++i) _independence_clears.push_back(clears[i]);',
    )


class FrontendLiveReads(unittest.TestCase):
    def test_live_read_in_member_initializer_is_refused(self):
        for source in (
            'var snapshot = _economy_facade.report()\nfunc update():\n\tpass\n',
            'func update():\n\tpass\n@onready var snapshot = (\n\t_economy_facade.report()\n)\n',
            '@warning_ignore("unsafe_method_access") @onready var snapshot := _economy_facade.report()\n',
            'class Row extends Control:\n\t@onready var model := get_parent().get_economy_facade()\n'
            '\t@onready var snapshot := model.report()\n\tfunc draw():\n\t\tpass\n',
        ):
            with self.subTest(source=source):
                errors = script_access.frontend_live_read_violations("scripts/ui/calendar.gd", source, {})
                self.assertEqual(len(errors), 1)
                self.assertIn("class body reads the live Economy report", errors[0])

    def test_published_parameter_shadows_same_named_live_member(self):
        for parameter in ("_economy_facade", "_economy_facade: PublishedEconomyView"):
            with self.subTest(parameter=parameter):
                source = ("var _economy_facade: EconomyFacade\n"
                          f"func update({parameter}):\n\treturn _economy_facade.report()\n")
                self.assertEqual(
                    script_access.frontend_live_read_violations("scripts/ui/calendar.gd", source, {}), [])
                explicit = source.replace("return _economy_facade", "return self._economy_facade")
                self.assertEqual(len(script_access.frontend_live_read_violations(
                    "scripts/ui/calendar.gd", explicit, {})), 1)

    def test_a_later_local_shadow_does_not_hide_an_earlier_live_read(self):
        source = ("var _economy_facade: EconomyFacade\nfunc update():\n"
                  "\tvar result := _economy_facade.report()\n\tif visible:\n"
                  "\t\tvar _economy_facade: PublishedEconomyView = state.current_view\n"
                  "\t\treturn _economy_facade.report()\n\treturn result\n")
        errors = script_access.frontend_live_read_violations("scripts/ui/calendar.gd", source, {})
        self.assertEqual(len(errors), 1)
        self.assertIn("calendar.gd:3", errors[0])

    def test_ci_refuses_a_manually_increased_native_reference_count(self):
        name = "Project/project-keynes/scripts/ui/calendar.gd"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            baseline = root / script_access.BASELINE
            baseline.parent.mkdir(parents=True)
            baseline.write_text(json.dumps({name: {"economy": 2}}), encoding="utf-8")
            for flags in ([], ["--write-baseline"]):
                with self.subTest(flags=flags), \
                        patch.object(sys, "argv", ["check_script_native_access.py", "--root", directory, *flags]), \
                        patch.object(script_access, "inspect", return_value=([], [], 0)), \
                        patch.object(script_access, "previous_baseline", return_value={name: {"economy": 1}}), \
                        redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()) as stderr:
                    self.assertEqual(script_access.main(), 1)
                    self.assertIn("cannot increase historical native access allowance", stderr.getvalue())

    def test_legacy_live_exception_must_match_an_existing_read(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            baseline = root / script_access.LIVE_BASELINE
            baseline.parent.mkdir(parents=True)
            baseline.write_text(json.dumps(CALENDAR_BASELINE), encoding="utf-8")
            read_site = root / script_access.PROJECT / PLAYER_GAME
            read_site.parent.mkdir(parents=True)
            read_site.write_text(PUBLISHED_CALENDAR, encoding="utf-8")
            with patch.object(script_access, "previous_baseline", return_value=CALENDAR_BASELINE), \
                    patch.object(script_access.inventory, "inventory", side_effect=lambda _: ([], [])), \
                    patch.object(script_access.inventory, "load_table", return_value={"modules": {}}):
                _, errors, _ = script_access.inspect(root)
                self.assertEqual(len(errors), 1)
                self.assertIn("remove unused live read exception", errors[0])
                baseline.write_text("{}", encoding="utf-8")
                self.assertEqual(script_access.inspect(root)[1], [])

    def test_heartbeat_callers_cannot_use_its_live_day_for_the_calendar(self):
        source = (ROOT / script_access.PROJECT / PLAYER_GAME).read_text(encoding="utf-8")
        self.assertEqual(script_access.frontend_live_read_violations(PLAYER_GAME, source, CALENDAR_BASELINE), [])
        old = '\tvar eco := _economy_probe()\n'
        self.assertIn(old, source)
        changed = source.replace(old, old + '\t_world_clock.set_economy_settled_day(eco["eco_day"])\n')
        self.assertTrue(script_access.frontend_live_read_violations(PLAYER_GAME, changed, CALENDAR_BASELINE))
        other = 'func update(player):\n\treturn Callable(player, "_economy_probe").call()\n'
        self.assertTrue(script_access.frontend_live_read_violations(
            "scripts/game/calendar_adapter.gd", other, CALENDAR_BASELINE))

    def test_first_live_baseline_can_use_only_the_base_heartbeat_and_consumer(self):
        source = (ROOT / script_access.PROJECT / PLAYER_GAME).read_bytes()
        with patch.object(script_access, "historical_file", return_value=source):
            self.assertEqual(script_access.historical_live_baseline(ROOT, "base"), CALENDAR_BASELINE)
        changed = source.replace(b'var eco := _economy_probe()\n',
                                 b'var eco := _economy_probe()\n\tclock.set_day(eco["eco_day"])\n')
        self.assertNotEqual(changed, source)
        with patch.object(script_access, "historical_file", return_value=changed):
            self.assertEqual(script_access.historical_live_baseline(ROOT, "base"), {})

    def test_live_economy_facade_members_and_local_aliases_are_detected(self):
        for origin in ('var model: EconomyFacade', 'var model = generator.get_economy_facade()',
                       'var model\nfunc configure(generator):\n\tself.model = generator.get_economy_facade()'):
            with self.subTest(origin=origin):
                source = origin + '\nfunc update():\n\tvar economy = self.model\n\treturn economy.report()\n'
                self.assertTrue(script_access.frontend_live_read_violations(
                    "scripts/ui/calendar.gd", source, {}))

    def test_published_view_can_use_the_same_method_name(self):
        source = """func update(publication: PublishedEconomyView):
	var generator = publication
	return generator.get_economy_report()
"""
        self.assertEqual(script_access.frontend_live_read_violations("scripts/ui/calendar.gd", source, {}), [])

    def test_calendar_cannot_gain_access_through_the_heartbeats_live_report(self):
        self.assertEqual(script_access.frontend_live_read_violations(PLAYER_GAME, HEARTBEAT, CALENDAR_BASELINE), [])
        self.assertEqual(script_access.frontend_live_read_violations(PLAYER_GAME, PUBLISHED_CALENDAR, {}), [])
        errors = script_access.frontend_live_read_violations(PLAYER_GAME, HISTORICAL_CALENDAR, CALENDAR_BASELINE)
        self.assertEqual(len(errors), 1)
        self.assertIn("_economy_probe reads the live Economy report", errors[0])

    def test_report_name_alone_does_not_make_an_unrelated_receiver_live_economy(self):
        source = """func _update_status(generator) -> void:
	var facade = generator.get_country_facade()
	var display = "generator.get_economy_facade().report()"
	var economy = generator.get_economy_facade()
	if economy.has_method("report"):
		display = str(facade.report())
"""
        file = "scripts/ui/country_panel.gd"
        self.assertEqual(script_access.frontend_live_read_violations(file, source, {}), [])
        for read in ('economy.call(&"report")', 'generator.get_economy_facade().report()',
                     'generator.get_economy_report()', 'Callable(economy, "report").call()'):
            with self.subTest(read=read):
                errors = script_access.frontend_live_read_violations(file, source + f"\tprint({read})\n", {})
                self.assertEqual(len(errors), 1)

    def test_live_reference_baseline_can_only_shrink(self):
        self.assertEqual(script_access.live_baseline_violations({}, CALENDAR_BASELINE), [])
        self.assertIn("live read exception added or changed", script_access.live_baseline_violations(
            CALENDAR_BASELINE, {})[0])


class NarrativeSaveLayout(unittest.TestCase):
    # test-guard[assertion]: 字段值与拒绝后整份状态在 runtime_narrative_checkpoint_test 和原生同对象自检中直接核对。
    def test_next_day_drain_must_survive_a_checkpoint(self):
        implementations = [(UNREST_FILE, HISTORICAL_DRAIN)]
        errors = layout.drained_state_violations(SAVE_SOURCE, implementations)
        self.assertEqual(errors, [f"{UNREST_FILE}:2: drained Narrative state _independence_clears is missing "
                                  "from checkpoint capture or restore"])
        self.assertEqual(layout.drained_state_violations(unversioned_last_city_capture(), implementations), [])
        self.assertEqual(layout.drained_state_violations(SAVE_SOURCE, [
            (UNREST_FILE, "// The previous example used std::exchange(_independence_clears, {});"),
        ]), [])

    def test_new_unrest_field_requires_its_own_version_and_a_frozen_layout(self):
        self.assertEqual(layout.layout_violations(layout.archive_shapes(SAVE_SOURCE), SAVE_BASELINE), [])
        source = unversioned_last_city_capture()
        errors = layout.layout_violations(layout.archive_shapes(source), SAVE_BASELINE)
        self.assertEqual(len(errors), 1)
        self.assertIn("PKStratumUnrest version 1 changed serialized fields", errors[0])
        self.assertIn("pending_independence_clears", errors[0])
        source = source.replace('unrest["version"] = 1;', 'unrest["version"] = 2;')
        baseline = copy.deepcopy(SAVE_BASELINE)
        baseline["PKStratumUnrest"]["2"] = ["needs_player_recovery", "pending_independence_clears", "schema"]
        self.assertEqual(layout.layout_violations(layout.archive_shapes(source), baseline, SAVE_BASELINE), [])
        baseline["PKStratumUnrest"]["1"] = baseline["PKStratumUnrest"]["2"]
        self.assertIn("cannot remove or rewrite PKStratumUnrest version 1",
                      layout.layout_violations(layout.archive_shapes(source), baseline, SAVE_BASELINE)[0])


if __name__ == "__main__":
    unittest.main()
