extends "res://tests/building/building_runtime_test.gd"

const SEED := 293
const CELL := 4
const CELL_COUNT := CELL + 1
const OPENING_DAY := 4
const REVIEW_DAY := 5


func _run() -> void:
	_test_vacant_looms("one local owner", 0, 65536, false, true, false, 1)
	_test_vacant_looms("mobility disabled", 2, 0, false, true, false, 0)
	_test_vacant_looms("entry savings missing", 2, 65536, true, false, false, 0)
	_test_vacant_looms("both seats filled", 2, 65536, true, true, false, 2)
	_test_vacant_looms("only one move", 2, 655, true, true, false, 1)
	_test_vacant_looms("two groups share one move", 2, 655, true, true, false, 1, true)
	_test_vacant_looms("funded unemployment subsidy", 2, 65536, true, true, true, 2)
	print("building recovery occupancy: %d failures" % failures)


func _test_vacant_looms(label: String, applicants: int, mobility_q16: int,
		require_savings: bool, funded: bool, subsidy: bool, hired: int,
		separate_groups: bool = false) -> void:
	var catalog := EconomyCatalogScript.compile_native_catalog()
	var profile: Dictionary = load("res://data/economy/default_economy.tres").to_native_profile()
	profile.market_runtime_mode = "ACTIVE"
	profile.economy_cadence_force_market_days = 1
	profile.economy_cadence_force_plan_days = 5
	profile.economy_cadence_force_investment_days = 10
	profile.startup_demand_runtime_mode = "OFF"
	profile.family_runtime_mode = "OFF"
	profile.investment_max_growth_share_q16 = 0
	profile.building_severe_loss_cycles = 1
	profile.starvation_death_rate_q32 = 0
	profile.employment_mobility_daily_q16 = mobility_q16
	for key in ["signature_birth_rate_q32", "signature_death_rate_q32"]:
		var rates: PackedInt64Array = catalog[key]
		rates.fill(0)
		catalog[key] = rates
	var types: PackedStringArray = catalog.building_type_ids
	var looms := PackedInt32Array([types.find("household_loom")])
	if separate_groups:
		looms.push_back(types.find("improved_domestic_loom"))
	var signatures: PackedStringArray = catalog.signature_keys
	var artisan := signatures.find("artisan|default")
	var merchant := signatures.find("merchant|default")
	var unemployed := signatures.find("unemployed|default")
	if require_savings:
		var entry_days: PackedInt32Array = catalog.profession_entry_savings_days
		entry_days[catalog.signature_profession_ids[artisan]] = 36500
		catalog.profession_entry_savings_days = entry_days
	for loom in looms:
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
	stock.resize(goods.size() * CELL_COUNT)
	for good in goods.size():
		if good != cloth:
			stock[CELL * goods.size() + good] = 100_000_000

	var ext := _new_ext(catalog, CELL_COUNT)
	var country_handle := _configure_vacancy_country(ext, catalog)
	_expect(label + ": country and economy configure",
		country_handle != 0 and bool(ext.configure_economy(
			catalog, profile, CELL_COUNT, SEED).get("ok", false)))
	if subsidy:
		_expect(label + ": unemployment subsidy is in force",
			_set_unemployment_subsidy(ext, country_handle, catalog.signature_profession_ids[unemployed]))
	var funds := (2_000_000_000 if require_savings else 100_000_000) if funded else 0
	var has_incumbent := applicants == 0
	var people := {
		"cell_indices": PackedInt32Array([CELL, CELL]),
		"signature_ids": PackedInt32Array([artisan if has_incumbent else unemployed, merchant]),
		"population": PackedInt64Array([1 if has_incumbent else applicants, 1]),
		"funds": PackedInt64Array([funds, 100_000_000]),
	}
	var boot: Dictionary = ext.bootstrap_economy(people, {
		"stock": stock,
		"building_cells": PackedInt32Array([CELL, CELL] if separate_groups else [CELL]),
		"building_type_ids": looms,
		"building_owner_signature_ids": PackedInt32Array([artisan, artisan] if separate_groups else [artisan]),
		"building_counts": PackedInt64Array([1, 1] if separate_groups else [2]),
		"building_owner_fill": PackedInt64Array([0, 0] if separate_groups else [1 if has_incumbent else 0]),
	})
	_expect(label + ": two looms bootstrap", bool(boot.get("ok", false)))
	if not bool(boot.get("ok", false)):
		return
	# The opening settlement is off the normal mobility date. The next
	# settlement is both a mobility and a recovery-review date.
	var opening := _settle(ext, OPENING_DAY)
	var suspended: Dictionary = ext.get_building_cell_snapshot(CELL)
	var pool: Dictionary = ext.get_population_cell_snapshot(CELL)
	var pool_row := _row_for_signature(pool, unemployed)
	print("vacancy opening ", label, {
		"state": suspended.get("operating_state"), "seats": suspended.get("filled_owner"),
		"vacancy_streak": suspended.get("severe_loss_cycles"),
		"pool": _snapshot_i64(pool, "populations", pool_row),
		"pool_cash": _snapshot_i64(pool, "funds_by_cohort", pool_row),
	})
	_expect(label + ": an actual opening vacancy suspends both lots",
		_balanced(opening) and _sum_i64(suspended.group_counts) == 2
		and (suspended.operating_state as PackedByteArray).count(1) == looms.size()
		and (suspended.severe_loss_cycles as PackedInt32Array).count(1) == looms.size())
	if applicants > 0:
		_expect(label + ": both applicants are present for the next review",
			_snapshot_i64(pool, "populations", pool_row) == applicants
			and (_snapshot_i64(pool, "funds_by_cohort", pool_row) > 0) == funded)
	if subsidy:
		_expect(label + ": the idle applicants were actually paid a subsidy",
			_sum_i64(ext.get_country_fiscal_snapshot(
				country_handle).get("subsidy_paid", PackedInt64Array())) > 0)
	var review := _settle(ext, REVIEW_DAY)
	var lots: Dictionary = ext.get_building_cell_snapshot(CELL)
	var remaining: Dictionary = ext.get_population_cell_snapshot(CELL)
	var remaining_pool := _row_for_signature(remaining, unemployed)
	print("vacancy review ", label, {
		"approval": review.get("recovery_approved"), "retired": review.get("recovery_liquidated_buildings"),
		"count": lots.get("group_counts"), "seats": lots.get("filled_owner"),
		"vacancy_streak": lots.get("severe_loss_cycles"),
		"pool": _snapshot_i64(remaining, "populations", remaining_pool),
		"margin": lots.get("last_margin_gap_q16"),
	})
	_expect(label + ": every viable lot opens its jobs for this review",
		int(review.get("recovery_approved", -1)) == looms.size())
	_expect(label + ": the review uses the actual number of filled seats",
		_balanced(review) and _snapshot_i64(lots, "last_margin_gap_q16", 0) > 0
		and _snapshot_i64(lots, "filled_owner", 0) == hired)
	if hired == 2:
		_expect(label + ": actual full staffing preserves both looms and clears the streak",
			_snapshot_i64(lots, "group_counts", 0) == 2
			and int(review.get("recovery_liquidated_buildings", -1)) == 0
			and _snapshot_i64(lots, "severe_loss_cycles", 0) == 0
			and _snapshot_i64(lots, "last_output", 0) > 0)
	else:
		_expect(label + ": an approval cannot clear an actual unfilled streak",
			_snapshot_i64(lots, "group_counts", 0) == 1
			and int(review.get("recovery_liquidated_buildings", -1)) == 1)
		if hired == 1:
			var resumed := _settle(ext, REVIEW_DAY + 5)
			var survivor: Dictionary = ext.get_building_cell_snapshot(CELL)
			_expect(label + ": the surviving loom is viable with its actual owner",
				_balanced(resumed) and _snapshot_i64(survivor, "group_counts", 0) == 1
				and _snapshot_i64(survivor, "filled_owner", 0) == 1
				and _snapshot_i64(survivor, "last_output", 0) > 0)


