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
	_test_remaining_vacancy_after_failed_purchase()
	_test_recovery_with_incumbent_move()
	_test_loss_suspension_without_vacancy()
	_test_recovery_with_another_ethnicity()
	print("building lifecycle: %d failures" % failures)


func _fixture(cell: int, count: int, applicants: int, cash: int,
		input: String = "", input_stock: int = 0) -> Dictionary:
	return _boot_fixture(_fixture_data(cell, count, applicants, cash, input, input_stock))


func _fixture_data(cell: int, count: int, applicants: int, cash: int,
		input: String, input_stock: int) -> Dictionary:
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
	return {
		"catalog": catalog, "profile": profile, "cell": cell, "excluded": excluded,
		"artisan": artisan, "unemployed": unemployed, "loom": loom,
		"people": {
			"cell_indices": PackedInt32Array([cell, cell]),
			"signature_ids": PackedInt32Array([unemployed, signatures.find("merchant|default")]),
			"population": PackedInt64Array([applicants, 1]),
			"funds": PackedInt64Array([cash, 100_000_000]),
		},
		"buildings": {
			"stock": stock,
			"building_cells": PackedInt32Array([cell]),
			"building_type_ids": PackedInt32Array([loom]),
			"building_owner_signature_ids": PackedInt32Array([artisan]),
			"building_counts": PackedInt64Array([count]),
			"building_owner_fill": PackedInt64Array([0]),
		},
	}


func _boot_fixture(fixture: Dictionary) -> Dictionary:
	var ext := _configured_fixture(fixture)
	var boot: Dictionary = ext.bootstrap_economy(fixture.people, fixture.buildings)
	_expect("lifecycle fixture bootstraps", bool(boot.get("ok", false)))
	fixture.ext = ext
	return fixture


func _configured_fixture(fixture: Dictionary) -> Object:
	var cells: int = fixture.cell + 1
	var ext := _new_ext(fixture.catalog, cells)
	var country_ok := CountryTestHelper.configure_all_technologies(
		ext, fixture.catalog, cells, FIXTURE_SEED, PackedByteArray(), fixture.excluded)
	var configured: Dictionary = ext.configure_economy(fixture.catalog, fixture.profile, cells, FIXTURE_SEED)
	_expect("lifecycle fixture configures", country_ok and bool(configured.get("ok", false)))
	if not country_ok or not bool(configured.get("ok", false)):
		print("  fixture configuration: country=%s economy=%s" % [country_ok, configured.get("reason")])
	return ext


func _was_suspended(ext: Object, cell: int, count: int, day: int) -> bool:
	var opening := _settle(ext, day)
	var lots: Dictionary = ext.get_building_cell_snapshot(cell)
	return _balanced(opening) and _snapshot_i64(lots, "group_counts", 0) == count \
		and lots.operating_state == PackedByteArray([1]) \
		and _snapshot_i64(lots, "owner_vacancy_cycles", 0) == 1 \
		and _snapshot_i64(lots, "vacant_buildings", 0) > 0 \
		and _snapshot_i64(lots, "severe_loss_cycles", 0) == 0


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
		and _snapshot_i64(waiting, "owner_vacancy_cycles", 0) == 1
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
		and _snapshot_i64(open, "owner_vacancy_cycles", 0) == 0
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
		and _snapshot_i64(lots, "severe_loss_cycles", 0) == 0
		and _snapshot_i64(lots, "vacant_buildings", 0) == 0
		and _snapshot_i64(lots, "filled_owner", 0) == 0
		and _snapshot_i64(population, "populations", _row_for_signature(population, fixture.unemployed)) == applicants
		and int(review.get("recovery_liquidated_buildings", -1)) == count - applicants)


