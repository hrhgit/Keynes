extends "res://tests/economy/economy_rolling_runtime_test.gd"

var _cases := 0
var _error_path := RegEx.create_from_string(r"[A-Za-z_][A-Za-z0-9_.\[\]]*$")


func _init() -> void:
	call_deferred("_run_checkpoint")


func _packet(country: int) -> Dictionary:
	var unrest := []
	for i in 12:
		unrest.append({"event_id": "unrest_%d" % i})
	return {"country": country, "seed": 83, "events": [{"event_id": "checkpoint_event"}],
		"unrest": unrest, "unrest_actions": [[], [], [], []], "month_lengths": [30]}


func _rich_state(country: int) -> Dictionary:
	var definition := {"event_id": "fixture", "title": "待定事件"}
	var request := {"ai_request_seq": 8, "day": 6, "effective_day": 10, "cell_ctx": {"cell": 1}}
	return {
		"world_seed": 83, "last_pulse_day": 17, "last_fact_event_id": 12,
		"event_pause_mask": 0, "next_ai_request_seq": 10, "ai_enabled": true,
		"pending_choice": {"effective_day": 10, "offer_id": 5, "offer_generation": 2, "option_index": 1},
		"active_offer": {"offer_id": 5, "offer_generation": 2}, "ready_queue": [{"offer_id": 6}],
		"chronicle": [{"record_id": 4}], "pending_event_pause_masks": [[12, 3]],
		"pending_ai_request": request, "pending_ai_reply": {"ok": true, "definition": definition},
		"pending_ai_settings": [[11, false]],
		"ai_event_pool": [{"pool_id": 3, "state_id": "state", "cell_idx": 1,
			"created_day": 4, "def_dict": definition}],
		"state_last_seed": {"state": 3}, "cell_year_event_counts": {"0:1": 1},
		"cooldowns": {"country:fixture": 8}, "completed_one_shots": {"done": 7},
		"state_tracking": {"tracking": {"cell": 1, "since_day": 2, "last_seen_day": 3,
			"peak_price_ratio": 1.5, "min_satisfaction": 0.5}},
		"story_flags": {"test": {"set_day": 3, "expires_day": 6, "value": 2}},
		"dynamic_events_by_id": {"fixture": definition},
		"weight_biases": [{"id": 2, "target_event_id": "fixture", "target_tag": "tag",
			"scope_cell": 1, "add_weight": 4, "mul_q16": 65536, "expires_day": 8, "source_event_id": "from"}],
		"scheduled_events": [{"due_day": 12, "event_id": "fixture", "cell_idx": 1, "chain_id": "chain",
			"parent_record_id": 4, "ai_prompt_hint": "续篇", "ai_requested": true}],
		"stratum_unrest": {"last_day": 8, "last_fact_id": 6, "sequence": 7, "needs_player_recovery": false,
			"pending_independence": [{"cell": 1, "owner_handle": country, "queued_day": 4,
				"stable_id": "test_independence", "submitted": true}],
			"pending_stage_checks": [{"cell": 1, "profession": 3, "stage": 2, "owner_handle": country}]},
	}


func _roundtrip(ext: Object, packet: Dictionary, initial: Dictionary) -> Dictionary:
	if not ext.configure_gameplay_narrative(packet, initial):
		_expect("rich Narrative fixture configures", false)
		return {}
	var first: Dictionary = ext.capture_gameplay_narrative()
	for key in initial:
		if key == "stratum_unrest":
			for field in initial[key]:
				_expect("fixture survives first capture: unrest.%s" % field,
					first.get(key, {}).get(field) == initial[key][field])
		else:
			_expect("fixture survives first capture: %s" % key, first.get(key) == initial[key])
	var bytes := var_to_bytes(first)
	var staged: Dictionary = ext.submit_gameplay_narrative(&"restore", bytes_to_var(bytes))
	_expect("frozen bytes accepted for restore", staged.get("ok", false))
	_expect("staged checkpoint installed", ext.configure_gameplay_narrative(packet, {}))
	_expect("capture → restore → capture preserves bytes", var_to_bytes(ext.capture_gameplay_narrative()) == bytes)
	return first


