extends "res://tests/building/building_recovery_occupancy_test.gd"

const FIXTURE_SEED := 293


func _run() -> void:
	if OS.get_cmdline_user_args().has("--disjoint-calendars-only"):
		_test_disjoint_calendars()
		print("building lifecycle disjoint calendars: %d failures" % failures)
		return
	_test_non_hiring_review()
	_test_expired_vacancy_reaches_joint_review()
	_test_partial_recovery("")
	_test_partial_recovery("bast_fiber")
	_test_unavailable_input()
	_test_unfunded_recovery(1, 1)
	_test_unfunded_recovery(8, 7)
	print("building lifecycle: %d failures" % failures)


func _fixture(cell: int, count: int, applicants: int, cash: int,
		input: String = "", input_stock: int = 0) -> Dictionary:
	var catalog := EconomyCatalogScript.compile_native_catalog()
	var profile: Dictionary = load("res://data/economy/default_economy.tres").to_native_profile()
	profile.market_runtime_mode = "ACTIVE"
	profile.economy_cadence_force_market_days = 1
	profile.economy_cadence_force_plan_days = 5
	profile.economy_cadence_force_investment_days = 10
	profile.startup_demand_runtime_mode = "OFF"
	profile.family_runtime_mode = "OFF"
	profile.merchant_credit_runtime_mode = "OFF"
	profile.investment_max_growth_share_q16 = 0
	profile.building_severe_loss_cycles = 1
	profile.starvation_death_rate_q32 = 0
	profile.employment_mobility_daily_q16 = 65536
	for key in ["signature_birth_rate_q32", "signature_death_rate_q32", "profession_entry_savings_days"]:
		var values: Variant = catalog[key]
		values.fill(0)
		catalog[key] = values
	var loom: int = catalog.building_type_ids.find("household_loom")
	var signatures: PackedStringArray = catalog.signature_keys
	var artisan := signatures.find("artisan|default")
	var unemployed := signatures.find("unemployed|default")
	var goods: PackedStringArray = catalog.good_ids
	var cloth := goods.find("cloth")
	_strip_building_inputs(catalog, loom)
	if not input.is_empty():
		_ensure_building_input(catalog, loom, goods.find(input), 100_000, 65536)
	_strip_building_resources(catalog, loom)
	_clear_building_climate(catalog, loom)
	_block_construction_except(catalog, PackedInt32Array(), _luxury_blocking_good(catalog))
	var prices: PackedInt32Array = catalog.good_default_price
	var max_prices: PackedInt32Array = catalog.good_reference_max_price
	prices[cloth] = 1_000_000
	max_prices[cloth] = prices[cloth]
	catalog.good_default_price = prices
	catalog.good_reference_max_price = max_prices
	var stock := PackedInt64Array()
	stock.resize(goods.size() * (cell + 1))
	for good in goods.size():
		if good != cloth:
			stock[cell * goods.size() + good] = input_stock if goods[good] == input else 100_000_000
	var excluded := PackedStringArray()
	if not input.is_empty() and input_stock == 0:
		var good := goods.find(input)
		var offsets: PackedInt32Array = catalog.good_technology_tag_offsets
		var tags: PackedStringArray = catalog.good_technology_tags
		for tag in tags.slice(offsets[good], offsets[good + 1]):
			if tag.begins_with("tech."):
				excluded.append(tag)
	var fixture := {
		"catalog": catalog, "profile": profile, "cell": cell, "excluded": excluded,
		"artisan": artisan, "unemployed": unemployed,
	}
	var ext := _configured_fixture(fixture)
	var boot: Dictionary = ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([cell, cell]),
		"signature_ids": PackedInt32Array([unemployed, signatures.find("merchant|default")]),
		"population": PackedInt64Array([applicants, 1]),
		"funds": PackedInt64Array([cash, 100_000_000]),
	}, {
		"stock": stock,
		"building_cells": PackedInt32Array([cell]),
		"building_type_ids": PackedInt32Array([loom]),
		"building_owner_signature_ids": PackedInt32Array([artisan]),
		"building_counts": PackedInt64Array([count]),
		"building_owner_fill": PackedInt64Array([0]),
	})
	_expect("lifecycle fixture bootstraps", bool(boot.get("ok", false)))
	fixture.ext = ext
	return fixture


func _configured_fixture(fixture: Dictionary) -> Object:
	var cells: int = fixture.cell + 1
	var ext := _new_ext(fixture.catalog, cells)
	_expect("lifecycle fixture configures", CountryTestHelper.configure_all_technologies(
		ext, fixture.catalog, cells, FIXTURE_SEED, PackedByteArray(), fixture.excluded)
		and bool(ext.configure_economy(fixture.catalog, fixture.profile, cells, FIXTURE_SEED).get("ok", false)))
	return ext


