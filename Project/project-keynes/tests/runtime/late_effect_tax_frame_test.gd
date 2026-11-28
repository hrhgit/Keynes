extends "res://tests/runtime/background_daily_self_sufficiency_test.gd"

const GRANT_RECIPE := "technology.tech.animal_husbandry"
const FUTURE_RECIPE := "technology.tech.earth_building"
const TAX_RECIPE := "technology.tech.state_bureaucracy"
const FUTURE_INSTANCE := 77098

class TaxProbeHost extends WorldRuntimeHost:
	var configured := false
	var grant_event_count := 0
	var tax_cadence := 0

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
		# A test peer holds one receipt for a grant that was sealed with D2.
		var effects := LoadingCatalogCache.effect_native_columns().duplicate(true)
		if effects.is_empty():
			effects = EffectDomainCatalog.build().compile_native_catalog()
		var program: int = effects.effect_keys.find(GRANT_RECIPE)
		var tax_program: int = effects.effect_keys.find(TAX_RECIPE)
		if program >= 0 and tax_program >= 0:
			tax_cadence = effects.cadence_days[tax_program]
			grant_event_count = _add_test_peer(effects, program)
			var effect_config: Dictionary = ext.configure_effects(effects)
			configured = config.get("ok", false) and inserted > 0 and effect_config.get("ok", false)
			if not configured:
				print("EFFECT_TAX_FIXTURE ", config, " ", effect_config)
		super._start_runtime_executor()

	func _add_test_peer(effects: Dictionary, program: int) -> int:
		var begin: int = effects.command_offsets[program]
		var end: int = effects.command_offsets[program + 1]
		for key in effects:
			if String(key).begins_with("command_") and key != "command_offsets":
				effects[key].insert(end, effects[key][begin])
		effects.command_actions[end] = 2 # COUNTRY_COMMAND
		effects.command_domains[end] = 1
		effects.command_opcodes[end] = 1
		effects.command_keys[end] = "test.country.receipt"
		effects.command_definition_keys[end] = "test.country.receipt"
		effects.command_value_modes[end] = 0 # CONSTANT
		for offset in range(program + 1, effects.command_offsets.size()):
			effects.command_offsets[offset] += 1
		var instruction: int = effects.instruction_offsets[program + 1] - 1
		effects.instruction_ops.insert(instruction, 11) # EMIT_COMMAND before END
		effects.instruction_arg0.insert(instruction, end - begin)
		effects.instruction_arg1.insert(instruction, 0)
		effects.instruction_values.insert(instruction, 0)
		for offset in range(program + 1, effects.instruction_offsets.size()):
			effects.instruction_offsets[offset] += 1
		return end - begin + 1

func _create_host() -> WorldRuntimeHost:
	return TaxProbeHost.new()

func _background_config() -> NewGameConfig:
	var config := super._background_config()
	config.country.foreign_count = 0
	config.base.map_width = 40
	config.base.map_height = 28
	return config

func _run() -> void:
	var early := await _run_world(false)
	var late := await _run_world(true)
	_expect("D2 settlement uses sealed input rather than late external updates",
		early.get("d2_tax") == 300 and late.get("d2_tax") == 0
		and early.get("d2_paid", -1) > 0 and late.get("d2_paid", -1) == 0)
	print("late effect tax frame: %d checks, %d failures" % [_checks, _failures])
	call_deferred("quit", 0 if _failures == 0 and early.get("day") == 4 and late.get("day") == 4 else 1)

