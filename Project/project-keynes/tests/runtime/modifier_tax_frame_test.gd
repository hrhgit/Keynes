extends "res://tests/runtime/modifier_same_day_reapply_test.gd"

func _run() -> void:
	var result := await _run_world(false)
	_expect("the displayed batch reached D4", result.get("day") == 4)
	_expect("explicit synchronous queries finished", _check_synchronous_tax_owner())
	print("modifier tax frame: %d checks, %d failures" % [_checks, _failures])
	call_deferred("quit", int(_failures != 0))


func _sample_world(host: WorldRuntimeHost, clock: WorldClock, _stall: bool) -> Dictionary:
	var generator := host.get_generator()
	var country = generator.get_country_facade()
	var economy = generator.get_economy_facade()
	var ext: Object = economy.world_ext()
	var cell := int(generator.gameplay_start_report().cell)
	var handle := int(country.cell_summary(cell).country_handle)
	var fixture := host as TaxHost
	var signaled := {}
	host.map_fields_received.connect(func(day: int):
		signaled[day] = _tax_rows(country, handle, cell))
	clock.set_speed(SPEED)
	clock.pause(false)
	_publish_day(host, clock, 1)
	if not await _wait_golden_read_boundary(host, economy, 1):
		return {}
	_admit(ext, _apply_packet(fixture.definition_id, handle, FIRST_REQUEST, 2))
	_publish_day(host, clock, 2)
	if not await _wait_golden_read_boundary(host, economy, 2):
		return {}
	var frozen: Dictionary = ext.sample_effect_metric_probe(INCOME_TAX_MEAN_BP, cell, handle)
	_expect("the worker froze every profession at 1001 bp", frozen.get("ok") and frozen.value == 1001)
	_check_inherited(signaled.get(2, {}), int(frozen.value), "D2 map signal")
	var held := _tax_rows(country, handle, cell)
	_check_inherited(held, int(frozen.value), "D2 after frame release")
	clock.pause(true)
	_expect("paused display retains its rate", _tax_rows(country, handle, cell) == held)
	clock.pause(false)
	_admit(ext, _apply_packet(fixture.definition_id, handle, SECOND_REQUEST, 4))
	var ids: PackedStringArray = held.national.profession_ids
	var local_percent: Dictionary = country.set_cell_tax_override_basis_points(handle, cell, 0, ids[0], 118, 4, 3051)
	var local_amount: Dictionary = country.set_cell_tax_override_basis_points(handle, cell, 0, ids[1], 73, 4, 3052, 1)
	_expect("both cell overrides admitted", local_percent.get("ok") and local_amount.get("ok"))
	var hold := _run_hold(host, 4)
	_expect("worker completed D3 and D4 without a display frame", hold.committed_after == 4
		and hold.display_after == 2 and hold.process_frames == 0)
	_expect("all three reads still return the full D2 rows", _tax_rows(country, handle, cell) == held)
	if not await _wait_golden_read_boundary(host, economy, 4):
		return {}
	var records: Array = host._runtime_last_commit.get("days", [])
	_expect("one take delivers D3 and D4", records.size() == 2 and records[0].day == 3 and records[1].day == 4)
	var latest := _tax_rows(country, handle, cell)
	_expect("the D4 signal already contained the final rows", signaled.get(4) == latest)
	if latest.is_empty():
		return {}
	var national: Dictionary = latest.national.income
	_expect("D4 panel uses all national rates", latest.panel == latest.national)
	var local: Dictionary = latest.local.income
	_check_local(local, 0, 118, 2119, 0, "cell_item")
	_check_local(local, 1, 73, 73, 1, "cell_item")
	_check_local(local, 2, 0, 2001, 0, "country_default")
	_expect("cell changes leave the national base, mode, effective rates and amounts intact",
		national.rates_basis_points[0] == 0 and national.assessment_modes[0] == 0
		and national.absolute_amounts[0] == 0 and national.has_override[0] == 0
		and national.effective_rates_basis_points[0] == 2001 and national.effective_rates[0] == 20)
	return {"day": 4}


