extends "res://tests/runtime/background_daily_self_sufficiency_test.gd"

const Modifier = preload("res://scripts/modifier/modifier_facade.gd")
const TAX_MODIFIER := "test.same_day_income_tax"
const INCOME_TAX_MEAN_BP := 55
const ADD_PER_STACK := 1000.5
const FIRST_REQUEST := 707001
const SECOND_REQUEST := 707002
const GAMEPLAY_REQUEST := 708001


class TaxHost extends WorldRuntimeHost:
	var definition_id := -1
	var income_stat_ids := PackedInt32Array()

	func _start_runtime_executor() -> void:
		var catalog: Dictionary = _generator.get_modifier_facade().compiled_catalog().duplicate(true)
		definition_id = catalog.definition_keys.size()
		catalog.definition_keys.append(TAX_MODIFIER)
		catalog.definition_versions.append(1)
		catalog.definition_domains.append(Modifier.Domain.COUNTRY)
		catalog.definition_policies.append(2) # STACK_REFRESH
		catalog.definition_max_stacks.append(8)
		catalog.definition_default_duration.append(-1)
		for stat in catalog.stat_keys.size():
			if String(catalog.stat_keys[stat]).begins_with("country.tax.income."):
				income_stat_ids.append(stat)
				catalog.term_stat_ids.append(stat)
				catalog.term_operations.append(0) # ADD
				catalog.term_values.append(ADD_PER_STACK)
		catalog.definition_term_offsets.append(catalog.term_values.size())
		var ext = _generator.get_data_core_world_ext()
		var configured: Dictionary = ext.configure_modifiers(catalog, get_current_map().cell_count())
		if not configured.get("ok", false):
			definition_id = -1
		super._start_runtime_executor()


func _create_host() -> WorldRuntimeHost:
	return TaxHost.new()


func _background_config() -> NewGameConfig:
	var config := super._background_config()
	config.country.foreign_count = 0
	config.base.map_width = 40
	config.base.map_height = 28
	return config


func _run() -> void:
	var result := await _run_world(false)
	_expect("the scenario finished every check through day 3", result.get("completed_day") == 3)
	print("modifier same-day reapply: %d checks, %d failures" % [_checks, _failures])
	call_deferred("quit", 0 if _failures == 0 else 1)