func _sample_world(host: WorldRuntimeHost, clock: WorldClock, late_submission: bool) -> Dictionary:
	var generator := host.get_generator()
	var economy = generator.get_economy_facade()
	var country = generator.get_country_facade()
	var ext: Object = economy.world_ext()
	var cell := int(generator.gameplay_start_report().cell)
	var handle := int(country.cell_summary(cell).country_handle)
	var stat: int = generator.get_modifier_facade().compiled_catalog().stat_keys.find("country.tax.income.scholar.rate_bp")
	_expect("test content adds income tax to the technology", (host as TaxProbeHost).configured and stat >= 0)
	var d2_tax := -1
	var d2_paid := -1
	var published_events := {}
	economy.population_cell_snapshot(cell)
	clock.pause(false)
	for day in range(1, 5):
		if day == 2:
			_submit_instance(ext, FUTURE_INSTANCE, FUTURE_RECIPE, handle, 4, 1)
			var grant: Dictionary = country.grant_technology(handle, &"tech.animal_husbandry", day, 515, true)
			_expect("Country accepted the technology", grant.get("ok", false))
			if not late_submission:
				_submit_instance(ext, 77097, TAX_RECIPE, handle, 2, 0)
		_publish_day(host, clock, day)
		if day == 2:
			var parked := false
			for _slice in range(MAX_SLICES_PER_DAY):
				var pending: Dictionary = ext.get_runtime_thread_report()
				if pending.get("economy_pod_committed_day") == 2 and ext.runtime_committed_day() == 1:
					parked = true
					break
				await process_frame
			_expect("Economy settled D2 while Country waits for the grant", parked)
			if not parked:
				print("LATE_EFFECT_WAIT ", ext.get_runtime_thread_report())
				return {}
			var catalog: Dictionary = country.native_catalog()
			var tech: int = catalog.technology_ids.find("tech.animal_husbandry")
			var grant_instance := ((handle & 0x00007fffffffffff) << 16) | (tech + 1)
			# Enqueue the tax change while the sealed grant is still waiting.
			if late_submission:
				_submit_instance(ext, 77097, TAX_RECIPE, handle, 2, 0)
			var peer: Dictionary = ext.poll_effect_worker_intent()
			while peer.get("available", false):
				if peer.get("source_id") == grant_instance and peer.get("target_domain") == 3:
					break
				peer = ext.poll_effect_worker_intent()
			_expect("the sealed Country grant has emitted its waiting peer command", peer.get("available", false))
			if not peer.get("available", false):
				return {}
			peer["domain"] = peer.target_domain
			var receipt: Dictionary = ext.submit_effect_worker_ack(peer)
			_expect("the peer receipt releases the original Country grant", receipt.get("ok", false))
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
		var tax_day := 3 if late_submission else 2
		var tax_basis_points := 300 if day >= tax_day else 0
		if day == 2:
			d2_tax = int(frozen.value)
			var payment := await _published_economy(func(): return economy.population_cell_snapshot(cell), day)
			_expect("the opening capital reports actual tax payments for D2", not payment.is_empty())
			if not payment.is_empty():
				d2_paid = 0
				for amount in payment.epoch_tax_paid_by_cohort:
					d2_paid += amount
		print("EFFECT_TAX_FENCE late=%s day=%d frozen=%s modifier=%s d2_paid=%d" % [
			late_submission, day, frozen.value, owner.bucket_sum_add[bucket] if bucket >= 0 else 0, d2_paid])
		_expect("day %d settled using the expected nonzero timeline" % day,
			frozen.get("ok") and frozen.value == tax_basis_points)
		_expect("day %d owner snapshot contains the late application" % day,
			owner.committed_day == day and (bucket == -1 if day < tax_day else bucket >= 0 and owner.bucket_sum_add[bucket] == 300))
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
		if day >= 2:
			var future: Dictionary = ext.explain_effect(FUTURE_INSTANCE)
			var late: Dictionary = ext.explain_effect(77097)
			var cadence := (host as TaxProbeHost).tax_cadence
			if day < 4:
				_expect("D%d keeps the D4 instance on its original schedule" % day,
					future.get("fire_sequence") == 0 and future.get("next_due_day") == 4)
			else:
				_expect("the scheduled instance fires and is acknowledged on D4",
					future.get("fire_sequence") == 1 and future.get("last_acked_fire_sequence") == 1)
			if day < tax_day:
				_expect("an external request admitted after D2 seals has not fired",
					late.is_empty() or late.get("fire_sequence", 0) == 0)
			else:
				_expect("tax instance fires and is acknowledged on its admitted day",
					late.get("fire_sequence") == 1 and late.get("last_acked_fire_sequence") == 1
					and late.get("next_due_day") == tax_day + cadence)
			var journal: Dictionary = ext.poll_gameplay_events({"consumer_id": &"late_effect_test",
				"after_event_id": 0, "max_events": 0, "type": 900})
			var commands := _event_commands(journal, handle, day)
			for prior_day: int in published_events:
				_expect("D%d preserves every event and transaction published for D%d" % [day, prior_day],
					_event_commands(journal, handle, prior_day) == published_events[prior_day])
			published_events[day] = commands
			var expected := (host as TaxProbeHost).grant_event_count + 2
			var technology_transactions := 0
			var total := 0
			var tax_pair := false
			for rows: Array in commands.values():
				if not rows.has([10, 13]): # technology.adopted
					continue
				technology_transactions += 1
				total += rows.size()
				if rows.size() == 2 and rows.has([7, 1]) and rows.has([10, 13]):
					tax_pair = true
			if day == 2:
				_expect("D2 publishes the sealed grant and only the tax transaction admitted for D2",
					technology_transactions == (1 if late_submission else 2)
					and total == (expected - 2 if late_submission else expected)
					and tax_pair != late_submission)
			elif day == 3:
				_expect("D3 publishes the late request once",
					technology_transactions == (1 if late_submission else 0)
					and total == (2 if late_submission else 0) and tax_pair == late_submission)
			elif day == 4:
				_expect("D4 publishes the scheduled technology event once",
					technology_transactions == 1 and total == 1 and not tax_pair)
			print("LATE_EFFECT D%d future_fire=%s future_due=%s tax_due=%s events=%s" % [
				day, future.get("fire_sequence"), future.get("next_due_day"), late.get("next_due_day"), commands])
		if day == 2:
			clock.pause(true)
			var restarted: Dictionary = host.restart_runtime_executor()
			_expect("same-authority restart stays on D2", restarted.get("ok", false)
				and ext.runtime_committed_day() == day)
			var after_report: Dictionary = ext.get_runtime_thread_report()
			_expect("D2 restart keeps the same day-tail Modifier",
				after_report.get("modifier_pod_snapshot_generation") == owner.generation
				and after_report.get("modifier_pod_state_hash") == owner.state_hash)
			var after := [country.tax_policy_snapshot(handle), country.cell_tax_policy_snapshot(cell),
				country.ui_snapshot(handle, 2).get("tax_policy", {})]
			for i in after.size():
				var rates: PackedInt32Array = after[i].get("income", {}).get("effective_rates_basis_points", PackedInt32Array())
				_expect("D2 restart preserves the frozen rate for %s" % ["national", "cell", "panel"][i],
					rates.size() == national.profession_ids.size() and rates.size() > 0 and rates.count(tax_basis_points) == rates.size())
			clock.pause(false)
	return {"day": 4, "d2_tax": d2_tax, "d2_paid": d2_paid}