func _tax_rows(country, handle: int, cell: int) -> Dictionary:
	var national: Dictionary = country.tax_policy_snapshot(handle)
	var local: Dictionary = country.cell_tax_policy_snapshot(cell)
	var panel: Dictionary = country.ui_snapshot(handle, 2).get("tax_policy", {})
	if not national.get("ok", false) or not local.get("ok", false) or not panel.get("ok", false):
		return {}
	return {"national": national, "local": local, "panel": panel}


func _check_inherited(rows: Dictionary, bp: int, phase: String) -> void:
	_expect(phase + " has national, local and panel policies", not rows.is_empty())
	if rows.is_empty():
		return
	_expect(phase + " panel tax fields equal national fields", rows.panel == rows.national)
	for kind in ["income", "consumption", "business", "import", "export"]:
		var national: Dictionary = rows.national[kind]
		var local: Dictionary = rows.local[kind]
		var mismatches := PackedInt32Array()
		for item in national.rates_basis_points.size():
			var expected: int = bp if kind == "income" else national.rates_basis_points[item]
			if national.effective_rates_basis_points[item] != expected \
					or local.effective_rates_basis_points[item] != expected \
					or local.final_base_rates_basis_points[item] != national.rates_basis_points[item] \
					or local.assessment_modes[item] != national.assessment_modes[item] \
					or local.source_scopes[item] != "country_default":
				mismatches.append(item)
		_expect("%s %s rates, bases, modes and sources (mismatched items %s)" % [
			phase, kind, mismatches], mismatches.is_empty())


func _check_local(local: Dictionary, item: int, base: int, effective: int, mode: int, source: String) -> void:
	_expect("cell item %d source, mode, base, amount and effective rate" % item,
		local.final_base_rates_basis_points[item] == base and local.assessment_modes[item] == mode
		and local.absolute_amounts[item] == (base if mode == 1 else 0)
		and local.effective_rates_basis_points[item] == effective
		and local.effective_rates[item] == (0 if mode == 1 else floori(effective / 100.0))
		and local.source_scopes[item] == source and local.has_local_item[item] == int(source == "cell_item"))


func _check_synchronous_tax_owner() -> bool:
	var ext := DCWorldExt.new()
	ext.create_entities(2)
	var country := preload("res://scripts/country/country_facade.gd").new()
	if not country.configure(ext, 2, 7321).get("ok", false):
		return false
	if not country.bootstrap(PackedByteArray([0, 0])).get("ok", false):
		return false
	var handle := int(country.cell_summary(0).get("country_handle", 0))
	if not handle or not ext.capture_country_runtime_snapshot().get("ok", false):
		return false
	var off := ext.start_runtime_worker({"simulation_thread_mode": "OFF",
		"economy_production_writer": "compact_slice"})
	if not off.get("ok", false):
		return false
	# The old published snapshot remains reachable. Only the local owner receives
	# this change, so every OFF entry point must pick the local Country store.
	var initial := _tax_rows(country, handle, 0)
	if initial.is_empty():
		return false
	var original := int(initial.national.income.effective_rates_basis_points[0])
	var new_rate := 483 if original != 483 else 484
	if not country.set_tax_default_basis_points(handle, 0, new_rate, 1, 7501).get("ok", false):
		return false
	var result := ext.run_country_slice({"day_index": 1})
	if not result.get("ok", false) or not result.get("done", false):
		return false
	var rows := _tax_rows(country, handle, 0)
	if rows.is_empty():
		return false
	for source in ["national", "local", "panel"]:
		var rates: PackedInt32Array = rows[source].income.effective_rates_basis_points
		_expect("OFF %s reads the local tax change after publishing %d bp" % [source, original],
			not rates.is_empty() and rates[0] == new_rate)
	return true
