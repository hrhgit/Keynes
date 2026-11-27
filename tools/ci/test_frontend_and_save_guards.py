import copy
import unittest

import check_script_native_access as script_access
import narrative_save_layout as layout

PLAYER_GAME = "scripts/game/player_game.gd"
UNREST_FILE = "gdext/src/runtime_narrative_unrest.cpp"

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
    def test_next_day_drain_must_survive_a_checkpoint(self):
        implementations = [(UNREST_FILE, HISTORICAL_DRAIN)]
        errors = layout.drained_state_violations(SAVE_SOURCE, implementations)
        self.assertEqual(errors, [f"{UNREST_FILE}: drained Narrative state _independence_clears is missing "
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