func _queue_stock(ext: Object, cell: int, good: int, day: int, quantity: int) -> bool:
	var market: Dictionary = ext.get_market_cell_snapshot(cell)
	return bool(ext.submit_economy_commands({
		"opcodes": PackedInt32Array([4 if quantity > 0 else 5]),
		"effective_days": PackedInt64Array([day]),
		"sequences": PackedInt64Array([day]),
		"target_handles": PackedInt64Array([0]),
		"i32_0": PackedInt32Array([int(market.get("market_id", -1))]),
		"i32_1": PackedInt32Array([good]),
		"i64_0": PackedInt64Array([absi(quantity)]),
		"i64_1": PackedInt64Array([0]),
	}).get("ok", false))


func _test_remaining_vacancy_after_failed_purchase() -> void:
	var fixture := _fixture_data(4, 8, 5, 0, "bast_fiber", 0)
	var fiber: int = fixture.catalog.good_ids.find("bast_fiber")
	fixture.buildings.stock[4 * fixture.catalog.good_ids.size() + fiber] = 100_000_000
	var ext: Object = _boot_fixture(fixture).ext
	_expect("D4: the eight looms suspend", _was_suspended(ext, 4, 8, 4))
	var review := _settle(ext, 5)
	var lots: Dictionary = ext.get_building_cell_snapshot(4)
	_expect("D5: only two of the three vacant looms retire and failed purchases release the five owners",
		_balanced(review) and int(review.get("recovery_liquidated_buildings", -1)) == 2
		and _snapshot_i64(lots, "group_counts", 0) == 6
		and _snapshot_i64(lots, "filled_owner", 0) == 0)
	_expect("D8: the remaining fiber stock is removed before the next plan",
		_queue_stock(ext, 4, fiber, 8, -100_000_000)
		and _balanced(_settle(ext, 8))
		and _good_value(ext.get_market_cell_snapshot(4), "stock", "bast_fiber") == 0)
	review = _settle(ext, 9)
	lots = ext.get_building_cell_snapshot(4)
	print("remaining vacancy: groups=%s vacancies=%s retired=%s stock=%s" % [
		lots.get("group_counts"), lots.get("vacant_buildings"), review.get("recovery_liquidated_buildings"),
		_good_value(ext.get_market_cell_snapshot(4), "stock", "bast_fiber")])
	_expect("D9: a loss of inputs can retire only the one remaining observed vacancy",
		_balanced(review) and int(review.get("recovery_liquidated_buildings", -1)) == 1
		and _snapshot_i64(lots, "group_counts", 0) == 5
		and _snapshot_i64(lots, "vacant_buildings", 0) == 0)


func _test_recovery_with_incumbent_move() -> void:
	var fixture := _fixture_data(1, 1, 1, 2_000_000_000, "bast_fiber", 0)
	var catalog: Dictionary = fixture.catalog
	var source_type: int = catalog.building_type_ids.find("flint_quarry")
	var forager: int = catalog.signature_keys.find("forager|default")
	var fiber: int = catalog.good_ids.find("bast_fiber")
	_strip_building_inputs(catalog, source_type)
	_clear_building_climate(catalog, source_type)
	fixture.people.signature_ids[0] = forager
	fixture.buildings.building_cells.append(1)
	fixture.buildings.building_type_ids.append(source_type)
	fixture.buildings.building_owner_signature_ids.append(forager)
	fixture.buildings.building_counts.append(1)
	fixture.buildings.building_owner_fill.append(1)
	var ext: Object = _boot_fixture(fixture).ext
	_expect("D6: incumbent transfer fixture opens", _balanced(_settle(ext, 6)))
	_expect("D7: the vacant loom reaches its plan review without fiber",
		_balanced(_settle(ext, 7)))
	_expect("D8: fiber arrives after planning so the D9 review can quote it",
		_queue_stock(ext, 1, fiber, 8, 100_000_000))
	var suspension := _settle(ext, 8)
	var before: Dictionary = ext.get_building_cell_snapshot(1)
	var source: int = before.group_type_ids.find(source_type)
	var target: int = before.group_type_ids.find(fixture.loom)
	_expect("D8: the loom is suspended while the only eligible person holds a quarry job",
		_balanced(suspension) and source >= 0 and target >= 0
		and before.operating_state[target] == 1
		and _snapshot_i64(before, "filled_owner", source) == 1
		and _snapshot_i64(before, "filled_owner", target) == 0)
	_expect("D8: the fiber is on the shelf for the next plan",
		_good_value(ext.get_market_cell_snapshot(1), "stock", "bast_fiber") >= 100_000)
	var review := _settle(ext, 9)
	var after: Dictionary = ext.get_building_cell_snapshot(1)
	source = after.group_type_ids.find(source_type)
	target = after.group_type_ids.find(fixture.loom)
	print("incumbent recovery: approvals=%s moves=%s owners=%s margin=%s retired=%s stock=%s" % [
		review.get("recovery_approved"), review.get("building_owner_job_reallocations"), after.get("filled_owner"),
		after.get("last_margin_gap_q16"), review.get("recovery_liquidated_buildings"),
		_good_value(ext.get_market_cell_snapshot(1), "stock", "bast_fiber")])
	_expect("D9: actual incumbent transfer can restart and operate on the unemployment hiring rest day",
		_balanced(review) and int(review.get("building_owner_job_reallocations", 0)) == 1
		and _snapshot_i64(after, "filled_owner", source) == 0
		and _snapshot_i64(after, "filled_owner", target) == 1
		and _snapshot_i64(after, "last_output", target) > 0
		and int(review.get("recovery_liquidated_buildings", -1)) == 0)


