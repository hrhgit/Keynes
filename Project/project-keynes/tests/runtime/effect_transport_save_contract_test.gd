extends "res://tests/runtime/runtime_inline_save_restore_test.gd"

const Header := preload("res://scripts/game/pksr_bundle_header.gd")
const ETQ1 := 0x31515445
const ETQ2 := 0x32515445
const ID := 711
const INSTANCE_BYTES := 90
const METRIC_BYTES := 40

func _run() -> void:
	var ext := DCWorldExt.new()
	var catalog := EffectDomainCatalog.build()
	var columns: Dictionary = catalog.compile_native_catalog()
	var count: int = catalog.metric_keys.size()
	var config := _config(true, 0x841)
	_expect("Effect configured", ext.configure_effects(columns).get("effect_pod_ready", false))
	_expect("executor starts", ext.start_runtime_worker(config).get("ok", false))
	var input := {"instance_id": ID, "generation": 1, "program_id": 0, "source_handle": 11,
		"target_handle": 12, "target_generation": 1, "next_due_day": 1}
	var metric := {"instance_id": ID, "generation": 1, "metric_id": count - 1, "revision": 7, "value": 42}
	_expect("pending instance and highest valid metric accepted", ext.queue_effect_pod_instance(input).ok
		and ext.queue_effect_pod_metric(metric).ok)
	_expect("retirement and receipt accepted", ext.queue_effect_pod_remove(712, 1).ok
		and ext.submit_effect_worker_ack({"transaction_id": 17, "target_handle": 12, "domain": 3}).ok)
	var saved := await _save(ext, 901)
	var bytes: PackedByteArray = saved.bytes
	var start := _transport_offset(bytes)
	var metric_count := start + 16 + INSTANCE_BYTES
	var first_metric := metric_count + 4
	if start < 0 or bytes.decode_u32(start + 12) != 1 or bytes.decode_u32(metric_count) != 1:
		_expect("locate dated instance and metric in the real archive", false)
		_finish_contract()
		return
	var remove_count := first_metric + METRIC_BYTES
	_expect("all four pending queues were written", bytes.decode_u32(remove_count) == 1
		and bytes.decode_u32(remove_count + 4 + 28) == 1)
	_expect("current envelope makes v5 readers refuse before interpreting queues",
		bytes.decode_u32(4) == 6 and saved.bundle_version == 6)
	for bad in [[-1, 1], [count, 1], [0, -1]]:
		var invalid := metric.duplicate()
		invalid.metric_id = bad[0]
		invalid.revision = bad[1]
		_expect("invalid metric rejected at intake %s" % [bad], not ext.queue_effect_pod_metric(invalid).ok)
	await _stop(ext)
	var cold := DCWorldExt.new()
	var without_catalog := cold.restore_runtime_bundle(bytes)
	_expect("restore requires the matching catalog to interpret both Effect sections",
		not without_catalog.ok and without_catalog.code == "effect_pod_save_header_invalid")
	var target := DCWorldExt.new()
	_expect("target catalog configured", target.configure_effects(columns).get("effect_pod_ready", false))
	_expect("current envelope validates", Header.valid(bytes) and target.restore_runtime_bundle(bytes).ok)
	for version in [5, 6]:
		for bad in [[-1, 1], [count, 1], [0, -1]]:
			var broken := bytes.duplicate()
			broken.encode_u32(4, version)
			broken.encode_s32(first_metric + 20, bad[0])
			broken.encode_s64(first_metric + 24, bad[1])
			_sign(broken)
			var verdict := target.restore_runtime_bundle(broken)
			print("ETQ_METRIC version=%d id=%d revision=%d code=%s" % [version, bad[0], bad[1], verdict.code])
			_expect("malformed metric rejected by the transport decoder",
				not verdict.ok and verdict.code == "effect_transport_continuation_invalid")
	# Binding and retirement ordinals share one counter and order one identity.
	for pair in [[0, 2], [1, 1], [1, 3]]:
		var broken := bytes.duplicate()
		broken.encode_u64(start + 24, pair[0])
		broken.encode_u64(remove_count + 12, pair[1])
		_sign(broken)
		var verdict := target.restore_runtime_bundle(broken)
		_expect("invalid pending ordinals refused %s" % [pair],
			not verdict.ok and verdict.code == "effect_transport_continuation_invalid")
	_expect("valid pending archive survives all refusals", target.start_runtime_worker(config).get("ok", false))
	var resumed := await _save(target, 902)
	_expect("all pending rows retain their bytes", resumed.get("bytes", PackedByteArray()).slice(start, -8)
		== bytes.slice(start, -8))
	await _stop(target)
	var exhausted := bytes.duplicate()
	exhausted.encode_u64(start + 4, -1)
	_sign(exhausted)
	_expect("exhausted transport cursor loads", target.restore_runtime_bundle(exhausted).ok
		and target.start_runtime_worker(config).ok)
	var other := input.duplicate()
	other.instance_id = 719
	var bind_result := target.queue_effect_pod_instance(other)
	var retire_result := target.queue_effect_pod_remove(719, 1)
	_expect("exhausted cursor refuses both allocations without wrapping",
		not bind_result.ok and not retire_result.ok)
	await _stop(target)
	for legacy in [false, true]:
		var old := bytes.duplicate()
		old.encode_u32(4, 5)
		if legacy:
			old.encode_u32(start, ETQ1)
			for date_offset in [remove_count + 4, first_metric, start + 16]:
				old = old.slice(0, date_offset) + old.slice(date_offset + 8)
		_sign(old)
		_expect("PKSR v5 header and native decoder accept the historical queues",
			Header.valid(old) and target.restore_runtime_bundle(old).ok)
		_expect("historical queues install", target.start_runtime_worker(config).get("ok", false))
		var again := await _save(target, 903)
		var expected := bytes.slice(start, -8)
		if legacy:
			for date_offset in [remove_count + 4, first_metric, start + 16]:
				expected.encode_s64(date_offset - start, 0)
		_expect("legacy rows retain their payloads when resaved", again.bytes.slice(start, -8) == expected)
		await _stop(target)
	# Repeating an existing binding keeps its owner's latch. A separate
	# instance between the two submissions cannot change that outcome.
	var reference := await _bound_state(columns, [17, 41], [0, 0])
	var reversed := await _bound_state(columns, [41, 17], [0, 0])
	var adjacent := await _bound_state(columns, [17, 17, 41], [0, 1, 0])
	var between := await _bound_state(columns, [17, 41, 17], [0, 0, 1])
	_expect("independent registration does not change a repeated binding or its saved state",
		not reference.is_empty() and adjacent.get("applied") == reference.get("applied")
		and between.get("applied") == reference.get("applied"))
	_expect("unopened requests save identically across independent permutations",
		not reference.is_empty() and reversed == reference and adjacent.get("pending") == between.get("pending"))
	_finish_contract()

