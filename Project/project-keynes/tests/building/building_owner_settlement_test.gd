extends "res://tests/building/building_lifecycle_test.gd"


func _run() -> void:
	_test_accounts(false)
	_test_accounts(true)
	_test_household_reserve()
	_test_same_profession_signature()
	_test_opening_stream()
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

func _set_workshop_output_value(f: Dictionary) -> void:
	var tool: int = f.catalog.good_ids.find("chipped_stone_tools")
	f.buildings.stock[f.cell * f.catalog.good_ids.size() + tool] = 0
	f.catalog.good_default_price[tool] = 10_000_000
	f.catalog.good_reference_max_price[tool] = 10_000_000
	var workshop: int = f.catalog.building_type_ids.find("knapping_workshop")
	f.catalog.building_output_quantities[f.catalog.building_output_offsets[workshop]] = 100_000


func _test_household_reserve() -> void:
	# The registrant runs a profitable workshop. The loom's only worker buys
	# fibre and has household orders large enough to spend the whole balance.
	var reference := PackedInt64Array()
	for registered in [true, false]:
		var f := _fixture_data(4, 1, 1, 750_000, "bast_fiber", 100_000_000)
		var plan: int = f.catalog.signature_plan_ids[f.artisan]
		for need in range(f.catalog.plan_need_offsets[plan], f.catalog.plan_need_offsets[plan + 1]):
			f.catalog.need_base_qty_per_person[need] *= 20
		var base := _add_ethnicities(f.catalog)
		var actual: int = 2 * base + f.artisan
		f.people.signature_ids[0] = 2 * base + f.unemployed
		if registered:
			f.buildings.building_owner_signature_ids[0] = actual
		_add_workshop(f, f.artisan)
		_set_workshop_output_value(f)
		var ext: Object = _boot_fixture(f).ext
		_expect("the workshop is occupied before the loom reopens", _balanced(_settle(ext, 4))
			and ext.get_building_cell_snapshot(4).filled_owner == PackedInt64Array([0, 1]))
		var day := _settle(ext, 5)
		var pop: Dictionary = ext.get_population_cell_snapshot(4)
		var cash := _snapshot_i64(pop, "funds_by_cohort", _row_for_signature(pop, actual))
		var reserve := int(day.get("owner_working_capital_reserved", 0))
		_expect("the loom payer retains its fibre budget after household clearing",
			_balanced(day) and reserve > 0 and cash >= reserve)
		var next := _settle(ext, 6)
		var lots: Dictionary = ext.get_building_cell_snapshot(4)
		var result := PackedInt64Array([cash, lots.last_input_cost[0], lots.last_output[0]])
		print("loom reserve: registered=%s protected=%s cash=%s next_input=%s next_output=%s" % [
			registered, reserve, cash, result[1], result[2]])
		_expect("both lots keep operating", _balanced(next)
			and lots.filled_owner == PackedInt64Array([1, 1]) and result[1] > 0 and result[2] > 0)
		if registered:
			reference = result
		else:
			_expect("a visiting payer keeps the same cash and buys the same input as a registered payer",
				result == reference)


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
	_set_workshop_output_value(f)
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
	print("D5 loom working capital: registrant present=%s reserved=%s input paid=%s" % [
		registrant_present, review.get("owner_working_capital_reserved"), lots.last_input_cost[0]])
	_expect("the active loom protects its next fibre purchase even when only its visiting owner is local",
		int(review.get("owner_working_capital_reserved", 0)) > 0)
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
	var malformed := legacy.duplicate()
	malformed[building_chunk] = corrupt
	var bad := _load_sections(_configured_fixture(f), malformed)
	_expect("PKEC66 refuses 65535 financial losses at a threshold of one",
		not bad.get("ok", false) and bad.get("reason") == "save_building_loss_history_invalid")
	_check_failed_stream(f, malformed, legacy, "save_building_loss_history_invalid")
	var bad_header := building.duplicate()
	bad_header.encode_u32(12, 0)
	malformed = chunks.duplicate()
	malformed[building_chunk] = bad_header
	_check_failed_stream(f, malformed, chunks, "save_chunk_header_invalid")


