extends "res://tests/building/building_lifecycle_test.gd"


func _run() -> void:
	_test_accounts(false)
	_test_accounts(true)
	_test_ineligible_debtor()
	_test_shared_lot()
	print("building owner settlement: %d failures" % failures)


func _add_ethnicities(catalog: Dictionary) -> int:
	var base: int = catalog.signature_keys.size()
	for ethnicity in [1, 2]:
		catalog.ethnicity_ids.append("test_%d" % ethnicity)
		catalog.ethnicity_culture_group_ids.append(catalog.ethnicity_culture_group_ids[0])
		var needs: PackedInt32Array = catalog.ethnicity_need_factor_q16
		catalog.ethnicity_need_factor_q16.append_array(needs.slice(0, needs.size() / ethnicity))
		for key in ["signature_satisfaction_dimension_weights_q16", "signature_profession_ids",
				"signature_plan_ids", "signature_birth_rate_q32", "signature_death_rate_q32",
				"signature_satisfaction_birth_weight_q16"]:
			var values: Variant = catalog[key]
			values.append_array(values.slice(0, values.size() / ethnicity))
			catalog[key] = values
		for sig in base:
			catalog.signature_keys.append(catalog.signature_keys[sig].replace("|default", "|test_%d" % ethnicity))
			catalog.signature_ethnicity_ids.append(ethnicity)
	return base


func _add_workshop(fixture: Dictionary, artisan: int) -> void:
	var workshop: int = fixture.catalog.building_type_ids.find("knapping_workshop")
	_strip_building_inputs(fixture.catalog, workshop)
	fixture.people.cell_indices.append(fixture.cell)
	fixture.people.signature_ids.append(artisan)
	fixture.people.population.append(1)
	fixture.people.funds.append(200_000_000)
	fixture.buildings.building_cells.append(fixture.cell)
	fixture.buildings.building_type_ids.append(workshop)
	fixture.buildings.building_owner_signature_ids.append(artisan)
	fixture.buildings.building_counts.append(1)
	fixture.buildings.building_owner_fill.append(1)


# Add an ordinary outstanding loan to the first existing building in a real PKEC stream.
# Restore through the public reader, including its original catalog and country checks.
func _loan_world(source: Object, fixture: Dictionary) -> Object:
	var target := _configured_fixture(fixture)
	var begin: Dictionary = source.begin_economy_save(65536)
	var start: Dictionary = target.begin_economy_restore()
	_expect("loan fixture starts native save and restore", begin.get("ok", false) and start.get("ok", false))
	var edited := false
	while true:
		var chunk: PackedByteArray = source.read_economy_save_chunk(65536)
		if chunk.is_empty():
			break
		if chunk.decode_u16(6) == 5 and not edited:
			_expect("first saved building is the loom", chunk.decode_s32(20) == fixture.loom)
			chunk.encode_u16(16 + 227, 2)
			chunk.encode_s64(16 + 231, 20_000)
			edited = true
		var fed: Dictionary = target.feed_economy_restore_chunk(chunk)
		if not fed.get("ok", false):
			_expect("loan fixture reads building debt %s" % fed, false)
			break
	source.end_economy_save()
	var restored: Dictionary = target.end_economy_restore()
	_expect("loan enters the live building through restore %s" % restored.get("reason", ""),
		edited and restored.get("ok", false))
	target.set_economy_inspector_trace_cell(fixture.cell)
	return target


