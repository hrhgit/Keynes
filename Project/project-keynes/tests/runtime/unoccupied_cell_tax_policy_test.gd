extends "res://tests/runtime/modifier_tax_frame_test.gd"


func _run() -> void:
	var result := await _run_world(false)
	_expect("D4 published both capital and empty-cell policies", result.get("day") == 4)
	print("unoccupied cell tax policy: %d checks, %d failures" % [_checks, _failures])
	call_deferred("quit", int(_failures != 0))


func _sample_world(host: WorldRuntimeHost, clock: WorldClock, _stall: bool) -> Dictionary:
	var generator := host.get_generator()
	var economy = generator.get_economy_facade()
	var country = generator.get_country_facade()
	var capital := int(generator.gameplay_start_report().cell)
	var player := int(country.cell_summary(capital).country_handle)
	var cell := _find_hidden_unowned_land(host.current_map())
	_expect("the map has empty land outside the capital", cell >= 0 and cell != capital)
	clock.pause(false)
	var claim: Dictionary = country.transfer_territory(cell, player, 1, 75141, true)
	_expect("the claim was admitted on D1", claim.get("ok") and claim.get("effective_day") == 1)
	for day in range(1, 5):
		if day == 2:
			_admit(economy.world_ext(), _apply_packet((host as TaxHost).definition_id, player, FIRST_REQUEST, day))
		if day == 3:
			var ids: PackedStringArray = country.tax_policy_snapshot(player).profession_ids
			var percent: Dictionary = country.set_cell_tax_default_basis_points(player, cell, 0, 118, day, 75142)
			var amount: Dictionary = country.set_cell_tax_override_basis_points(player, cell, 0, ids[0], 73, day, 75143, 1)
			var zero: Dictionary = country.set_cell_tax_override_basis_points(player, cell, 0, ids[1], 0, day, 75144, 1)
			_expect("only the empty cell received the local default and two absolute overrides",
				percent.get("ok") and amount.get("ok") and zero.get("ok"))
		if day == 4:
			# These are different legal defaults. The amount bits overlap the old
			# settlement cache's mode bit, so the vacant cell must never replace the
			# row used for assessment in the active capital.
			var empty_subsidy: Dictionary = country.set_cell_tax_default_basis_points(player, cell, 0, -118, day, 75145, 1)
			var active_discount: Dictionary = country.set_cell_tax_default_basis_points(player, capital, 0, -118, day, 75146)
			var large_amount: Dictionary = country.set_cell_tax_default_basis_points(player, cell, 1, 1 << 24, day, 75147, 1)
			var zero_charge: Dictionary = country.set_cell_tax_default_basis_points(player, capital, 1, 0, day, 75148, 1)
			_expect("all four distinct policy defaults were admitted", empty_subsidy.get("ok")
				and active_discount.get("ok") and large_amount.get("ok") and zero_charge.get("ok"))
		_publish_day(host, clock, day)
		if not await _wait_golden_read_boundary(host, economy, day):
			return {}
		# Subscribe to both economy readouts on D1, before the assertions use their published values.
		var pop: Dictionary = economy.population_cell_summary(cell)
		var buildings: Dictionary = economy.building_cell_snapshot(cell)
		if day < 2:
			continue
		var counts: PackedInt64Array = buildings.get("building_counts_by_type", PackedInt64Array())
		_expect("D%d land is owned, without residents, buildings or construction" % day,
			country.cell_summary(cell).get("country_handle") == player and pop.get("population") == 0
			and buildings.get("ok") and not counts.is_empty() and counts.count(0) == counts.size()
			and buildings.has("construction_counts") and buildings.construction_counts.is_empty())
		var local: Dictionary = country.cell_tax_policy_snapshot(cell).income
		var active: Dictionary = country.cell_tax_policy_snapshot(capital).income
		if day < 4:
			_expect("D%d the active capital retains 1001 bp" % day, active.effective_rates_basis_points[0] == 1001)
		print("D%d cell %d first three applicable rate/mode pairs: %s / %s" % [day, cell,
			local.effective_rates_basis_points.slice(0, 3), local.assessment_modes.slice(0, 3)])
		if day == 2:
			_check_local(local, 0, 0, 1001, 0, "country_default")
		elif day == 3:
			_check_local(local, 0, 73, 73, 1, "cell_item")
			_check_local(local, 1, 0, 0, 1, "cell_item")
			_check_local(local, 2, 118, 1119, 0, "cell_default")
		else:
			_check_local(active, 2, -118, 883, 0, "cell_default")
			_check_local(local, 2, -118, -118, 1, "cell_default")
			_check_local(country.cell_tax_policy_snapshot(capital).consumption, 0, 0, 0, 1, "cell_default")
			_check_local(country.cell_tax_policy_snapshot(cell).consumption, 0, 1 << 24, 1 << 24, 1, "cell_default")
	return {"day": 4}