func _check_failed_stream(f: Dictionary, bad: Array[PackedByteArray],
		valid: Array[PackedByteArray], reason: String) -> void:
	var live: Object = _boot_fixture(f).ext
	var control: Object = _boot_fixture(f).ext
	_expect("both original worlds settle D4 before streaming",
		_balanced(_settle(live, 4)) and _balanced(_settle(control, 4)))
	var before: int = live.get_economy_state_hash()
	var result: Dictionary = live.begin_economy_restore()
	var after_begin: int = live.get_economy_state_hash()
	var busy: Dictionary = live.run_economy_slice({"day_index": 5})
	_expect("a pending stream holds the committed day", busy.get("reason") == "save_restore_active"
		and live.get_economy_state_hash() == before)
	var capture: Dictionary = live.capture_economy_day_inputs(5)
	var stages: Dictionary = live.run_economy_stage_ops_day(5)
	_expect("direct input capture and stage execution also preserve the pending day",
		capture.get("reason") == "save_restore_active" and not capture.get("captured", true)
		and stages.get("reason") == "save_restore_active" and live.get_economy_state_hash() == before)
	var last_good := after_begin
	for chunk in bad:
		result = live.feed_economy_restore_chunk(chunk)
		if not result.get("ok", false):
			break
		last_good = live.get_economy_state_hash()
	var ended: Dictionary = live.end_economy_restore()
	var after: int = live.get_economy_state_hash()
	print("failed stream %s: before=%s begin=%s prefix=%s end=%s end_reason=%s" % [
		result.get("reason"), before, after_begin, last_good, after, ended.get("reason")])
	_expect("bad feed identifies %s and leaves the published world intact throughout" % reason,
		result.get("reason") == reason and not ended.get("ok", true) and ended.get("reason") == reason
		and before == after_begin and before == last_good and before == after)
	var next: Dictionary = live.run_economy_slice({"day_index": 5})
	if next.get("ok", true) and not next.get("fatal", false):
		if not next.get("done", false):
			next = _settle(live, 5)
	_expect("after %s the original world continues exactly like the control" % reason,
		_balanced(_settle(control, 5)) and _balanced(next)
		and live.get_economy_state_hash() == control.get_economy_state_hash())
	var loaded := _load_sections(live, valid)
	_expect("the next valid stream can install after %s (%s)" % [reason, loaded.get("reason", "")],
		loaded.get("ok", false))


func _test_opening_stream() -> void:
	var f := _fixture_data(4, 1, 1, 750_000, "bast_fiber", 100_000_000)
	var source: Object = _boot_fixture(f).ext
	var live := _configured_fixture(f)
	var start: Dictionary = source.begin_economy_save(65536)
	var chunks: Array[PackedByteArray] = []
	while true:
		var chunk: PackedByteArray = source.read_economy_save_chunk(65536)
		if chunk.is_empty():
			break
		chunks.append(chunk)
	source.end_economy_save()
	_expect("ordinary PKEC can also save the opening before the first day",
		start.get("ok", false) and start.get("committed_day") == -1 and chunks.size() > 1)
	if chunks.size() <= 1:
		return
	var result := _load_sections(live, chunks)
	_expect("the opening stream installs with its first settlement still to run", result.get("ok", false))
	if not result.get("ok", false):
		return
	_expect("the restored opening can settle", _balanced(_settle(live, 4)))
	var before: int = live.get_economy_state_hash()
	var incomplete := chunks.duplicate()
	incomplete.pop_back()
	result = _load_sections(live, incomplete)
	_expect("end with a missing terminator preserves the live day and closes the stream",
		result.get("reason") == "restore_end_missing" and before == live.get_economy_state_hash())
	var begin: Dictionary = live.begin_economy_restore()
	var worker: Dictionary = live.start_runtime_worker({
		"simulation_thread_mode": "ACTIVE", "graph_coverage_complete": true,
		"native_daily_inline": true, "paused": true,
	})
	_expect("the executor cannot start in the middle of a restore",
		not worker.get("ok", true) and worker.get("code") == "economy_restore_active")
	if worker.get("ok", false):
		live.request_runtime_stop()
	var fed: Dictionary = live.feed_economy_restore_chunk(PackedByteArray())
	_expect("an empty feed closes immediately, even when its caller omits end",
		begin.get("ok", false) and fed.get("reason") == "restore_chunk_empty"
		and before == live.get_economy_state_hash() and _load_sections(live, chunks).get("ok", false))
	var replay := _settle(live, 4)
	_expect("replacing a committed day with a valid opening reproduces that day",
		_balanced(replay) and before == live.get_economy_state_hash())
	begin = live.begin_economy_restore()
	fed = live.feed_economy_restore_chunk(chunks[0])
	var country: int = live.get_country_cell_summary(4).get("country_handle", 0)
	var changed := _set_unemployment_subsidy(live, country, f.catalog.signature_profession_ids[f.unemployed])
	var current: int = live.get_economy_state_hash()
	for index in range(1, chunks.size()):
		if fed.get("ok", false):
			fed = live.feed_economy_restore_chunk(chunks[index])
	var ended: Dictionary = live.end_economy_restore()
	_expect("a country change after the header refuses installation before touching the live economy",
		begin.get("ok", false) and changed and not ended.get("ok", true)
		and ended.get("reason") == "economy_country_restore_order_or_hash_mismatch"
		and live.get_economy_state_hash() == current)