func _was_suspended(ext: Object, cell: int, count: int, day: int) -> bool:
	var opening := _settle(ext, day)
	var lots: Dictionary = ext.get_building_cell_snapshot(cell)
	return _balanced(opening) and _snapshot_i64(lots, "group_counts", 0) == count \
		and lots.operating_state == PackedByteArray([1]) \
		and _snapshot_i64(lots, "severe_loss_cycles", 0) == 1


func _test_non_hiring_review() -> void:
	var fixture := _fixture(1, 1, 1, 2_000_000_000)
	var ext: Object = fixture.ext
	# Start the plan period on D7. Cell 1 is reviewed on D8.
	_expect("D7: the first settlement opens the plan period", _balanced(_settle(ext, 7)))
	_expect("D8: an observed vacancy suspends the loom", _was_suspended(ext, 1, 1, 8))
	var review := _settle(ext, 9)
	var waiting: Dictionary = ext.get_building_cell_snapshot(1)
	_expect("D9: liquidation day without mobility keeps the vacant loom and streak",
		_balanced(review) and _snapshot_i64(waiting, "group_counts", 0) == 1
		and waiting.operating_state == PackedByteArray([1])
		and _snapshot_i64(waiting, "severe_loss_cycles", 0) == 1
		and int(review.get("recovery_liquidated_buildings", -1)) == 0)
	var save: Dictionary = ext.capture_economy_ecp2(9)
	_expect("D9: the waiting state can be saved", bool(save.get("ok", false)))
	if not bool(save.get("ok", false)):
		return
	var restored := _configured_fixture(fixture)
	var load_result: Dictionary = restored.restore_economy_ecp2(save.bytes)
	_expect("D9: the waiting state can be restored", bool(load_result.get("ok", false)))
	if not bool(load_result.get("ok", false)):
		return
	var hiring := _settle(ext, 10)
	var restored_hiring := _settle(restored, 10)
	var open: Dictionary = restored.get_building_cell_snapshot(1)
	_expect("D10: the first real opportunity recruits and runs the saved loom",
		_balanced(hiring) and _balanced(restored_hiring)
		and ext.get_economy_state_hash() == restored.get_economy_state_hash()
		and _snapshot_i64(open, "group_counts", 0) == 1
		and _snapshot_i64(open, "filled_owner", 0) == 1
		and _snapshot_i64(open, "severe_loss_cycles", 0) == 0
		and _snapshot_i64(open, "last_output", 0) > 0)


func _test_expired_vacancy_reaches_joint_review() -> void:
	var fixture := _fixture(1, 2, 1, 2_000_000_000)
	var ext: Object = fixture.ext
	_expect("D7: the long-vacancy fixture opens its plan period", _balanced(_settle(ext, 7)))
	_expect("D8: two vacant looms suspend", _was_suspended(ext, 1, 2, 8))
	var waiting := true
	for day in range(9, 25):
		var review := _settle(ext, day)
		var lots: Dictionary = ext.get_building_cell_snapshot(1)
		waiting = waiting and _balanced(review) and _snapshot_i64(lots, "group_counts", 0) == 2 \
			and int(review.get("recovery_liquidated_buildings", -1)) == 0
		if day == 10:
			_expect("D10: the staffed portion runs before the next liquidation date",
				_snapshot_i64(lots, "filled_owner", 0) == 1
				and _snapshot_i64(lots, "last_output", 0) > 0)
	_expect("D9-D24: retirement waits until a hiring and liquidation date coincide", waiting)
	var retirement := _settle(ext, 25)
	var survivor: Dictionary = ext.get_building_cell_snapshot(1)
	_expect("D25: the continuing vacancy costs one loom while its staffed neighbor operates",
		_balanced(retirement) and int(retirement.get("recovery_liquidated_buildings", -1)) == 1
		and _snapshot_i64(survivor, "group_counts", 0) == 1
		and _snapshot_i64(survivor, "filled_owner", 0) == 1
		and _snapshot_i64(survivor, "last_output", 0) > 0)