func _world_hash(ext: Object) -> PackedByteArray:
	var sha := HashingContext.new()
	sha.start(HashingContext.HASH_SHA256)
	sha.update(var_to_bytes([ext.get_country_state_hash(), ext.get_economy_state_hash(),
		ext.capture_gameplay_narrative(), ext.get_gameplay_narrative_view()]))
	return sha.finish()


func _reject(ext: Object, patch: Dictionary, field: String) -> void:
	var before := _world_hash(ext)
	var result: Dictionary = ext.submit_gameplay_narrative(&"restore", patch)
	var path := _error_path.search(str(result.get("message")))
	_expect("bad checkpoint rejected: %s" % field, result.get("ok") == false
		and result.get("code") == "narrative_archive_invalid" and path != null and path.get_string() == field)
	_expect("world hash unchanged after rejecting %s" % field, _world_hash(ext) == before)
	_cases += 1


func _bad_checkpoints(ext: Object) -> void:
	# Start each case from an independent patch; absent optional fields are legal in older saves.
	for field in ["version", "world_seed", "player_country_handle", "next_offer_id",
			"next_offer_generation", "next_record_id", "next_bias_id", "next_mod_source_id",
			"last_pulse_day", "last_popup_day", "last_fact_event_id", "last_ai_request_day",
			"next_ai_request_seq", "last_state_probe_day", "event_pause_mask",
			"last_notification_fact", "notification_sequence", "last_notice_era", "next_pool_id",
			"ai_enabled", "ready_queue", "chronicle", "ai_event_pool", "weight_biases",
			"scheduled_events", "pending_event_pause_masks", "pending_ai_settings", "pending_ai_requests",
			"active_offer", "pending_choice", "pending_ai_request", "pending_ai_reply", "state_tracking",
			"state_last_seed", "cell_year_event_counts", "cooldowns", "completed_one_shots", "story_flags",
			"dynamic_events_by_id", "stratum_unrest"]:
		_reject(ext, {field: "invalid"}, field)
	for field in ["state_last_seed", "cell_year_event_counts", "cooldowns", "completed_one_shots",
			"state_tracking", "story_flags", "dynamic_events_by_id"]:
		_reject(ext, {field: {"bad": false}}, field + ".bad")
	for spec in [
			["story_flags", "value", false], ["state_tracking", "cell", false],
			["state_tracking", "min_satisfaction", "invalid"], ["dynamic_events_by_id", "event_id", ""]]:
		_reject(ext, {spec[0]: {"x": {spec[1]: spec[2]}}}, "%s.x.%s" % [spec[0], spec[1]])
	_reject(ext, {"active_offer": {"offer_id": 0}}, "active_offer.offer_id")
	var choice := {"effective_day": 6, "offer_id": 1, "offer_generation": 2, "option_index": 0}
	for key in choice:
		var invalid := choice.duplicate()
		invalid[key] = -1
		_reject(ext, {"pending_choice": invalid}, "pending_choice." + key)
	choice.automatic = 1
	_reject(ext, {"pending_choice": choice}, "pending_choice.automatic")
	for spec in [["ready_queue", "offer_id", -1], ["chronicle", "record_id", false],
			["weight_biases", "id", "invalid"], ["scheduled_events", "due_day", false]]:
		_reject(ext, {spec[0]: [{spec[1]: spec[2]}]}, "%s[0].%s" % [spec[0], spec[1]])
	_reject(ext, {"scheduled_events": [{"due_day": 1, "cell_idx": false}]}, "scheduled_events[0].cell_idx")
	_reject(ext, {"scheduled_events": [{"due_day": 1, "ai_requested": 1}]}, "scheduled_events[0].ai_requested")
	for value in [null, {}, {"event_id": ""}]:
		var field := "ai_event_pool[0].def_dict" + (".event_id" if value is Dictionary else "")
		_reject(ext, {"ai_event_pool": [{"def_dict": value}]}, field)
	for key in ["ready_queue", "chronicle", "weight_biases", "scheduled_events", "ai_event_pool", "pending_ai_requests"]:
		_reject(ext, {key: [false]}, key + "[0]")
	for key in ["pending_event_pause_masks", "pending_ai_settings"]:
		var valid_value = 3 if key == "pending_event_pause_masks" else true
		for row in [null, [], [false, valid_value], [1, "invalid"], [-1, valid_value]]:
			_reject(ext, {key: [row]}, key + "[0]")
		_reject(ext, {key: [[3, valid_value], [3, valid_value]]}, key + "[1]")
	var request := {"ai_request_seq": 2, "day": 4, "effective_day": 5, "cell_ctx": {}}
	_reject(ext, {"pending_ai_reply": {"ok": false}}, "pending_ai_request.reply")
	for spec in [["ai_request_seq", 0], ["due_day", false], ["day", false],
			["effective_day", 2], ["cell_ctx", []]]:
		var invalid := request.duplicate()
		invalid[spec[0]] = spec[1]
		_reject(ext, {"pending_ai_request": invalid}, "pending_ai_request." + spec[0])
	var no_day := request.duplicate()
	no_day.erase("day")
	_reject(ext, {"pending_ai_request": no_day}, "pending_ai_request.effective_day")
	for entry in [[{"ok": 1}, "ok"], [{"ok": true}, "definition"],
			[{"ok": true, "definition": {}}, "definition.event_id"], [{"ok": false, "code": 4}, "code"]]:
		_reject(ext, {"pending_ai_request": request, "pending_ai_reply": entry[0]}, "pending_ai_request.reply." + entry[1])
	var record := {"request": request, "reply": {}}
	_reject(ext, {"pending_ai_requests": [record], "pending_ai_request": request}, "pending_ai_requests")
	_reject(ext, {"pending_ai_requests": [{"request": 1}]}, "pending_ai_requests[0].request")
	_reject(ext, {"pending_ai_requests": [{"request": request, "reply": 1}]}, "pending_ai_requests[0].reply")
	_reject(ext, {"pending_ai_requests": [{}]}, "pending_ai_requests[0].request.effective_day")
	_reject(ext, {"pending_ai_requests": [record, record]}, "pending_ai_requests[1].request.ai_request_seq")
	_reject(ext, {"pending_ai_request": request, "next_ai_request_seq": 2}, "next_ai_request_seq")
	for key in ["last_fact_id", "last_day", "sequence", "needs_player_recovery", "pending_independence", "pending_stage_checks"]:
		_reject(ext, {"stratum_unrest": {key: "invalid"}}, "stratum_unrest." + key)
	for key in ["pending_independence", "pending_stage_checks"]:
		_reject(ext, {"stratum_unrest": {key: [false]}}, key + "[0]")
		_reject(ext, {"stratum_unrest": {key: [{"owner_handle": false}]}}, "stratum_unrest.%s[0].owner_handle" % key)


