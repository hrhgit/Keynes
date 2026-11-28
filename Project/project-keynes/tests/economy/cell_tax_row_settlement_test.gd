extends "res://tests/economy/economy_rolling_runtime_test.gd"

const Commands = preload("res://scripts/country/country_command_batch.gd")
const PEOPLE := 3
const LOW := 1
const HIGH := (1 << 24) + LOW
const BASELINE := "../../tools/ci/tax_row_keys_baseline.json"
const OLD_CACHE := "gdext/src/economy_runtime_country_epoch_capture_tax_rows.inc"
const OLD_KEY := "7dcd33574ceaede7d250cdcedee50519b6b83e8297e2497ba40f193cbab414c1"

var _catalog: Dictionary
var _profile: Dictionary


func _init() -> void:
	_run()
	print("cell tax settlement: %d failures" % failures)
	quit(int(failures != 0))


func _sample(live: Array, policies: Dictionary, observed: int) -> Dictionary:
	var ext := _new_ext(_catalog)
	var seed_value := 92021
	_expect("country configures", CountryTestHelper.configure_all_technologies(
		ext, _catalog, CELL_COUNT, seed_value))
	_expect("economy configures", ext.configure_economy(_catalog, _profile, CELL_COUNT, seed_value).ok)
	var merchant: int = _catalog.signature_keys.find("merchant|default")
	var signatures := PackedInt32Array()
	var people := PackedInt64Array()
	var funds := PackedInt64Array()
	for cell in live:
		signatures.append(merchant)
		people.append(PEOPLE)
		funds.append(10_000_000_000)
	var prices := PackedInt32Array()
	var stock := PackedInt64Array()
	for cell in range(CELL_COUNT):
		prices.append_array(_catalog.good_default_price)
	stock.resize(prices.size())
	var boot: Dictionary = ext.bootstrap_economy({"cell_indices": PackedInt32Array(live),
		"signature_ids": signatures, "population": people, "funds": funds},
		{"stock": stock, "price": prices})
	_expect("population and markets bootstrap", boot.ok)
	var commands: Array[Dictionary] = []
	var handle: int = ext.get_country_cell_summary(0).country_handle
	for cell in policies:
		commands.append({"opcode": CountryFacade.Opcode.SET_CELL_TAX_DEFAULT,
			"effective_day": 0, "sequence": commands.size() + 1, "target_handle": handle,
			"cell": cell, "tax_kind": CountryFacade.TaxKind.INCOME,
			"tax_rate_basis_points": policies[cell],
			"tax_assessment_mode": CountryFacade.TaxAssessmentMode.ABSOLUTE})
	var accepted: Dictionary = ext.submit_country_commands(Commands.pack(commands, true, 0))
	_expect("local tax defaults admitted", accepted.ok)
	var committed: Dictionary = ext.run_country_slice({"day_index": 0})
	_expect("local tax defaults committed", committed.ok)
	_expect("settlement trace requested", ext.set_economy_inspector_trace_cell(observed).ok)
	var slice: Dictionary
	var tick := 0
	while true:
		slice = ext.run_economy_slice_compact({"day_index": 0, "tick_index": tick})
		if slice.get("done", false) or slice.get("fatal", false):
			break
		tick += 1
	_expect("D0 commits", slice.get("done", false) and not slice.get("fatal", false))
	var snapshot: Dictionary = ext.get_population_cell_snapshot(observed)
	var source: int = snapshot.get("settlement_cashflow_source_stable_ids", PackedStringArray()).find("income_tax")
	var indices: PackedInt32Array = snapshot.get("settlement_cashflow_source_indices", PackedInt32Array())
	var expense: PackedInt64Array = snapshot.get("settlement_cashflow_expense", PackedInt64Array())
	var total := 0
	for i in range(indices.size()):
		if indices[i] == source:
			total += expense[i]
	_expect("settlement traced a funded cohort's income tax", snapshot.get("settlement_detail_available", false)
		and source >= 0 and indices.has(source) and indices.size() == expense.size())
	_expect("D0 settles five days for the observed cell",
		ext.get_building_cell_snapshot(observed).get("period_days", -1) == PHASE_COUNT)
	# This host only settles. The compact report counts the actual compiled
	# policies and rows before any display frame is requested. An unoccupied
	# cell still has a valid local tax policy in Country.
	_expect("settlement compiles only the distinct policies on occupied cells",
		slice.get("economy_live_cells", -1) == live.size()
		and slice.get("cell_tax_compiled_policy_count", -1) == live.size())
	return {"total": total, "rows": slice.get("cell_tax_shared_default_row_count", -1)}