func _event_commands(journal: Dictionary, handle: int, day: int) -> Dictionary:
	var commands := {}
	for i in journal.get("tick", PackedInt64Array()).size():
		if journal.tick[i] == day and journal.entity_handle[i] == handle:
			var tx: int = journal.value_i64[i]
			if not commands.has(tx):
				commands[tx] = []
			commands[tx].append([journal.payload_i0[i], journal.payload_i1[i]])
	return commands

func _submit_instance(ext: Object, id: int, recipe: String, handle: int, due: int, level: int) -> void:
	var result: Dictionary = ext.submit_effect_instances({
		"instance_ids": PackedInt64Array([id]), "program_keys": PackedStringArray([recipe]),
		"generations": PackedInt32Array([1]), "source_types": PackedInt32Array([0x54454348]),
		"source_ids": PackedInt64Array([id]), "source_handles": PackedInt64Array([handle]),
		"target_handles": PackedInt64Array([handle]), "target_generations": PackedInt32Array([handle >> 32]),
		"levels": PackedInt32Array([level]), "next_due_days": PackedInt64Array([due]),
		"active": PackedByteArray([1])})
	_expect("Effect accepted instance %d due D%d" % [id, due], result.get("ok", false))

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
		_expect("D2 Country completes the sealed grant after the peer receipt", "tech.animal_husbandry" in tail.get("technology_ids", []))