func _run_checkpoint() -> void:
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	var catalog := compiled.duplicate(true)
	catalog.erase("ok")
	var profile: Dictionary = load("res://data/economy/default_economy.tres").to_native_profile()
	var ext := _new_runtime(compiled, catalog, profile, 83)
	var country: int = ext.get_country_cell_summary(0).country_handle
	var terrain := PackedByteArray()
	terrain.resize(CELL_COUNT)
	terrain.fill(2)
	var boundary: Dictionary = ext.capture_runtime_inputs({"generation": 1, "day": 0, "terrain": terrain})
	_expect("stopped world has a runtime boundary", boundary.get("ok", false))
	var packet := _packet(country)
	var header: Dictionary = ext.capture_gameplay_narrative()
	_expect("empty runtime returns versioned header", header.get("schema") == "PKNarrativeRuntime"
		and typeof(header.get("version")) == TYPE_INT and header.version > 0 and header.size() == 2)
	var state := _rich_state(country)
	var first := _roundtrip(ext, packet, state)
	_expect("configured and empty headers use same version", first.get("version") == header.get("version"))
	var second_request: Dictionary = state.pending_ai_request.duplicate(true)
	second_request.ai_request_seq += 1
	state.pending_ai_requests = [{"request": state.pending_ai_request, "reply": state.pending_ai_reply},
		{"request": second_request, "reply": {}}]
	state.erase("pending_ai_request")
	state.erase("pending_ai_reply")
	_roundtrip(ext, packet, state)
	_bad_checkpoints(ext)
	print("=== Narrative checkpoint: two byte roundtrips, %d rejection/hash checks, %d failures ===" % [_cases, failures])
	quit(int(failures != 0))