func _test_same_profession_signature() -> void:
	var f := _fixture_data(0, 1, 1, 2_000_000, "", 0)
	var catalog: Dictionary = f.catalog
	var first: int = catalog.signature_keys.find("forager|default")
	var actual: int = catalog.signature_keys.size()
	for key in ["signature_ethnicity_ids", "signature_profession_ids", "signature_plan_ids",
			"signature_birth_rate_q32", "signature_death_rate_q32", "signature_satisfaction_birth_weight_q16"]:
		catalog[key].append(catalog[key][first])
	var weights: PackedInt32Array = catalog.signature_satisfaction_dimension_weights_q16
	var dims := weights.size() / actual
	catalog.signature_satisfaction_dimension_weights_q16.append_array(weights.slice(first * dims, (first + 1) * dims))
	catalog.signature_keys.append("forager_other_plan|default")
	var flint: int = catalog.building_type_ids.find("flint_quarry")
	var timber: int = catalog.building_type_ids.find("timber_collector")
	var logs: int = catalog.good_ids.find("logs")
	catalog.good_default_price[logs] = 1_000_000_000
	catalog.good_reference_max_price[logs] = 1_000_000_000
	f.people.signature_ids[0] = actual
	f.profile.resource_safe_harvest_q16 = 0
	f.buildings.building_cells = PackedInt32Array([0, 0])
	f.buildings.building_type_ids = PackedInt32Array([flint, timber])
	f.buildings.building_owner_signature_ids = PackedInt32Array([actual, actual])
	f.buildings.building_counts = PackedInt64Array([1, 1])
	f.buildings.building_owner_fill = PackedInt64Array([1, 0])
	var ext: Object = _boot_fixture(f).ext
	var day := _settle(ext, 0)
	var lots: Dictionary = ext.get_building_cell_snapshot(0)
	var people: Dictionary = ext.get_population_cell_snapshot(0)
	var target: int = lots.group_type_ids.find(timber)
	var owner := _row_for_signature(people, actual)
	_expect("only the second local signature moves from the quarry to the timber job",
		_balanced(day) and int(day.get("building_owner_job_reallocations")) == 1
		and int(day.get("building_owner_job_profession_changes")) == 0
		and target >= 0 and lots.filled_owner[target] == 1 and lots.last_output[target] > 0
		and owner >= 0 and _snapshot_i64(people, "owner_employed_by_cohort", owner) == 1
		and _row_for_signature(people, first) < 0)
	var save: Dictionary = ext.capture_economy_ecp2(0)
	var cold := _configured_fixture(f)
	# The world archive restores these map slots separately from the economic section.
	for slot_name in catalog.building_resource_reserve_slots + catalog.building_resource_extra_slots:
		var source_slot := int(ext.component_id(StringName(slot_name)))
		var target_slot := int(cold.component_id(StringName(slot_name)))
		cold.write_f32_range(target_slot, 0, ext.snapshot_f32(source_slot))
	var load_result: Dictionary = cold.restore_economy_ecp2(save.bytes)
	print("same-profession transfer: local=%s first=%s owners=%s moves=%s load=%s" % [
		actual, first, lots.filled_owner, day.get("building_owner_job_reallocations"), load_result.get("reason", "ok")])
	_expect("the moved owner's real signature survives PKEC67 restore", load_result.get("ok", false)
		and ext.get_economy_state_hash() == cold.get_economy_state_hash())
	if load_result.get("ok", false):
		# In synchronous mode harvesting writes to the map. Sample that map once
		# so the checkpoint also contains the actual stock available for D1.
		var sampled: Dictionary = ext.capture_economy_day_inputs(1)
		var checkpoint: Dictionary = ext.capture_economy_ecp2(0)
		_expect("the checkpoint includes the next day's sampled timber stock",
			sampled.get("captured", false) and checkpoint.get("ok", false)
			and cold.restore_economy_ecp2(checkpoint.bytes).get("ok", false))
		for next_day in [1, 2]:
			_expect("D%d: both worlds continue with the same owner after the move" % next_day,
				_balanced(_settle(ext, next_day)) and _balanced(_settle(cold, next_day))
				and ext.get_economy_state_hash() == cold.get_economy_state_hash())


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
