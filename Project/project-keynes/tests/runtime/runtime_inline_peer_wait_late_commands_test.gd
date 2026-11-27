extends "res://tests/runtime/background_daily_self_sufficiency_test.gd"

const TECHNOLOGY := "tech.animal_husbandry"


class InlineHost extends WorldRuntimeHost:
	var recipe_disabled := false

	func _native_daily_inline_requested() -> bool:
		return true

	func _start_runtime_executor() -> void:
		# Country can enqueue the existing recipe, but cannot receive a first-fire
		# acknowledgement. The wait survives the inline adapter's peer pump.
		var country: Dictionary = _generator.get_country_facade().native_catalog()
		var technology := (country.technology_ids as PackedStringArray).find(TECHNOLOGY)
		var effects := LoadingCatalogCache.effect_native_columns()
		if effects.is_empty():
			effects = EffectDomainCatalog.build().compile_native_catalog()
		if technology >= 0:
			var recipe: String = country.technology_effect_recipe_ids[technology]
			var program := (effects.effect_keys as PackedStringArray).find(recipe)
			if program >= 0:
				effects.enabled[program] = 0
				recipe_disabled = _generator.get_data_core_world_ext().configure_effects(effects).get("ok", false)
		super._start_runtime_executor()


func _create_host() -> WorldRuntimeHost:
	return InlineHost.new()


func _background_config() -> NewGameConfig:
	var config := super._background_config()
	config.country.foreign_count = 0
	config.base.map_width = 40
	config.base.map_height = 28
	return config


func _run() -> void:
	_partial_day_accepts_late_gameplay()
	var result := await _run_world(false)
	_expect("the admission check ran after the peer wait", result.get("checked", false))
	_finish()


func _submit_event(ext: Object, day: int, request_id: int) -> Dictionary:
	var wire := PackedByteArray()
	wire.resize(80) # PUBLISH_EVENT with four zero payload values
	wire.encode_s32(0, 5)
	wire.encode_s32(4, 4)
	wire.encode_s32(8, GameplayEventBus.EVENT_VISUAL_DIRTY_INTENT)
	wire.encode_s64(12, day)
	wire.encode_u64(20, 4294967297)
	wire.encode_u32(28, 1)
	wire.encode_u64(72, request_id)
	return ext.submit_runtime_command({"domain": 8, "opcode": 4,
		"request_id": request_id, "producer_id": 708, "sequence": request_id,
		"requested_day": day, "payload": wire})


func _partial_day_accepts_late_gameplay() -> void:
	# This partial host has no full-world seal. Country lacks its snapshot,
	# so its day stays open while new GameplayEffect packets are admitted.
	var ext := DCWorldExt.new()
	var started: Dictionary = ext.start_runtime_worker({"simulation_thread_mode": "ACTIVE",
		"graph_coverage_complete": true, "native_daily_inline": true,
		"authoritative_domain_mask": 0xa85, "day": 0, "speed_days_per_second": 0, "paused": true})
	_expect("the partial fixture starts", started.get("ok", false))
	var captured: Dictionary = ext.capture_runtime_inputs({"generation": 1, "day": 1,
		"terrain": PackedByteArray([1]), "landform": PackedByteArray([0]),
		"has_river": PackedByteArray([0]), "neighbor_indices": PackedInt32Array([-1, -1, -1, -1, -1, -1])})
	_expect("the partial fixture has its day-one frame", captured.get("ok", false))
	var first := {}
	for request_id in [708301, 708302]:
		var accepted := _submit_event(ext, 1, request_id)
		_expect("the partial host admits each request on its still-open day",
			accepted.get("admitted", false) and accepted.get("effective_day") == 1)
		var attempt: Dictionary = ext.run_native_daily_inline_day()
		var completed := int(attempt.get("completed_domain_mask", 0))
		_expect("GameplayEffect accepts the input while Country and Events remain open",
			not attempt.get("ok", true) and (completed & 0x80) != 0 and (completed & 0x204) == 0)
		if not first.is_empty():
			_expect("the late packet adds exactly one unit of gameplay work",
				attempt.get("work_units") == int(first.work_units) + 1)
		first = attempt
	# An invalid late row must actually be inspected. A cached success would
	# incorrectly leave GameplayEffect marked complete.
	var rejected: Dictionary = ext.submit_runtime_command({"domain": 8, "opcode": 4,
		"request_id": 708303, "producer_id": 708, "sequence": 708303, "requested_day": 1})
	_expect("the invalid typed payload reaches the domain validator", rejected.get("admitted", false))
	var failed: Dictionary = ext.run_native_daily_inline_day()
	_expect("GameplayEffect refuses a new malformed packet on the same day",
		not failed.get("ok", true) and (int(failed.get("completed_domain_mask", -1)) & 0x80) == 0)
	ext.request_runtime_stop()


func _sample_world(host: WorldRuntimeHost, _clock: WorldClock, _stall: bool) -> Dictionary:
	host.set_process(false)
	var generator := host.get_generator()
	var ext: Object = generator.get_data_core_world_ext()
	var ready := (host as InlineHost).recipe_disabled and host._native_daily_inline_active
	_expect("the formal inline executor uses the disabled first-fire recipe", ready)
	if not ready:
		return {}
	var first: Dictionary = ext.run_native_daily_inline_day()
	_expect("day one committed", first.get("ok", false) and first.get("committed_day") == 1)
	if not first.get("ok", false):
		return {}
	var country = generator.get_country_facade()
	var cell := int(generator.gameplay_start_report().get("cell", -1))
	var handle := int(country.cell_summary(cell).get("country_handle", 0))
	var grant: Dictionary = country.grant_technology(handle, TECHNOLOGY, 2, 515, true)
	_expect("the technology is admitted before day two freezes",
		grant.get("ok", false) and grant.get("effective_day") == 2)
	var wait: Dictionary = ext.run_native_daily_inline_day()
	var parked: bool = not wait.get("ok", true) and wait.get("continuation_pending", false) \
			and wait.get("reason") == "country_worker_peer_results_pending" and ext.runtime_committed_day() == 1
	_expect("Country is still waiting for the Effect acknowledgement on day two", parked)
	if not parked:
		print("INLINE_COUNTRY_WAIT ", JSON.stringify(wait))
		return {}
	# The first packet also establishes a nonzero GameplayEffect workload.
	# A second new packet must add exactly one unit to the same day's work.
	var after_first := {}
	for request_id in [708201, 708202]:
		var late := _submit_event(ext, 2, request_id)
		_expect("a command received during the peer wait keeps its requested day two",
			late.get("admitted", false) and late.get("effective_day") == 2)
		var attempt: Dictionary = ext.run_native_daily_inline_day()
		_expect("day two processes GameplayEffect and continues waiting for Country",
			attempt.get("day") == 2 and attempt.get("reason") == "country_worker_peer_results_pending"
			and (int(attempt.get("completed_domain_mask", 0)) & 0x80) != 0
			and ext.runtime_committed_day() == 1)
		if not after_first.is_empty():
			_expect("the second new packet adds one unit of work on day two",
				attempt.get("work_units") == int(after_first.work_units) + 1)
		after_first = attempt
	return {"checked": true}