func _configure_vacancy_country(ext: Object, catalog: Dictionary) -> int:
	var profile := {
		"country_runtime_mode": "ACTIVE",
		"starting_technology_ids": catalog.technology_ids,
	}
	if not bool(ext.configure_country(catalog, profile, CELL_COUNT, SEED).get("ok", false)):
		return 0
	var water := PackedByteArray()
	water.resize(CELL_COUNT)
	var boot: Dictionary = ext.bootstrap_country({
		"country_ids": PackedStringArray(["country.vacancy_test"]),
		"country_names": PackedStringArray(["Vacancy test"]),
		"country_cash": PackedInt64Array([1_000_000_000]),
		"territory_offsets": PackedInt32Array([0, 1]),
		"territory_cells": PackedInt32Array([CELL]),
	}, water)
	return int(ext.get_country_cell_summary(CELL).get("country_handle", 0)) if boot.get("ok", false) else 0


func _set_unemployment_subsidy(ext: Object, country_handle: int, profession: int) -> bool:
	var commands: Array[Dictionary] = [{
		"opcode": 12, "effective_day": 0, "sequence": 1,
		"target_handle": country_handle, "tax_kind": 0,
		"tax_item": profession, "tax_rate_percent": -100,
	}]
	return bool(ext.submit_country_commands(CountryCommandBatch.pack(
		commands, true, 0)).get("ok", false)) and bool(ext.run_country_slice(
			{"day_index": 0}).get("ok", false))


func _settle(ext: Object, day: int) -> Dictionary:
	var report: Dictionary = ext.run_economy_slice({"day_index": day})
	while not bool(report.get("done", false)) and not bool(report.get("fatal", false)):
		report = ext.run_economy_slice({"day_index": day})
	return report


func _balanced(report: Dictionary) -> bool:
	return bool(report.get("done", false)) and not bool(report.get("fatal", false)) \
		and int(report.get("population_error", 1)) == 0 \
		and int(report.get("money_error", 1)) == 0 and int(report.get("goods_error", 1)) == 0