func _test_accounts(registrant_present: bool) -> void:
	var f := _fixture_data(4, 1, 1, 2_000_000_000, "bast_fiber", 100_000_000)
	var base := _add_ethnicities(f.catalog)
	var actual: int = base * 2 + f.artisan
	f.people.signature_ids[0] = base * 2 + f.unemployed
	if not registrant_present:
		f.buildings.building_owner_signature_ids[0] = base + f.artisan
	_add_workshop(f, f.artisan)
	var tool: int = f.catalog.good_ids.find("chipped_stone_tools")
	f.buildings.stock[f.cell * f.catalog.good_ids.size() + tool] = 0
	f.catalog.good_default_price[tool] = 10_000_000
	f.catalog.good_reference_max_price[tool] = 10_000_000
	var output: int = f.catalog.building_output_offsets[f.catalog.building_type_ids.find("knapping_workshop")]
	f.catalog.building_output_quantities[output] = 100_000
	f.profile.economy_trace_mode = "SELECTIVE"
	var source: Object = _boot_fixture(f).ext
	var opening := _settle(source, 4)
	var initial: Dictionary = source.get_building_cell_snapshot(4)
	print("D4 types=%s owners=%s moves=%s" % [initial.group_type_ids, initial.filled_owner, opening.get("building_owner_job_reallocations")])
	_expect("D4: one empty loom and one staffed workshop", _balanced(opening)
		and initial.filled_owner == PackedInt64Array([0, 1]))
	var ext := _loan_world(source, f)
	var review := _settle(ext, 5)
	var lots: Dictionary = ext.get_building_cell_snapshot(4)
	var pop: Dictionary = ext.get_population_cell_snapshot(4)
	var hired := _row_for_signature(pop, actual)
	var incumbent := _row_for_signature(pop, f.artisan)
	print("registered present=%s jobs=%s debt=%s outputs=%s" % [
		registrant_present, lots.filled_owner, lots.merchant_debt_principal, lots.last_output])
	_expect("D5: both groups have an owner and the loom pays the instalment", _balanced(review)
		and lots.filled_owner == PackedInt64Array([1, 1])
		and _snapshot_i64(lots, "last_input_cost", 0) > 0 and _snapshot_i64(lots, "last_output", 0) > 0
		and _snapshot_i64(lots, "merchant_debt_principal", 0) == 10_000)
	_expect("D5: fibre, loan and sale are booked to the actual loom owner",
		_cashflow_has_source(pop, hired, "production_inputs", false)
		and _cashflow_has_source(pop, hired, "other", false)
		and (_cashflow_has_source(pop, hired, "owner_operations", true)
			or _cashflow_has_source(pop, hired, "producer_support_issuance", true))
		and not _cashflow_has_source(pop, incumbent, "other", false))
	var wire: Dictionary = ext.capture_economy_ecp2(5)
	var cold := _configured_fixture(f)
	var loaded: Dictionary = cold.restore_economy_ecp2(wire.bytes)
	cold.set_economy_inspector_trace_cell(4)
	if registrant_present:
		_test_owner_archive(ext, f, actual, base + f.artisan)
	var warm_day := _settle(ext, 6)
	var cold_day := _settle(cold, 6)
	pop = cold.get_population_cell_snapshot(4)
	hired = _row_for_signature(pop, actual)
	_expect("D6: cold load preserves the real borrower's last payment and production",
		loaded.get("ok", false) and _balanced(warm_day) and _balanced(cold_day)
		and ext.get_economy_state_hash() == cold.get_economy_state_hash()
		and _cashflow_has_source(pop, hired, "other", false)
		and _cashflow_has_source(pop, hired, "production_inputs", false))


func _test_ineligible_debtor() -> void:
	var f := _fixture_data(4, 1, 0, 0, "", 0)
	_add_workshop(f, f.artisan)
	f.people.cell_indices = PackedInt32Array([4, 4])
	f.people.signature_ids = PackedInt32Array([f.artisan, f.catalog.signature_keys.find("merchant|default")])
	f.people.population = PackedInt64Array([2, 1])
	f.people.funds = PackedInt64Array([2_000_000_000, 100_000_000])
	f.buildings.building_owner_fill[0] = 1
	f.excluded = PackedStringArray(["tech.weaving"])
	f.profile.economy_trace_mode = "SELECTIVE"
	var source: Object = _boot_fixture(f).ext
	_expect("unlicensed debtor reaches a save boundary", _balanced(_settle(source, 3)))
	var ext := _loan_world(source, f)
	var day := _settle(ext, 4)
	var lots: Dictionary = ext.get_building_cell_snapshot(4)
	var pop: Dictionary = ext.get_population_cell_snapshot(4)
	var row := _row_for_signature(pop, f.artisan)
	print("unlicensed borrower: balance=%s output=%s principal=%s repaid=%s" % [
		_snapshot_i64(pop, "funds_by_cohort", row), lots.last_output, lots.merchant_debt_principal,
		day.get("merchant_credit_repaid")])
	_expect("unlicensed loom makes no cloth and its solvent registered owner repays on time",
		_balanced(day) and _snapshot_i64(lots, "last_output", 0) == 0
		and _snapshot_i64(pop, "funds_by_cohort", row) > 10_000
		and _snapshot_i64(lots, "merchant_debt_principal", 0) == 10_000
		and _snapshot_i64(lots, "merchant_debt_delinquent_cycles", 0) == 0
		and _cashflow_has_source(pop, row, "other", false))

