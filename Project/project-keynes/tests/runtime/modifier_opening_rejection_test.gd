extends "res://tests/runtime/runtime_inline_save_restore_test.gd"

func _run() -> void:
	var source := DCWorldExt.new()
	_expect("partial world starts", source.start_runtime_worker(_config(true)).get("ok", false))
	await _day(source, true, 1)
	_expect("D2 command accepted", source.submit_runtime_command({"request_id": 1711,
		"producer_id": 2, "requested_day": 2, "domain": 1, "opcode": 1}).get("pending", false))
	var saved := await _save(source, 1701)
	await _stop(source)
	_expect("partial D1 archive has no committed Modifier", saved.get("ready", false)
		and saved.get("committed_day", -1) == 1 and saved.get("modifier_bytes", -1) == 0)
	var bytes: PackedByteArray = saved.get("bytes", PackedByteArray())
	for inline_mode in [false, true]:
		await _reject_opening(bytes, inline_mode)
	print("modifier opening rejection: %d checks, %d failures" % [checks, failures])
	quit(int(failures != 0))

func _reject_opening(bytes: PackedByteArray, inline_mode: bool) -> void:
	var target := DCWorldExt.new()
	target.create_entities(2)
	var catalog: Dictionary = ModifierCatalog.load_default().compile_native_catalog()
	_expect("target Modifier configures", target.configure_modifiers(catalog, 2).get("modifier_pod_ready", false))
	var country := preload("res://scripts/country/country_facade.gd").new()
	_expect("target Country configures",
		country.configure(target, 2, 7321, null, {}, null, catalog).get("ok", false))
	_expect("target Country bootstraps", country.bootstrap(PackedByteArray([0, 0])).get("ok", false))
	_expect("target Country catalog captured", target.capture_country_pod_catalog().get("ok", false))
	_expect("target Country snapshot captured", target.capture_country_runtime_snapshot().get("ok", false))
	_expect("partial archive decodes", target.restore_runtime_bundle(bytes).get("ok", false))

	# This archive has a committed D1, but no D1 Modifier. The full world demands
	# a matching opening view, in both worker and caller-driven execution modes.
	var started := target.start_runtime_worker(_config(inline_mode, 0xfff))
	var report := target.get_runtime_thread_report()
	print("opening rejection inline=%s code=%s state=%s exited=%s grant=%s" % [
		inline_mode, started.get("code"), report.get("simulation_host_state"),
		report.get("simulation_executor_exited"), report.get("authoritative_domain_mask")])
	_expect("mismatched opening rejected", not started.get("ok", true)
		and started.get("code") == "modifier_opening_frame_invalid")
	_expect("rejection leaves executor stopped", report.get("simulation_host_state") == "STOPPED"
		and report.get("simulation_executor_exited", false))
	_expect("rejection releases simulation authority", report.get("authoritative_domain_mask", -1) == 0)
	var compatible := target.start_runtime_worker(_config(inline_mode))
	_expect("archive can open immediately with its original authority", compatible.get("ok", false))
	if compatible.get("ok", false):
		var resumed := target.get_runtime_thread_report()
		_expect("compatible start retained D1 and the pending D2 command",
			resumed.get("simulation_committed_day", -1) == 1 and resumed.get("economy_pending_command_count", -1) == 1)
	await _stop(target)
