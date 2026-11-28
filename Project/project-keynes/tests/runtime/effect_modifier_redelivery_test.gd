extends "res://tests/runtime/background_daily_self_sufficiency_test.gd"

const TECHNOLOGY := &"tech.animal_husbandry"
const DEFINITION := "technology.animal_husbandry"
const TECH := 0x54454348

class InlineHost extends WorldRuntimeHost:
	func _native_daily_inline_requested() -> bool:
		return true

func _create_host() -> WorldRuntimeHost:
	return InlineHost.new()

func _background_config() -> NewGameConfig:
	var config := super._background_config()
	config.country.foreign_count = 0
	config.base.map_width = 40
	config.base.map_height = 28
	return config

func _run() -> void:
	var result := await _run_world(false)
	_expect("D2 completed", result.get("day") == 2)
	_partial_modifier_redelivery()
	print("effect modifier redelivery: %d checks, %d failures" % [_checks, _failures])
	call_deferred("quit", 0 if _failures == 0 else 1)

func _partial_modifier_redelivery() -> void:
	const GRANT := 0x841 # Input capture, Modifier and day commit
	var ext := DCWorldExt.new()
	var modifier := ModifierFacade.new()
	var configured := modifier.configure(ext, 1)
	_expect("partial host configures Modifier", configured.get("modifier_pod_ready", false))
	var effects := preload("res://scripts/effect/effect_domain_catalog.gd").build()
	_expect("partial host configures embedded Effect", ext.configure_effects(
		effects.compile_native_catalog()).get("effect_pod_ready", false))
	var technology := preload("res://scripts/economy/technology_catalog.gd").compile_native_catalog()
	var slot: int = technology.technology_ids.find(String(TECHNOLOGY))
	var definition: int = modifier.compiled_catalog().definition_keys.find(DEFINITION)
	_expect("partial host uses the formal technology and Modifier definition", slot >= 0 and definition >= 0)
	if slot < 0 or definition < 0:
		return
	var started := ext.start_runtime_worker({"simulation_thread_mode": "ACTIVE",
		"graph_coverage_complete": true, "native_daily_inline": true,
		"authoritative_domain_mask": GRANT, "day": 0, "speed_days_per_second": 0, "paused": true})
	_expect("partial inline executor starts", started.get("ok", false))
	const COUNTRY := 4294967296
	const OLD_GENERATION := 2
	const NEW_GENERATION := 1
	var source := slot + 1
	var seed_row := ext.submit_runtime_command(_peer_packet(
		1, 1, COUNTRY, OLD_GENERATION, source, definition, 0))
	_expect("partial D1 admits the conflicting row", seed_row.get("admitted", false))
	_expect("partial D1 captures inputs", _capture_partial(ext, 1))
	var first_day := ext.run_native_daily_inline_day()
	_expect("partial D1 commits without Effect or Events authorization",
		first_day.get("ok", false) and first_day.get("completed_domain_mask") == GRANT)
	if ext.runtime_committed_day() != 1:
		ext.request_runtime_stop()
		return
	var first := _published(ext)
	var index: int = first.entry_source_ids.find(source)
	_expect("partial D1 publishes the conflicting Modifier", index >= 0)
	if index < 0:
		ext.request_runtime_stop()
		return
	var instance := (COUNTRY << 16) | source
	var queued := ext.queue_effect_pod_instance({
		"instance_id": instance, "generation": 1,
		"program_key": technology.technology_effect_recipe_ids[slot],
		"source_handle": COUNTRY, "target_handle": COUNTRY, "target_generation": NEW_GENERATION,
		"source_type": TECH, "source_id": instance, "level": 1, "next_due_day": 2,
	})
	_expect("partial D2 admits the embedded Effect instance", queued.get("ok", false))
	_expect("partial D2 captures inputs", _capture_partial(ext, 2))
	var d2_visits: Array[Dictionary] = []
	for visit in 2:
		var result := ext.run_native_daily_inline_day()
		var report := ext.get_runtime_thread_report()
		print("PARTIAL_EFFECT visit=%d committed=%d continuation=%s modifier=%s effect=%s transactions=%d" % [
			visit + 1, ext.runtime_committed_day(), result.get("continuation_pending", false),
			report.modifier_pod_fallback_reason, report.effect_pod_fallback_reason,
			report.effect_pod_transaction_count])
		d2_visits.append(report)
		if visit == 0:
			var late := ext.queue_effect_pod_instance({"instance_id": 71011, "generation": 1,
				"program_key": technology.technology_effect_recipe_ids[slot], "source_handle": COUNTRY,
				"target_handle": COUNTRY, "target_generation": 1, "source_type": TECH,
				"source_id": 71011, "level": 1, "next_due_day": 2})
			_expect("independent Effect accepted during the pending day", late.ok)
		_expect("partial D2 visit %d keeps the original Modifier request pending" % [visit + 1],
			result.get("continuation_pending", false) and ext.runtime_committed_day() == 1
			and report.modifier_pod_fallback_reason == "modifier_pod_stale_generation"
			and report.effect_pod_transaction_count == 1)
	_expect("both refusals leave the published Modifier generation and hash untouched",
		d2_visits[1].modifier_pod_snapshot_generation == first.generation
		and d2_visits[1].modifier_pod_state_hash == first.state_hash)
	if ext.runtime_committed_day() == 1:
		var released := ext.submit_runtime_command(_peer_packet(
			2, 2, COUNTRY, OLD_GENERATION, source, definition, first.entry_handles[index]))
		_expect("partial D2 admits the matching retirement", released.get("admitted", false)
			and released.get("effective_day") == 2)
		_expect("partial D2 commits when the conflict is gone", ext.run_native_daily_inline_day().get("ok", false))
	var current := _published(ext)
	var sources := []
	for i in current.get("entry_definition_ids", PackedInt32Array()).size():
		if current.entry_definition_ids[i] == definition and current.entry_entity_handles[i] == COUNTRY:
			sources.append([current.entry_source_ids[i], current.entry_target_generations[i]])
	var final_report := ext.get_runtime_thread_report()
	print("PARTIAL_EFFECT settled_day=%d source_and_generation=%s expected=%s modifier_acks=%d" % [
		ext.runtime_committed_day(), sources, [[source, NEW_GENERATION]], final_report.effect_pod_ack_count])
	_expect("partial D2 publishes the originally submitted technology once and receives its receipt",
		ext.runtime_committed_day() == 2 and sources == [[source, NEW_GENERATION]]
		and final_report.effect_pod_ack_count == 1)
	var late_source := 71011 & 0xffff
	_expect("D2 publishes no late technology", current.entry_source_ids.find(late_source) < 0)
	_expect("D3 captures its own inputs", _capture_partial(ext, 3))
	_expect("D3 commits", ext.run_native_daily_inline_day().get("ok", false))
	var next := _published(ext)
	_expect("D3 publishes the late technology exactly once", next.entry_source_ids.count(late_source) == 1)
	ext.request_runtime_stop()