func _sample_world(host: WorldRuntimeHost, clock: WorldClock, _stall: bool) -> Dictionary:
	var fixture := host as TaxHost
	var generator := host.get_generator()
	var country = generator.get_country_facade()
	var economy = generator.get_economy_facade()
	var ext = economy.world_ext()
	var cell := int(generator.gameplay_start_report().get("cell", -1))
	var handle := int(country.cell_summary(cell).get("country_handle", 0))
	var valid := fixture.definition_id >= 0 and not fixture.income_stat_ids.is_empty() and handle != 0
	_expect("the country and stackable income tax modifier exist", valid)
	if not valid:
		return {}
	var previous_generation := int(ext.get_runtime_thread_report().modifier_pod_snapshot_generation)
	var previous_stages := {}
	clock.pause(false)
	for day in range(1, 4):
		if day == 2:
			var grant: Dictionary = country.grant_technology(handle, &"tech.animal_husbandry", day, 515, true)
			_expect("the technology grant is admitted for day 2",
				grant.get("ok", false) and grant.get("effective_day") == day)
			_admit(ext, _apply_packet(fixture.definition_id, handle, FIRST_REQUEST, day))
			_admit(ext, _gameplay_event_packet(handle, day))
		if day == 3:
			var packet := _apply_packet(fixture.definition_id, handle, SECOND_REQUEST, day)
			_admit(ext, packet)
			# Resubmit the identical request id, producer, sequence and payload.
			# Its effect is checked separately from the first source below.
			ext.submit_runtime_command(packet)
		_publish_day(host, clock, day)
		var settled := await _wait_golden_read_boundary(host, economy, day)
		_expect("day %d settles" % day, settled)
		if not settled:
			return {}
		var runtime: Dictionary = ext.get_runtime_thread_report()
		runtime["gameplay_effect_generation"] = await _saved_gameplay_generation(ext, day)
		for field in ["trigger_pod_snapshot_generation", "gameplay_effect_generation",
				"events_pod_snapshot_generation"]:
			if previous_stages.has(field):
				_expect("%s advances exactly once on day %d" % [field, day],
					int(runtime[field]) == int(previous_stages[field]) + 1)
			previous_stages[field] = int(runtime[field])
		if day == 2:
			_expect("Country first waited for a peer on day 2", runtime.get("day_wait_day") == day
				and (int(runtime.get("day_wait_missing_mask", 0)) & 4) != 0)
		if day >= 2:
			_check_gameplay_event(ext, handle, day)
		var generation := int(runtime.modifier_pod_snapshot_generation)
		_expect("Modifier commits exactly once on day %d" % day, generation == previous_generation + 1)
		previous_generation = generation
		var snapshot: Dictionary = ext.get_runtime_modifier_snapshot(generation - 1)
		_expect("the published Modifier snapshot belongs to day %d" % day,
			snapshot.get("available", false) and snapshot.get("committed_day") == day)
		if not snapshot.get("available", false):
			return {}
		var expected_add := (day - 1) * ADD_PER_STACK
		var frozen: Dictionary = ext.sample_effect_metric_probe(INCOME_TAX_MEAN_BP, cell, handle)
		# All professions receive the same amount over a zero base. Their frozen
		# mean is the rate Economy used independently of the Modifier snapshot.
		_expect("Economy freezes the expected income rate on day %d" % day,
			frozen.get("ok", false) and frozen.get("value") == roundi(expected_add))
		var adds: Array = []
		for index in snapshot.bucket_stat_ids.size():
			if snapshot.bucket_scope_ids[index] == handle and snapshot.bucket_scopes[index] == Modifier.Scope.ENTITY \
					and fixture.income_stat_ids.has(snapshot.bucket_stat_ids[index]):
				adds.append(snapshot.bucket_sum_add[index])
		_expect("all income stat buckets reflect each request once on day %d" % day,
			adds.is_empty() if day == 1 else adds.size() == fixture.income_stat_ids.size()
			and adds.all(func(value): return value == expected_add))
		var stacks_by_source := {}
		for index in snapshot.entry_definition_ids.size():
			if snapshot.entry_definition_ids[index] == fixture.definition_id:
				stacks_by_source[snapshot.entry_source_ids[index]] = snapshot.entry_stacks[index]
		var wanted := {}
		if day >= 2:
			wanted[FIRST_REQUEST] = 1
		if day == 3:
			wanted[SECOND_REQUEST] = 1
		_expect("each distinct input has one stack on day %d" % day, stacks_by_source == wanted)
		print("MODIFIER_DAY day=%d generation=%d frozen_bp=%s bucket_add=%s stacks=%s" % [
			day, generation, frozen.get("value"), adds.front() if not adds.is_empty() else 0, stacks_by_source])
	return {"completed_day": 3}


func _saved_gameplay_generation(ext: Object, day: int) -> int:
	var request_id := 708100 + day
	var request: Dictionary = ext.request_runtime_save(request_id)
	var archive := {}
	if request.get("ok", false):
		for _slice in range(MAX_SLICES_PER_DAY):
			archive = ext.poll_runtime_save(request_id)
			if archive.get("ready", false) or not archive.get("ok", false):
				break
			await process_frame
	var bytes: PackedByteArray = archive.get("bytes", PackedByteArray())
	# GMP1 is preceded by its section marker and byte length. The payload
	# starts with the same marker, ABI version, and the committed generation.
	var offset := bytes.find(0x47)
	while offset >= 0 and offset + 40 <= bytes.size():
		if bytes.decode_u32(offset) == 0x31504d47 and bytes.decode_u32(offset + 4) == 32 \
				and bytes.decode_u32(offset + 8) == 0x31504d47 and bytes.decode_u32(offset + 12) == 1:
			_expect("the saved GameplayEffect generation belongs to day %d" % day,
				archive.get("committed_day") == day)
			return bytes.decode_u64(offset + 16)
		offset = bytes.find(0x47, offset + 1)
	_expect("GameplayEffect provides its committed GMP1 section for day %d" % day, false)
	return -1