func _test_loss_suspension_without_vacancy() -> void:
	var fixture := _fixture_data(4, 1, 1, 2_000_000_000, "bast_fiber", 0)
	var catalog: Dictionary = fixture.catalog
	var cloth: int = catalog.good_ids.find("cloth")
	var fiber: int = catalog.good_ids.find("bast_fiber")
	var lane: int = 4 * catalog.good_ids.size()
	_minimize_household_good_demand(catalog, cloth)
	catalog.good_default_price[cloth] = 1
	catalog.good_reference_max_price[cloth] = 1
	catalog.good_default_price[fiber] = 100_000
	catalog.good_reference_max_price[fiber] = 100_000
	fixture.buildings.stock[lane + cloth] = 100_000_000
	fixture.buildings.stock[lane + fiber] = 100_000_000
	fixture.buildings.building_owner_fill[0] = 1
	fixture.people.signature_ids[0] = fixture.artisan
	var ext: Object = _boot_fixture(fixture).ext
	var opening := _settle(ext, 3)
	var producing: Dictionary = ext.get_building_cell_snapshot(4)
	print("loss fixture D3: owners=%s input=%s output=%s revenue=%s" % [
		producing.get("filled_owner"), producing.get("last_input_cost"),
		producing.get("last_output"), producing.get("last_revenue")])
	_expect("D3: a filled loom has a settled operating loss",
		_balanced(opening) and _snapshot_i64(producing, "filled_owner", 0) == 1
		and _snapshot_i64(producing, "last_output", 0) > 0
		and _snapshot_i64(producing, "last_input_cost", 0) >
			_snapshot_i64(producing, "last_revenue", 0))
	var loss := _settle(ext, 4)
	var closed: Dictionary = ext.get_building_cell_snapshot(4)
	_expect("D4: measured financial loss suspends the loom and releases the owner",
		_balanced(loss) and closed.operating_state == PackedByteArray([1])
		and _snapshot_i64(closed, "severe_loss_cycles", 0) == 1
		and _snapshot_i64(closed, "owner_vacancy_cycles", 0) == 0
		and _snapshot_i64(closed, "filled_owner", 0) == 0)
	_expect("D5: the last mandatory fiber stock is removed before the review",
		_queue_stock(ext, 4, fiber, 5, -100_000_000))
	var review := _settle(ext, 5)
	var after: Dictionary = ext.get_building_cell_snapshot(4)
	print("loss fixture D5: groups=%s retired=%s" % [
		after.get("group_counts"), review.get("recovery_liquidated_buildings")])
	_expect("D5: a job released by loss suspension is not a measured vacancy",
		_balanced(review) and _good_value(ext.get_market_cell_snapshot(4), "stock", "bast_fiber") == 0
		and _snapshot_i64(after, "group_counts", 0) == 1
		and int(review.get("recovery_liquidated_buildings", -1)) == 0)


