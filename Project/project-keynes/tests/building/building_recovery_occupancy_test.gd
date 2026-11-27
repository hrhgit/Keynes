extends "res://tests/building/building_runtime_test.gd"


func _run() -> void:
	_test_vacant_looms(false)
	_test_vacant_looms(true)
	print("building recovery occupancy: %d failures" % failures)


func _test_vacant_looms(block_mobility: bool) -> void:
	var catalog := EconomyCatalogScript.compile_native_catalog()
	var profile: Dictionary = load("res://data/economy/default_economy.tres").to_native_profile()
	profile.market_runtime_mode = "ACTIVE"
	profile.market_cycle_days = 5
	profile.economy_cadence_force_market_days = 5
	profile.economy_cadence_force_plan_days = 5
	profile.economy_cadence_force_investment_days = 10
	profile.startup_demand_runtime_mode = "OFF"
	profile.family_runtime_mode = "OFF"
	profile.investment_max_growth_share_q16 = 0
	profile.building_severe_loss_cycles = 1
	profile.starvation_death_rate_q32 = 0
	if block_mobility:
		profile.employment_mobility_daily_q16 = 0
	var birth_rates: PackedInt64Array = catalog.signature_birth_rate_q32
	birth_rates.fill(0)
	catalog.signature_birth_rate_q32 = birth_rates
	var death_rates: PackedInt64Array = catalog.signature_death_rate_q32
	death_rates.fill(0)
	catalog.signature_death_rate_q32 = death_rates
	var loom := (catalog.building_type_ids as PackedStringArray).find("household_loom")
	var signatures: PackedStringArray = catalog.signature_keys
	var artisan := signatures.find("artisan|default")
	var merchant := signatures.find("merchant|default")
	var unemployed := signatures.find("unemployed|default")
	_strip_building_inputs(catalog, loom)
	_strip_building_resources(catalog, loom)
	_clear_building_climate(catalog, loom)
	_block_construction_except(catalog, PackedInt32Array(), _luxury_blocking_good(catalog))
	var goods: PackedStringArray = catalog.good_ids
	var cloth := goods.find("cloth")
	var prices: PackedInt32Array = catalog.good_default_price
	var max_prices: PackedInt32Array = catalog.good_reference_max_price
	prices[cloth] = 1_000_000
	max_prices[cloth] = prices[cloth]
	catalog.good_default_price = prices
	catalog.good_reference_max_price = max_prices
	var stock := PackedInt64Array()
	stock.resize(goods.size())
	stock.fill(100_000_000)
	stock[cloth] = 0

	var ext := _new_ext(catalog)
	_expect("vacancy fixture's country bootstraps",
		CountryTestHelper.configure_all_technologies(ext, catalog, 1, 293))
	_expect("vacancy fixture's economy configures",
		bool(ext.configure_economy(catalog, profile, 1, 293).get("ok", false)))
	var people := {
		"cell_indices": PackedInt32Array([0, 0]),
		"signature_ids": PackedInt32Array([artisan, merchant]),
		"population": PackedInt64Array([1, 1]),
		"funds": PackedInt64Array([100_000_000, 100_000_000]),
	}
	if block_mobility:
		people.cell_indices.append(0)
		people.signature_ids.append(unemployed)
		people.population.append(1)
		people.funds.append(100_000_000)
	_expect("one owner starts with two looms",
		bool(ext.bootstrap_economy(people, {
			"stock": stock,
			"building_cells": PackedInt32Array([0]),
			"building_type_ids": PackedInt32Array([loom]),
			"building_owner_signature_ids": PackedInt32Array([artisan]),
			"building_counts": PackedInt64Array([2]),
			"building_owner_fill": PackedInt64Array([1]),
		}).get("ok", false)))
	var opening := _run_day(ext, 0)
	var suspended: Dictionary = ext.get_building_cell_snapshot(0)
	_expect("the vacant loom triggers suspension while both lots still exist",
		bool(opening.get("done", false)) and not bool(opening.get("fatal", false))
		and _snapshot_i64(suspended, "group_counts", 0) == 2
		and (suspended.operating_state as PackedByteArray)[0] == 1
		and _snapshot_i64(suspended, "severe_loss_cycles", 0) == 1)
	var review := _run_day(ext, 1)
	var reduced: Dictionary = ext.get_building_cell_snapshot(0)
	print("vacancy review: mobility_blocked=%s approvals=%s retired=%s counts=%s margin=%s" % [
		block_mobility, review.get("recovery_approved"), review.get("recovery_liquidated_buildings"),
		reduced.get("group_counts"), reduced.get("last_margin_gap_q16")])
	var rejection_description := "positive restart quote cannot preserve an expired vacant lot"
	if block_mobility:
		var population: Dictionary = ext.get_population_cell_snapshot(0)
		var pool_row := _row_for_signature(population, unemployed)
		_expect("two local people are present but their only hiring path is disabled",
			_snapshot_i64(population, "populations", pool_row) == 2
			and _snapshot_i64(reduced, "filled_owner", 0) == 0)
		rejection_description = "unavailable unemployed people cannot prevent vacancy liquidation"
	_expect(rejection_description,
		bool(review.get("done", false)) and not bool(review.get("fatal", false))
		and _snapshot_i64(reduced, "last_margin_gap_q16", 0) > 0
		and int(review.get("recovery_approved", -1)) == 0
		and int(review.get("recovery_liquidated_buildings", 0)) == 1
		and _snapshot_i64(reduced, "group_counts", 0) == 1)
	if block_mobility:
		return
	var next_review := _run_day(ext, 2)
	var resumed := _run_day(ext, 3)
	var active: Dictionary = ext.get_building_cell_snapshot(0)
	_expect("the remaining loom restarts with the available owner",
		int(next_review.get("recovery_approved", 0)) == 1
		and bool(resumed.get("done", false)) and not bool(resumed.get("fatal", false))
		and _snapshot_i64(active, "group_counts", 0) == 1
		and (active.operating_state as PackedByteArray)[0] == 0
		and _snapshot_i64(active, "filled_owner", 0) == 1
		and _snapshot_i64(active, "last_output", 0) > 0)