func _bound_state(columns: Dictionary, ids: Array, latches: Array) -> Dictionary:
	var host := DCWorldExt.new()
	var modifier := ModifierFacade.new()
	_expect("order fixture configures Modifier", modifier.configure(host, 1).get("modifier_pod_ready", false))
	_expect("order fixture configures Effect", host.configure_effects(columns).ok)
	_expect("order fixture starts", host.start_runtime_worker(_config(true, 0x841)).ok)
	# Drive the same production ingress as a domain that already owns Effect.
	host.set_effect_forwarder_authority_for_test(1)
	for i in ids.size():
		var result := host.submit_effect_instances({"instance_ids": PackedInt64Array([ids[i]]),
			"program_keys": PackedStringArray(["technology.tech.animal_husbandry"]),
			"generations": PackedInt32Array([1]), "source_types": PackedInt32Array([0x54454348]),
			"source_ids": PackedInt64Array([ids[i]]), "source_handles": PackedInt64Array([1]),
			"target_handles": PackedInt64Array([1]), "target_generations": PackedInt32Array([1]),
			"levels": PackedInt32Array([1]), "next_due_days": PackedInt64Array([77]),
			"active": PackedByteArray([1]), "latched": PackedByteArray([latches[i]])})
		_expect("binding accepted", result.ok and result.get("instance_ids") == PackedInt64Array([ids[i]]))
	var unopened := await _save(host, 909)
	var pending_bytes: PackedByteArray = unopened.bytes
	var tail := _transport_offset(pending_bytes)
	_expect("pending Effect transport present", tail >= 0 and pending_bytes.decode_u32(tail) == ETQ2)
	await _day(host, true, 1)
	var saved := await _save(host, 910)
	await _stop(host)
	var bytes: PackedByteArray = saved.bytes
	var marker := "EFP1".to_ascii_buffer()
	for pos in range(0, bytes.size() - 12):
		if bytes[pos] == marker[0] and bytes.slice(pos, pos + 4) == marker and bytes.slice(pos + 8, pos + 12) == marker:
			var section := bytes.slice(pos + 8, pos + 8 + bytes.decode_u32(pos + 4))
			print("EFFECT_BINDINGS ids=%s EFP1=%s" % [ids, section.hex_encode().sha256_text()])
			return {"applied": section, "pending": pending_bytes.slice(tail, -8)}
	return {}

func _transport_offset(bytes: PackedByteArray) -> int:
	var offset := bytes.rfind(0x45, bytes.size() - 9)
	while offset >= 0:
		if offset + 4 <= bytes.size() and bytes.decode_u32(offset) == ETQ2:
			return offset
		if offset == 0:
			break
		offset = bytes.rfind(0x45, offset - 1)
	return -1

func _sign(bytes: PackedByteArray) -> void:
	var hash := 1469598103934665603
	for byte in bytes.slice(0, -8):
		hash = (hash ^ byte) * 1099511628211
	bytes.encode_u64(bytes.size() - 8, hash)

func _finish_contract() -> void:
	print("Effect transport save: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)