func _test_recovery_with_another_ethnicity() -> void:
	var fixture := _fixture_data(4, 1, 1, 2_000_000_000, "bast_fiber", 100_000_000)
	var catalog: Dictionary = fixture.catalog
	catalog.ethnicity_ids.append("test_ethnicity")
	catalog.ethnicity_culture_group_ids.append(catalog.ethnicity_culture_group_ids[0])
	catalog.ethnicity_need_factor_q16.append_array(catalog.ethnicity_need_factor_q16.duplicate())
	var signature_count: int = catalog.signature_keys.size()
	var weights: PackedInt32Array = catalog.signature_satisfaction_dimension_weights_q16.duplicate()
	catalog.signature_satisfaction_dimension_weights_q16.append_array(weights)
	for key in ["signature_profession_ids", "signature_plan_ids", "signature_birth_rate_q32",
			"signature_death_rate_q32", "signature_satisfaction_birth_weight_q16"]:
		var values: Variant = catalog[key]
		values.append_array(values.duplicate())
		catalog[key] = values
	for signature in signature_count:
		catalog.signature_keys.append(catalog.signature_keys[signature].replace("|default", "|test_ethnicity"))
		catalog.signature_ethnicity_ids.append(1)
	fixture.people.signature_ids[0] = signature_count + fixture.unemployed
	fixture.profile.economy_trace_mode = "SELECTIVE"
	var ext: Object = _boot_fixture(fixture).ext
	_expect("cross-ethnicity recovery enables employment tracing",
		bool(ext.set_economy_trace_filter({"cells": PackedInt32Array([4])}).get("ok", false)))
	_expect("D4: the loom has opened and then closed its vacant job", _was_suspended(ext, 4, 1, 4))
	var review := _settle(ext, 5)
	var after: Dictionary = ext.get_building_cell_snapshot(4)
	var population: Dictionary = ext.get_population_cell_snapshot(4)
	var employed := _row_for_signature(population, signature_count + fixture.artisan)
	var schema: Dictionary = ext.get_economy_event_schema()
	var employment: Dictionary = ext.poll_economy_events({
		"kind": int(schema.kinds.EMPLOYMENT_SETTLED), "cell": 4})
	var filled_during_employment := false
	for i in int(employment.get("count", 0)):
		filled_during_employment = filled_during_employment or (
			employment.commit_day[i] == 5 and employment.value0[i] == 1)
	_expect("D5: normal employment actually fills the owner seat before production", filled_during_employment)
	print("cross-ethnicity recovery: hires=%s owners=%s output=%s signatures=%s" % [
		filled_during_employment, after.get("filled_owner"), after.get("last_output"),
		population.get("signature_ids")])
	_expect("D5: the recruited owner keeps their ethnicity, pays for fiber and produces cloth",
		_balanced(review)
		and _row_for_signature(population, fixture.artisan) < 0
		and after.owner_signature_ids == PackedInt32Array([fixture.artisan])
		and _snapshot_i64(population, "populations", employed) == 1
		and _snapshot_i64(after, "filled_owner", 0) == 1
		and _snapshot_i64(after, "last_input_cost", 0) > 0
		and _snapshot_i64(after, "last_output", 0) > 0)
	var continued := _settle(ext, 6)
	var continuing: Dictionary = ext.get_building_cell_snapshot(4)
	_expect("D6: the same job remains open and staffed without another recovery",
		_balanced(continued) and int(continued.get("recovery_approved", -1)) == 0
		and _snapshot_i64(continuing, "filled_owner", 0) == 1
		and _snapshot_i64(continuing, "last_output", 0) > 0)