func _test_disjoint_calendars() -> void:
	# Run this case with PK_ECONOMY_TRACK_B_MOBILITY_SPREAD=4. Cell 0's
	# previous D0 schedule never coincided with a D1 retirement review.
	var fixture := _fixture(0, 2, 1, 2_000_000_000)
	var ext: Object = fixture.ext
	_expect("D0: the unstaffed lot suspends before the synchronized hiring day",
		_was_suspended(ext, 0, 2, 0)
		and _snapshot_i64(ext.get_building_cell_snapshot(0), "filled_owner", 0) == 0)
	var review := _settle(ext, 1)
	var survivor: Dictionary = ext.get_building_cell_snapshot(0)
	_expect("D1: cell 0 has its real hiring opportunity on the original retirement date",
		_balanced(review) and int(review.get("recovery_liquidated_buildings", -1)) == 1
		and _snapshot_i64(survivor, "group_counts", 0) == 1
		and _snapshot_i64(survivor, "filled_owner", 0) == 1
		and _snapshot_i64(survivor, "last_output", 0) > 0)


func _test_partial_recovery(input: String) -> void:
	# When there is a hard input, stock covers seven buildings but not eight.
	var fixture := _fixture(4, 8, 7, 2_000_000_000, input, 750_000)
	var ext: Object = fixture.ext
	_expect("D4: the eight vacant looms reach the suspension threshold", _was_suspended(ext, 4, 8, 4))
	if not input.is_empty():
		var stock := _good_value(ext.get_market_cell_snapshot(4), "stock", input)
		_expect("D4: actual fiber stock covers between seven and eight looms",
			stock >= 700_000 and stock < 800_000)
	var review := _settle(ext, 5)
	var partial: Dictionary = ext.get_building_cell_snapshot(4)
	print("partial recovery: input=%s counts=%s owners=%s output=%s retired=%s" % [
		input, partial.get("group_counts"), partial.get("filled_owner"), partial.get("last_output"),
		review.get("recovery_liquidated_buildings")])
	_expect("D5: seven owners produce and only the eighth loom is retired (input %s)" % input,
		_balanced(review) and _snapshot_i64(partial, "group_counts", 0) == 7
		and _snapshot_i64(partial, "filled_owner", 0) == 7
		and _snapshot_i64(partial, "last_output", 0) > 0
		and int(review.get("recovery_liquidated_buildings", -1)) == 1)


func _test_unavailable_input() -> void:
	var fixture := _fixture(4, 1, 1, 2_000_000_000, "bast_fiber")
	var ext: Object = fixture.ext
	_expect("D4: missing hard input does not hide an actual vacancy", _was_suspended(ext, 4, 1, 4))
	_expect("D4: no reachable fiber candidate yields a quote",
		_good_value(ext.get_market_cell_snapshot(4), "stock", "bast_fiber") == 0
		and _snapshot_i64(ext.get_building_cell_snapshot(4), "last_margin_gap_q16", 0) == -65536)
	var review := _settle(ext, 5)
	var lots: Dictionary = ext.get_building_cell_snapshot(4)
	print("unavailable input: counts=%s margin=%s retired=%s" % [
		lots.get("group_counts"), lots.get("last_margin_gap_q16"),
		review.get("recovery_liquidated_buildings")])
	_expect("D5: expired vacancy with unavailable mandatory fiber is eligible for retirement",
		_balanced(review) and int(review.get("recovery_liquidated_buildings", -1)) == 1
		and _snapshot_i64(lots, "group_counts", 0) == 0)


func _test_unfunded_recovery(count: int, applicants: int) -> void:
	var fixture := _fixture(4, count, applicants, 0, "bast_fiber", 100_000_000)
	var ext: Object = fixture.ext
	_expect("D4: the cashless fixture reaches suspension", _was_suspended(ext, 4, count, 4))
	var review := _settle(ext, 5)
	var lots: Dictionary = ext.get_building_cell_snapshot(4)
	var population: Dictionary = ext.get_population_cell_snapshot(4)
	print("unfunded recovery: counts=%s state=%s seats=%s output=%s approvals=%s" % [
		lots.get("group_counts"), lots.get("operating_state"), lots.get("filled_owner"),
		lots.get("last_output"), review.get("recovery_approved")])
	_expect("D5: a positive stocked quote opens the attempt without creating money",
		_balanced(review) and int(review.get("recovery_approved", -1)) == 1
		and _snapshot_i64(lots, "last_margin_gap_q16", 0) > 0
		and _snapshot_i64(lots, "last_output", 0) == 0)
	_expect("D5: a failed purchase leaves the facility suspended and frees the job",
		_snapshot_i64(lots, "group_counts", 0) == applicants and lots.operating_state == PackedByteArray([1])
		and _snapshot_i64(lots, "severe_loss_cycles", 0) == 1
		and _snapshot_i64(lots, "filled_owner", 0) == 0
		and _snapshot_i64(population, "populations", _row_for_signature(population, fixture.unemployed)) == applicants
		and int(review.get("recovery_liquidated_buildings", -1)) == count - applicants)