# These are native PKEC chunks. Version 66 ends the fixed business record at
# offset 337. Version 67 then carries the non-registered seats before the roles.
func _test_owner_archive(source: Object, f: Dictionary, actual: int, absent: int) -> void:
	var saved: Dictionary = source.begin_economy_save(65536)
	_expect("typed owner fixture reaches a save boundary", saved.get("ok", false))
	var chunks: Array[PackedByteArray] = []
	var building_chunk := -1
	while true:
		var bytes: PackedByteArray = source.read_economy_save_chunk(65536)
		if bytes.is_empty():
			break
		if bytes.decode_u16(6) == 5:
			building_chunk = chunks.size()
		chunks.append(bytes)
	source.end_economy_save()
	const FIRST_OWNER := 16 + 337
	var building := chunks[building_chunk]
	var expected := (building.decode_u16(4) == 67 and building.decode_u32(8) == 2
		and building.decode_u32(FIRST_OWNER) == 1 and building.decode_s32(FIRST_OWNER + 4) == actual
		and building.decode_s64(FIRST_OWNER + 8) == 1)
	_expect("PKEC records the hired cohort on its building", expected)
	if not expected:
		return
	for case in ["registered", "absent", "profession", "count"]:
		var copy := building.duplicate()
		match case:
			"registered": copy.encode_s32(FIRST_OWNER + 4, f.artisan)
			"absent": copy.encode_s32(FIRST_OWNER + 4, absent)
			"profession": copy.encode_s32(FIRST_OWNER + 4, f.unemployed)
			"count": copy.encode_s64(FIRST_OWNER + 8, 2)
		var malformed := chunks.duplicate()
		malformed[building_chunk] = copy
		var target := _configured_fixture(f)
		var result := _load_sections(target, malformed)
		_expect("building seat record refuses %s" % case, not result.get("ok", false)
			and result.get("reason") == "save_building_owner_seats_invalid")
	var legacy: Array[PackedByteArray] = []
	for chunk in chunks:
		var old := chunk.duplicate()
		old.encode_u16(4, 66)
		if old.decode_u16(6) == 5:
			var compact := old.slice(0, 16)
			var row := 16
			for i in old.decode_u32(8):
				var owners := row + 337
				var roles := owners + 4 + old.decode_u32(owners) * 12
				var end := roles + 4 + old.decode_u32(roles) * 72
				compact.append_array(old.slice(row, owners))
				compact.append_array(old.slice(roles, end))
				row = end
			compact.append_array(old.slice(row))
			compact.encode_u32(12, compact.size() - 16)
			old = compact
		legacy.append(old)
	var prior := _configured_fixture(f)
	var result := _load_sections(prior, legacy)
	_expect("PKEC66 still loads the two original building records", result.get("ok", false))
	var corrupt := legacy[building_chunk].duplicate()
	corrupt.encode_u16(16 + 217, 65535)
	legacy[building_chunk] = corrupt
	var bad := _load_sections(_configured_fixture(f), legacy)
	_expect("PKEC66 refuses 65535 financial losses at a threshold of one",
		not bad.get("ok", false) and bad.get("reason") == "save_building_loss_history_invalid")


func _load_sections(target: Object, chunks: Array[PackedByteArray]) -> Dictionary:
	var result: Dictionary = target.begin_economy_restore()
	for chunk in chunks:
		if not result.get("ok", false):
			return result
		result = target.feed_economy_restore_chunk(chunk)
	return target.end_economy_restore() if result.get("ok", false) else result

func _test_shared_lot() -> void:
	var f := _fixture_data(4, 3, 2, 2_000_000_000, "bast_fiber", 100_000_000)
	var base := _add_ethnicities(f.catalog)
	f.profile.economy_trace_mode = "SELECTIVE"
	f.people.signature_ids[0] = 2 * base + f.unemployed
	f.people.cell_indices.append(4)
	f.people.signature_ids.append(base + f.unemployed)
	f.people.population.append(1)
	f.people.funds.append(1_000_000_000)
	var source: Object = _boot_fixture(f).ext
	_expect("mixed lot opens with three vacancies", _was_suspended(source, 4, 3, 4))
	var ext := _loan_world(source, f)
	var review := _settle(ext, 5)
	var lots: Dictionary = ext.get_building_cell_snapshot(4)
	var pop: Dictionary = ext.get_population_cell_snapshot(4)
	var one := _row_for_signature(pop, base + f.artisan)
	var two := _row_for_signature(pop, 2 * base + f.artisan)
	_expect("the lot seats both cohorts and the two-seat owner settles its single invoice and loan",
		_balanced(review) and lots.filled_owner == PackedInt64Array([3])
		and _snapshot_i64(pop, "owner_employed_by_cohort", one) == 1 and _snapshot_i64(pop, "owner_employed_by_cohort", two) == 2
		and not _cashflow_has_source(pop, one, "production_inputs", false)
		and _cashflow_has_source(pop, two, "production_inputs", false)
		and _cashflow_has_source(pop, two, "other", false))