func _admit(ext: Object, packet: Dictionary) -> void:
	var result: Dictionary = ext.submit_runtime_command(packet)
	_expect("request %d admitted on its requested day" % packet.request_id,
		result.get("admitted", false) and result.get("effective_day") == packet.requested_day)


func _gameplay_event_packet(handle: int, day: int) -> Dictionary:
	# The production GameplayEffect PUBLISH_EVENT wire layout.
	var wire := StreamPeerBuffer.new()
	wire.put_32(5) # PUBLISH_EVENT
	wire.put_32(4) # Events target
	wire.put_32(GameplayEventBus.EVENT_VISUAL_DIRTY_INTENT)
	wire.put_64(day)
	wire.put_u64(handle)
	wire.put_u32(handle >> 32)
	wire.put_64(GAMEPLAY_REQUEST)
	for value in [5, 6, 7, 8]:
		wire.put_64(value)
	wire.put_u64(GAMEPLAY_REQUEST)
	return {"domain": 8, "opcode": GameplayEventBus.EVENT_VISUAL_DIRTY_INTENT,
		"request_id": GAMEPLAY_REQUEST, "producer_id": 708, "sequence": 1,
		"requested_day": day, "payload": wire.data_array}


func _check_gameplay_event(ext: Object, handle: int, day: int) -> void:
	var events: Dictionary = ext.poll_gameplay_events({"consumer_id": &"same_day_test",
		"after_event_id": 0, "max_events": 0, "type": GameplayEventBus.EVENT_VISUAL_DIRTY_INTENT})
	_expect("Events publishes day %d" % day,
		events.get("available", false) and events.get("committed_day") == day)
	var values: PackedInt64Array = events.get("value_i64", PackedInt64Array())
	_expect("the one GameplayEffect request has one event through day %d" % day,
		values.count(GAMEPLAY_REQUEST) == 1)
	var row := values.find(GAMEPLAY_REQUEST)
	if row >= 0:
		_expect("the event retains its day, source, target and payload through day %d" % day,
			events.tick[row] == 2 and events.source[row] == GameplayEventBus.SOURCE_EFFECT
			and events.entity_handle[row] == handle and events.payload_i0[row] == 5
			and events.payload_i1[row] == 6 and events.payload_i2[row] == 7
			and events.payload_i3[row] == 8)


func _apply_packet(definition_id: int, handle: int, request_id: int, day: int) -> Dictionary:
	# The public raw command entry point lets a caller resend the same identity.
	# Layout follows RUNTIME_MODIFIER_POD_WIRE_ABI_VERSION 1.
	var wire := StreamPeerBuffer.new()
	wire.put_u32(1)
	wire.put_u16(Modifier.Domain.COUNTRY)
	wire.put_u16(Modifier.Scope.ENTITY)
	wire.put_32(definition_id)
	wire.put_u64(handle)
	wire.put_u64(0) # group
	wire.put_u64(707) # source type
	wire.put_u64(request_id) # source id
	wire.put_32(-1) # permanent
	wire.put_32(1) # one stack
	wire.put_32(65536) # full magnitude
	wire.put_u64(0) # no existing instance
	wire.put_u32(handle >> 32)
	wire.put_u64(0) # independent of the environment generation
	return {"domain": 7, "opcode": Modifier.Opcode.APPLY, "request_id": request_id,
		"producer_id": 707, "sequence": request_id, "requested_day": day, "payload": wire.data_array}
