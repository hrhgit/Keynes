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
	print("effect modifier redelivery: %d checks, %d failures" % [_checks, _failures])
	call_deferred("quit", 0 if _failures == 0 else 1)

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
