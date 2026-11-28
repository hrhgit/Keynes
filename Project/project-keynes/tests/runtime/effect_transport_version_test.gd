extends "res://tests/runtime/effect_transport_save_contract_test.gd"

const LIVE := 701
const PENDING := 703
const TRANSPORT_BIT := 1 << 13

func _run() -> void:
	var columns: Dictionary = EffectDomainCatalog.build().compile_native_catalog()
	var source := DCWorldExt.new()
	var config := _config(true, 0x821)
	_expect("source starts", source.configure_effects(columns).ok and source.start_runtime_worker(config).ok)
	_expect("old identity installed on D1", source.queue_effect_pod_instance(_binding(LIVE)).ok)
	await _day(source, true, 1)
	_expect("second identity and observation queued", source.queue_effect_pod_instance(_binding(PENDING)).ok and
		source.queue_effect_pod_metric({"instance_id": LIVE, "generation": 1, "metric_id": 0,
			"revision": 1, "value": 123}).ok)
	var saved := await _save(source, 981)
	await _stop(source)
	var original: PackedByteArray = saved.bytes
	var start := _transport_offset(original)
	var metric := start + 16 + INSTANCE_BYTES + 4
	_expect("D1 envelope locates both real pending records", saved.committed_day == 1 and start >= 0 and
		original.decode_u32(start + 12) == 1 and original.decode_u32(metric - 4) == 1)
	original.encode_s64(start + 16, 3)
	original.encode_s64(metric, 3)
	_sign(original)
	# Rewinding an already-used executor also replaces the previous world's
	# environment input, whether the caller supplies D2 before or after startup.
	var reuse := DCWorldExt.new()
	_expect("configure reusable host", reuse.configure_effects(columns).ok)
	for pass_index in 2:
		_expect("restore D1", reuse.restore_runtime_bundle(original).ok and reuse.start_runtime_worker(config).ok)
		await _day(reuse, true, 2)
		await _day(reuse, true, 3)
		_expect("rewind consumes only the restored D2 and D3 inputs",
			reuse.runtime_committed_day() == 3 and reuse.get_runtime_thread_report().simulation_environment_generation == 3)
		await _stop(reuse)
	var target := DCWorldExt.new()
	_expect("dated D3 candidate is prepared", target.configure_effects(columns).ok and
		target.restore_runtime_bundle(original).ok)
	var etq1 := original.duplicate()
	etq1.encode_u32(start, ETQ1)
	for offset in [metric, start + 16]:
		etq1 = etq1.slice(0, offset) + etq1.slice(offset + 8)
	var missing := original.slice(0, start) + original.slice(-8)
	missing.encode_u32(85, missing.decode_u32(85) & ~TRANSPORT_BIT)
	var empty_flagged := original.slice(0, start) + original.slice(-8)
	_expect("v6 header requires the transport bit", not Header.valid(missing))
	for pair in [["ETQ1", etq1], ["missing", missing], ["empty", empty_flagged]]:
		var broken: PackedByteArray = pair[1].duplicate()
		_sign(broken)
		var verdict := target.restore_runtime_bundle(broken)
		print("EFFECT_V6 tail=%s ok=%s code=%s" % [pair[0], verdict.ok, verdict.code])
		_expect("v6 refuses " + str(pair[0]), not verdict.ok and verdict.code == "effect_transport_continuation_invalid")
		_expect("previous D1 archive starts", target.start_runtime_worker(config).ok)
		var after := await _save(target, 982)
		_expect("refusal leaves both original D3 dates and payloads intact", after.committed_day == 1 and
			after.bytes.slice(_transport_offset(after.bytes), -8) == original.slice(start, -8))
		await _stop(target)
		_expect("prepare reference again", target.restore_runtime_bundle(original).ok)
	for tail in [etq1, missing]:
		var old: PackedByteArray = tail.duplicate()
		old.encode_u32(4, 5)
		_sign(old)
		_expect("v5 still accepts its historic tail", target.restore_runtime_bundle(old).ok)
	for version in [5, 6]:
		for identity in [[LIVE, 1, false], [PENDING, 1, false], [LIVE, 2, true], [799, 1, true]]:
			var old := original.duplicate()
			old.encode_u32(4, version)
			old.encode_s64(metric + 8, identity[0])
			old.encode_u32(metric + 16, identity[1])
			old.encode_s64(metric + 24, -1)
			_sign(old)
			var verdict := target.restore_runtime_bundle(old)
			var drops: bool = version == 5 and identity[2]
			print("EFFECT_METRIC v=%d id=%d gen=%d ok=%s code=%s" % [version, identity[0], identity[1], verdict.ok, verdict.code])
			_expect("invalid revision checked against saved and queued generations", verdict.ok == drops and
				(drops or verdict.code == "effect_transport_continuation_invalid"))
			if verdict.ok and drops:
				_expect("v5 installs", target.start_runtime_worker(config).ok)
				var dropped_before: int = target.get_runtime_thread_report().effect_instance_rejected_count
				var migrated := await _save(target, 983)
				var reader := DCWorldExt.new()
				_expect("saving before the stale row drains makes a readable v6", migrated.bundle_version == 6 and
					reader.configure_effects(columns).ok and reader.restore_runtime_bundle(migrated.bytes).ok)
				_expect("migrated v6 installs", reader.start_runtime_worker(config).ok)
				await _day(reader, true, 2)
				await _day(reader, true, 3)
				_expect("v6 continuation also discards exactly once", reader.get_runtime_thread_report().effect_instance_rejected_count == 1)
				await _stop(reader)
				await _day(target, true, 2)
				_expect("D2 keeps the D3 discard pending", target.get_runtime_thread_report().effect_instance_rejected_count == dropped_before)
				await _day(target, true, 3)
				_expect("stale row is discarded on its day", target.runtime_committed_day() == 3 and
					target.get_runtime_thread_report().effect_instance_rejected_count == dropped_before + 1)
				await _stop(target)
	var bad_day := original.duplicate()
	bad_day.encode_s64(16, 4611686018427387904)
	_sign(bad_day)
	var day_result := target.restore_runtime_bundle(bad_day)
	_expect("unrepresentable day rejected on load", not day_result.ok and day_result.code == "command_seal_day_out_of_range")
	var fresh := DCWorldExt.new()
	_expect("fresh validation target configured", fresh.configure_effects(columns).ok)
	var bad_live := original.duplicate()
	bad_live.encode_u32(4, 5)
	bad_live.encode_s64(metric + 24, -1)
	_sign(bad_live)
	_expect("restored identity, even on an empty host, needs a valid revision", not fresh.restore_runtime_bundle(bad_live).ok)
	for metric_day in [2, 3, 4]:
		var old := original.duplicate()
		old.encode_u32(4, 5)
		old.encode_s64(metric + 8, PENDING)
		old.encode_s64(metric, metric_day)
		old.encode_s64(metric + 24, -1)
		_sign(old)
		_expect("pending identity is live only from its admission day, observation D%d" % metric_day,
			target.restore_runtime_bundle(old).ok == (metric_day < 3))
	var invalid_id := original.duplicate()
	invalid_id.encode_u32(4, 5)
	invalid_id.encode_s64(metric + 8, 799)
	invalid_id.encode_s32(metric + 20, -1)
	invalid_id.encode_s64(metric + 24, -1)
	_sign(invalid_id)
	_expect("stale legacy exception still validates the metric id", not target.restore_runtime_bundle(invalid_id).ok)
	_finish_contract()

func _binding(id: int) -> Dictionary:
	return {"instance_id": id, "generation": 1, "program_id": 0, "source_handle": id,
		"target_handle": id, "target_generation": 1, "next_due_day": 70}