func _capture_partial(ext: DCWorldExt, day: int) -> bool:
	return ext.capture_runtime_inputs({"generation": day, "day": day,
		"terrain": PackedByteArray([1]), "landform": PackedByteArray([0]),
		"has_river": PackedByteArray([0]), "neighbor_indices": PackedInt32Array([-1, -1, -1, -1, -1, -1]),
	}).get("ok", false)

func _sample_world(host: WorldRuntimeHost, _clock: WorldClock, _stall: bool) -> Dictionary:
	host.set_process(false)
	_expect("the complete world uses the step-by-step executor", host._native_daily_inline_active)
	var generator := host.get_generator()
	var economy = generator.get_economy_facade()
	var ext: Object = economy.world_ext()
	var cell := int(generator.gameplay_start_report().cell)
	var country := int(generator.get_country_facade().cell_summary(cell).country_handle)
	var generation := country >> 32
	var countries = generator.get_country_facade()
	var technology_slot: int = countries.native_catalog().technology_ids.find(TECHNOLOGY)
	_expect("the Country catalog includes the technology", technology_slot >= 0)
	var source := technology_slot + 1
	var instance := ((country & 0x00007fffffffffff) << 16) | source
	var catalog: Dictionary = generator.get_modifier_facade().compiled_catalog()
	var definition: int = catalog.definition_keys.find(DEFINITION)
	_expect("formal unique-source technology exists", definition >= 0 and catalog.definition_policies[definition] == 1)
	# Register a higher generation on D1 so the real Country grant conflicts on D2.
	var existing_generation := generation + 1
	var seed_row: Dictionary = ext.submit_runtime_command(_peer_packet(1, 1, country, existing_generation, source, definition, 0))
	_expect("D1 admits the existing Modifier row", seed_row.get("ok", false))
	var first_day: Dictionary = ext.run_native_daily_inline_day()
	_expect("D1 commits", first_day.get("ok", false) and ext.runtime_committed_day() == 1)
	if ext.runtime_committed_day() != 1:
		return {}
	var first := _published(ext)
	var conflicting_handle := 0
	for i in first.entry_definition_ids.size():
		if first.entry_definition_ids[i] == definition and first.entry_source_ids[i] == source:
			conflicting_handle = first.entry_handles[i]
	_expect("D1 publishes the existing technology", conflicting_handle != 0)
	if not conflicting_handle:
		return {}
	var accepted: Dictionary = countries.grant_technology(country, TECHNOLOGY, 2, 515, true)
	_expect("Country admits its technology grant on D2", accepted.get("ok", false) and accepted.get("effective_day") == 2)
	# Two explicit visits carry the existing transaction through a genuine redelivery,
	# even when the first call's Country peer pump stops after the initial refusal.
	var attempt: Dictionary = ext.run_native_daily_inline_day()
	if not attempt.get("ok", false):
		attempt = ext.run_native_daily_inline_day()
	var diag: Dictionary = ext.get_runtime_thread_report()
	var refused: bool = ext.runtime_committed_day() == 1 and attempt.get("continuation_pending", false) \
		and diag.get("modifier_pod_fallback_reason") == "modifier_pod_stale_generation"
	_expect("both deliveries keep the conflicting transaction pending", refused)
	if refused:
		# Reading D1 consumed its ring slot. Ask for a newer publication and
		# independently compare the committed owner hash and published generation.
		var later: Dictionary = ext.get_runtime_modifier_snapshot(first.generation)
		_expect("the D1 publication remains intact throughout both D2 refusals",
			later.get("ok", false) and not later.get("available", true)
			and diag.modifier_pod_snapshot_generation == first.generation
			and diag.modifier_pod_state_hash == first.state_hash)
		var released: Dictionary = ext.submit_runtime_command(_peer_packet(2, 2, country, existing_generation, source, definition, conflicting_handle))
		print("REDELIVERY_RELEASE ", released)
		_expect("the explicit inline day admits the matching retirement on D2",
			released.get("admitted", false) and released.get("effective_day") == 2)
		if released.get("effective_day") != 2:
			return {}
		attempt = ext.run_native_daily_inline_day()
		_expect("Country, Effect and Modifier settle after the retirement", attempt.get("ok", false))
	var current := _published(ext)
	var sources := []
	for i in current.entry_definition_ids.size():
		if current.entry_definition_ids[i] == definition and current.entry_entity_handles[i] == country:
			sources.append([current.entry_source_ids[i], current.entry_target_generations[i]])
	_expect("D2 publishes one current technology under its technology number", sources == [[source, generation]])
	var explain: Dictionary = ext.explain_effect(instance)
	_expect("the original fire received its receipt", explain.get("fire_sequence") == 1 and explain.get("last_acked_fire_sequence") == 1)
	print("REDELIVERY_WORLD D2 refused=%s source_and_generation=%s expected=%s fire=%s ack=%s" % [
		refused, sources, [source, generation], explain.get("fire_sequence"), explain.get("last_acked_fire_sequence")])
	return {"day": 2}

func _published(ext: Object) -> Dictionary:
	var report: Dictionary = ext.get_runtime_thread_report()
	return ext.get_runtime_modifier_snapshot(int(report.modifier_pod_snapshot_generation) - 1)

func _peer_packet(opcode: int, day: int, country: int, generation: int, source: int, definition: int, handle: int) -> Dictionary:
	var wire := StreamPeerBuffer.new()
	wire.put_u32(1)
	wire.put_u16(1) # COUNTRY
	wire.put_u16(2) # ENTITY
	wire.put_32(definition)
	wire.put_u64(country)
	wire.put_u64(0)
	wire.put_u64(TECH)
	wire.put_u64(source)
	wire.put_32(-1)
	wire.put_32(1)
	wire.put_32(65536)
	wire.put_u64(handle)
	wire.put_u32(generation)
	wire.put_u64(0)
	return {"domain": 7, "opcode": opcode, "request_id": 81800 + day, "producer_id": 1,
		"sequence": day, "requested_day": day, "payload": wire.data_array}
