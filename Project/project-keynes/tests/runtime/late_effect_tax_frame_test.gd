extends "res://tests/runtime/background_daily_self_sufficiency_test.gd"

class TaxProbeHost extends WorldRuntimeHost:
	var configured := false

	func _start_runtime_executor() -> void:
		if configured:
			super._start_runtime_executor()
			return
		var catalog: Dictionary = _generator.get_modifier_facade().compiled_catalog().duplicate(true)
		var definition: int = catalog.definition_keys.find("technology.state_bureaucracy")
		var inserted := 0
		if definition >= 0:
			var pos := int(catalog.definition_term_offsets[definition+1])
			for stat in catalog.stat_keys.size():
				if String(catalog.stat_keys[stat]).begins_with("country.tax.income."):
					catalog.term_stat_ids.insert(pos, stat)
					catalog.term_operations.insert(pos, 0)
					catalog.term_values.insert(pos, 300.0)
					pos += 1
					inserted += 1
			for offset in range(definition + 1, catalog.definition_term_offsets.size()):
				catalog.definition_term_offsets[offset] += inserted
			var ext: Object = _generator.get_data_core_world_ext()
			var config: Dictionary = ext.configure_modifiers(catalog, get_current_map().cell_count())
			configured = config.get("ok", false) and inserted > 0
		super._start_runtime_executor()

func _create_host() -> WorldRuntimeHost:
	return TaxProbeHost.new()

func _background_config() -> NewGameConfig:
	var config := super._background_config()
	config.country.foreign_count = 0
	config.country.starting_tax_rate_bp = 0
	config.base.map_width = 40
	config.base.map_height = 28
	return config

func _run() -> void:
	var samples := await _run_world(false)
	print("late effect tax frame: %d checks, %d failures" % [_checks, _failures])
	call_deferred("quit", 0 if _failures == 0 and samples.get("day") == 3 else 1)

