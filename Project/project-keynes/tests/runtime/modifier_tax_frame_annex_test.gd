extends "res://tests/runtime/modifier_tax_frame_test.gd"


func _run() -> void:
	var result := await _run_world(false)
	_expect("the Country owner published the D4 annexation", result.get("annexed") == 4)
	print("annexed country tax frame: %d checks, %d failures" % [_checks, _failures])
	call_deferred("quit", int(_failures != 0))


func _sample_world(host: WorldRuntimeHost, clock: WorldClock, _stall: bool) -> Dictionary:
	var generator := host.get_generator()
	var country = generator.get_country_facade()
	var economy = generator.get_economy_facade()
	var player_cell := int(generator.gameplay_start_report().cell)
	var player := int(country.cell_summary(player_cell).country_handle)
	var cell := _find_hidden_unowned_land(host.current_map())
	clock.pause(false)
	var created: Dictionary = country.create_country(&"country.tax_fixture", "Tax fixture", cell, 1, 7511)
	_expect("a second country is admitted on D1", created.get("ok", false))
	for day in [1, 2]:
		_publish_day(host, clock, day)
		if not await _wait_golden_read_boundary(host, economy, day):
			return {}
	var victim := int(country.cell_summary(cell).get("country_handle", 0))
	var had := _tax_rows(country, victim, cell)
	var before: Dictionary = country.ui_snapshot(victim, 3)
	_expect("D2 fiscal and research sections exist for the new country",
		victim != 0 and victim != player and not had.is_empty() and before.get("research", {}).get("ok", false))
	var renamed: Dictionary = country.rename_country(victim, "Renamed on D3", 3, 7512, true)
	_expect("D3 rename is admitted", renamed.get("ok", false))
	var hold := _run_hold(host, 3)
	_expect("the whole D3 commits while the display stays on D2", hold.committed_after == 3
		and hold.display_after == 2 and hold.process_frames == 0)
	_expect("the standalone non-tax section sees the new country name",
		country.ui_snapshot(victim, 1).get("summary", {}).get("country_name") == "Renamed on D3")
	var held_panel: Dictionary = country.ui_snapshot(victim, 3)
	_expect("the fiscal section retains its D2 country name, generation and tax rows",
		held_panel.get("summary") == before.get("summary")
		and held_panel.get("country_generation") == before.get("country_generation")
		and held_panel.get("tax_policy") == had.get("national"))
	if not await _wait_golden_read_boundary(host, economy, 3):
		return {}
	before = country.ui_snapshot(victim, 3)
	had = _tax_rows(country, victim, cell)
	_expect("the received D3 panel now shows the renamed country", before.get("summary", {}).get("country_name") == "Renamed on D3")
	var annexed: Dictionary = country.annex_country(victim, player, 4, 7513)
	_expect("D4 annexation is admitted", annexed.get("ok", false))
	# Country publishes the removed handle as soon as its stage finishes. Hold
	# the display at D3 even while the rest of the D4 simulation is working.
	host.set_process(false)
	_publish_day(host, clock, 4)
	for _slice in MAX_SLICES_PER_DAY:
		if country.cell_summary(cell).get("country_handle", 0) == player:
			break
		await process_frame
	_expect("the Country owner published D4 while the tax display is still on D3",
		country.cell_summary(cell).get("country_handle", 0) == player and host._runtime_commit_day == 3
		and not country.ui_snapshot(victim, 1).get("ok", false))
	_expect("all three D3 tax queries survive the owner's later annexation",
		not had.is_empty() and _tax_rows(country, victim, cell) == had)
	var combined: Dictionary = country.ui_snapshot(victim, 3)
	_expect("the combined panel uses its received country when the newer identity is gone",
		combined.get("summary") == before.get("summary") and combined.get("tax_policy") == had.get("national")
		and combined.get("research") == before.get("research"))
	return {"annexed": 4}