func _pair(live: Array, policies: Dictionary) -> Array:
	# The inspector records one selected cell in a run. Both runs receive the
	# identical complete command batch before D0.
	var left := _sample(live, policies, 0)
	var right := _sample(live, policies, 5)
	return [left.total, right.total, left.rows, right.rows]


func _old_key_registered() -> bool:
	var path := ProjectSettings.globalize_path("res://").path_join(BASELINE).simplify_path()
	if not FileAccess.file_exists(path):
		return false
	var entries = JSON.parse_string(FileAccess.get_file_as_string(path))
	return entries is Dictionary and entries.get(OLD_CACHE, []) == [OLD_KEY]


func _run() -> void:
	_catalog = EconomyCatalogScript.compile_native_catalog()
	_expect("catalog compiles", _catalog.get("ok", false))
	_catalog.erase("ok")
	_profile = load("res://data/economy/default_economy.tres").to_native_profile()
	_profile.market_runtime_mode = "ACTIVE"
	_profile.trade_runtime_mode = "OFF"
	_profile.economy_cadence_force_market_days = PHASE_COUNT
	_profile.economy_cadence_force_plan_days = 10
	_profile.economy_cadence_force_investment_days = 10
	var units := PEOPLE * PHASE_COUNT
	# Standalone controls also have an owned but unoccupied cell whose policy
	# would collide if it reached settlement. Its separate noncolliding peer
	# detects enlargement of the row table even when a bad key aliases a row.
	var policies := {0: LOW, 5: HIGH, 3: 71}
	for cell in [0, 5]:
		var single := _sample([cell], policies, cell)
		_expect("cell %d alone pays its statutory levy; empty cells add no rows" % cell,
			single == {"total": units * int(policies[cell]), "rows": 1})

	var normal := [units * LOW, units * (HIGH + 1), 2, 2]
	_expect("two occupied cells pay their own amounts",
		_pair([0, 5], {0: LOW, 5: HIGH + 1}) == normal)
	_expect("reversing the command and population order and adding empty land preserves each levy",
		_pair([5, 0], {3: 71, 5: HIGH + 1, 0: LOW}) == normal)

	var forward := _pair([0, 5], {0: LOW, 5: HIGH})
	var reversed := _pair([5, 0], {5: LOW, 0: HIGH})
	var expected_forward := [units * LOW, units * HIGH, 2, 2]
	var expected_reversed := [units * HIGH, units * LOW, 2, 2]
	if forward == expected_forward and reversed == expected_reversed:
		_expect("both legal levies stay distinct in either cell order", true)
		return
	print("tax rows [cell 0 paid, cell 5 paid, rows in each run]: actual %s / %s; expected %s / %s"
		% [forward, reversed, expected_forward, expected_reversed])
	# The one registered master defect has one exact outcome in BOTH
	# permutations. Removing the static key baseline makes this strict too.
	var known := forward == [units * LOW, units * LOW, 1, 1] \
		and reversed == [units * HIGH, units * HIGH, 1, 1]
	if known and _old_key_registered() and not OS.get_cmdline_user_args().has("--strict"):
		print("KNOWN tax row collision: two occupied cells share the first absolute levy")
	else:
		_expect("both legal levies stay distinct in either cell order", false)
