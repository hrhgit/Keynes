extends "res://tests/runtime/runtime_inline_save_restore_test.gd"

# INPUT_CAPTURE waits for an explicit frame. With Climate outside the grant,
# Modifier can finish before that frame arrives.
const MASK := 0x841
const SAVE_ID := 416

func _run() -> void:
	var ext := DCWorldExt.new()
	var modifier := ModifierFacade.new()
	_expect("configure Modifier", modifier.configure(ext, 1).get("modifier_pod_ready", false))
	_expect("start partial worker", ext.start_runtime_worker(_config(false, MASK)).get("ok", false))
	ext.set_runtime_clock(false, 30)
	var report: Dictionary = ext.get_runtime_thread_report()
	while report.get("day_wait_missing_mask", 0) == 0 and ext.runtime_committed_day() == 0 \
			and report.get("state", "") != "FAULTED":
		await process_frame
		report = ext.get_runtime_thread_report()
	_expect("input is missing on day one", report.get("day_wait_day", -1) == 1 and report.get("day_wait_env_day", 0) == -1
		and (int(report.get("day_wait_missing_mask", 0)) & 1) != 0)
	_expect("Modifier completed while the whole day waits", ext.runtime_committed_day() == 0
		and (int(report.get("day_wait_missing_mask", MASK)) & 0x40) == 0)
	_expect("save admitted", ext.request_runtime_save(SAVE_ID).get("ok", false))
	# The worker acknowledges pause on its next outer loop, after the save
	# service point. No wall-clock delay is needed to test non-publication.
	ext.set_runtime_clock(true, 30)
	while ext.get_runtime_control_state().get("state", "") != "PAUSED":
		await process_frame
	var saved: Dictionary = ext.poll_runtime_save(SAVE_ID)
	print("PARTIAL_SAVE host_day=%d missing=%s ready=%s archive_day=%s modifier_bytes=%s" % [
		ext.runtime_committed_day(), report.get("day_wait_missing_mask"), saved.get("ready", false),
		saved.get("committed_day", -1), saved.get("modifier_bytes", 0)])
	_expect("save waits for the entire day", saved.get("pending", false) and not saved.get("ready", false))
	if saved.get("pending", false):
		var captured: Dictionary = ext.capture_runtime_inputs({"day": 1, "generation": 1,
			"terrain": PackedByteArray([1]), "landform": PackedByteArray([0]),
			"has_river": PackedByteArray([0]), "neighbor_indices": PackedInt32Array([-1, -1, -1, -1, -1, -1])})
		_expect("missing input supplied", captured.get("ok", false))
		var deadline := Time.get_ticks_msec() + 3000
		while saved.get("pending", false) and Time.get_ticks_msec() < deadline:
			await process_frame
			saved = ext.poll_runtime_save(SAVE_ID)
		print("PAUSED_SAVE host_day=%d state=%s ready=%s pending=%s archive_day=%s archive_paused=%s" % [
			ext.runtime_committed_day(), ext.get_runtime_control_state().get("state"), saved.get("ready", false),
			saved.get("pending", false), saved.get("committed_day", -1), saved.get("paused", false)])
		_expect("same save releases at day one with Modifier", saved.get("ready", false)
			and saved.get("committed_day", -1) == 1 and int(saved.get("modifier_bytes", 0)) > 0)
		_expect("saving preserves the pause and opens no new day", saved.get("paused", false)
			and ext.runtime_committed_day() == 1
			and not ext.get_runtime_thread_report().get("inline_day_pending", true))
	if saved.get("ready", false):
		var reader := DCWorldExt.new()
		_expect("configure restore target", ModifierFacade.new().configure(reader, 1).get("ok", false))
		_expect("decode delivered archive", reader.restore_runtime_bundle(saved.bytes).get("restored", false))
		_expect("open saved world paused", reader.start_runtime_worker(_config(true, MASK)).get("ok", false))
		var decoded: Dictionary = reader.get_runtime_modifier_snapshot(-1)
		print("PARTIAL_RESTORE archive_day=%s modifier_day=%s" % [saved.committed_day, decoded.get("committed_day")])
		_expect("archive and restored Modifier both describe the completed day",
			saved.committed_day == 1 and decoded.get("committed_day", -1) == saved.committed_day)
		await _stop(reader)
	await _stop(ext)
	await _future_climate_input()
	print("partial worker save boundary: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)

func _future_climate_input() -> void:
	var ext := DCWorldExt.new()
	# A diagnostic caller can seed D2 before the Climate authority starts.
	var captured := ext.capture_runtime_inputs({"day": 2, "generation": 1,
		"terrain": PackedByteArray([1]), "landform": PackedByteArray([0]),
		"has_river": PackedByteArray([0]), "neighbor_indices": PackedInt32Array([-1, -1, -1, -1, -1, -1])})
	_expect("future opening frame captured", captured.get("ok", false))
	var config := _config(false)
	config.paused = false
	config.speed_days_per_second = 1.0
	_expect("bare Climate worker starts at D0", ext.start_runtime_worker(config).get("ok", false))
	var report := ext.get_runtime_thread_report()
	while not report.get("inline_day_pending", false) and report.get("worker_time_environment_wait_us", 0) == 0 \
			and report.get("state") != "FAULTED":
		await process_frame
		report = ext.get_runtime_thread_report()
	_expect("future input stays queued while the worker waits for D1", not report.get("inline_day_pending", true)
		and report.get("environment_ring_pending") == 1 and report.get("environment_consumed_days", -1) == 0)
	var saved := await _save(ext, SAVE_ID + 1)
	_expect("D0 save discards the queued future and reopens D1", saved.get("ready", false)
		and saved.get("committed_day") == 0 and ext.runtime_next_environment_day() == 1
		and ext.get_runtime_thread_report().get("environment_ring_pending") == 0)
	if saved.get("ready", false):
		await _day(ext, false, 1)
	await _stop(ext)