func _sample_world(host: WorldRuntimeHost, clock: WorldClock, _stall: bool) -> Dictionary:
	var generator := host.get_generator()
	var economy = generator.get_economy_facade()
	var country = generator.get_country_facade()
	var ext: Object = economy.world_ext()
	var cell := int(generator.gameplay_start_report().cell)
	var handle := int(country.cell_summary(cell).country_handle)
	var stat: int = generator.get_modifier_facade().compiled_catalog().stat_keys.find("country.tax.income.scholar.rate_bp")
	_expect("test content adds income tax to the technology", (host as TaxProbeHost).configured and stat >= 0)
	clock.pause(false)
	for day in range(1, 4):
		if day == 2:
			var submit: Dictionary = ext.submit_effect_instances({
				"instance_ids": PackedInt64Array([77097]),
				"program_keys": PackedStringArray(["technology.tech.state_bureaucracy"]),
				"generations": PackedInt32Array([1]),
				"source_types": PackedInt32Array([0x54454348]),
				"source_ids": PackedInt64Array([77097]),
				"source_handles": PackedInt64Array([handle]),
				"target_handles": PackedInt64Array([handle]),
				"target_generations": PackedInt32Array([handle >> 32]),
				"levels": PackedInt32Array([0]),
				"next_due_days": PackedInt64Array([3]),
				"active": PackedByteArray([1])})
			_expect("Effect accepted the instance", submit.get("ok", false))
			var grant: Dictionary = country.grant_technology(handle, &"tech.animal_husbandry", day, 515, true)
			_expect("Country accepted the technology", grant.get("ok", false))
		_publish_day(host, clock, day)
		if not await _wait_golden_read_boundary(host, economy, day):
			return {}
		var frozen: Dictionary = ext.sample_effect_metric_probe(55, cell, handle)
		var national: Dictionary = country.tax_policy_snapshot(handle)
		var local: Dictionary = country.cell_tax_policy_snapshot(cell)
		var ui: Dictionary = country.ui_snapshot(handle, 3)
		var panel: Dictionary = ui.get("tax_policy", {})
		_check_panel_day_tail(country, handle, day, ui)
		var report: Dictionary = ext.get_runtime_thread_report()
		var owner: Dictionary = ext.get_runtime_modifier_snapshot(report.modifier_pod_snapshot_generation - 1)
		var bucket: int = owner.bucket_stat_ids.find(stat)
		_expect("day %d settled using the expected nonzero timeline" % day,
			frozen.get("ok") and frozen.value == (300 if day == 3 else 0))
		_expect("day %d owner snapshot contains the late application" % day,
			owner.committed_day == day and (bucket == -1 if day == 1 else bucket >= 0 and owner.bucket_sum_add[bucket] == 300))
		if not national.get("ok") or not local.get("ok") or not panel.get("ok"):
			_expect("all three tax paths available", false)
			return {}
		for row in [national, local, panel]:
			var rates: PackedInt32Array = row.income.effective_rates_basis_points
			var percent: PackedInt32Array = row.income.effective_rates
			_expect("all income rows use the frozen assessment on day %d" % day,
				rates.size() == national.profession_ids.size() and rates.size() > 0
				and rates.count(int(frozen.value)) == rates.size()
				and percent.count(int(frozen.value / 100.0)) == rates.size())
		if day == 2:
			clock.pause(true)
			var restarted: Dictionary = host.restart_runtime_executor()
			_expect("same-authority restart stays on D2", restarted.get("ok", false)
				and ext.runtime_committed_day() == day)
			var after_report: Dictionary = ext.get_runtime_thread_report()
			_expect("D2 restart keeps the same day-tail Modifier at +300",
				after_report.get("modifier_pod_snapshot_generation") == owner.generation
				and after_report.get("modifier_pod_state_hash") == owner.state_hash)
			var after := [country.tax_policy_snapshot(handle), country.cell_tax_policy_snapshot(cell),
				country.ui_snapshot(handle, 2).get("tax_policy", {})]
			for i in after.size():
				var rates: PackedInt32Array = after[i].get("income", {}).get("effective_rates_basis_points", PackedInt32Array())
				_expect("D2 restart preserves frozen 0 bp for %s" % ["national", "cell", "panel"][i],
					rates.size() == national.profession_ids.size() and rates.size() > 0 and rates.count(0) == rates.size())
			clock.pause(false)
	return {"day": 3}

func _check_panel_day_tail(country, handle: int, day: int, panel: Dictionary) -> void:
	# The owner and display are both on D at this read boundary. Use the
	# independent Country query before requesting the next simulated day.
	var tail: Dictionary = country.snapshot(handle)
	var treasury: Dictionary = country.treasury_snapshot(handle)
	var summary: Dictionary = panel.get("summary", {})
	_expect("D%d fiscal panel publishes the same Country day" % day, panel.get("published_day") == day)
	_expect("D%d fiscal panel summary and treasury match end-of-day cash (%s vs %s)" %
		[day, summary.get("cash"), treasury.get("cash")],
		summary.get("cash") == treasury.get("cash") and panel.get("treasury") == treasury)
	_expect("D%d fiscal panel uses the end-of-day Country generation (%s vs %s) and revision (%s vs %s)" %
		[day, panel.get("country_generation"), tail.get("generation"), panel.get("revision"), tail.get("state_version")],
		panel.get("country_generation") == tail.get("generation") and panel.get("revision") == tail.get("state_version")
		and summary.get("state_version") == tail.get("state_version"))
	var completed: PackedStringArray = panel.get("country_snapshot", {}).get("technology_ids", PackedStringArray())
	_expect("D%d fiscal panel includes all completed technologies (%s vs %s)" % [day, completed, tail.get("technology_ids")],
		completed == tail.get("technology_ids") and summary.get("technology_count") == tail.get("technology_count"))
	if day == 2:
		_expect("D2 Country completed the technology granted after the tax freeze", "tech.animal_husbandry" in tail.get("technology_ids", []))
