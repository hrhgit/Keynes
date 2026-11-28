extends "res://tests/game/player_scene_handoff_probe.gd"

const EVENT_TYPE := GameplayEventBus.EVENT_VISUAL_DIRTY_INTENT
const MARKER := 924000
var _failures := PackedStringArray()


func _run() -> void:
	var config := NewGameConfig.create_default()
	config.base.initial_seed = SEED
	config.base.map_width = WIDTH
	config.base.map_height = HEIGHT
	var started := await _start_player_scene(root.get_node("GameFlow"), config)
	_check(started.get("ok", false), "PlayerGame starts: %s" % started)
	if started.get("ok", false):
		_host = _player_host()
		_generator = _host.get_generator()
		_clock = current_scene.get_node("WorldClock")
		_clock.set_process(false)
		_clock.pause(false)
		_check(not _host.runtime_events_probe_enabled, "uses the default Events diagnostics setting")
		if await _advance_day(1):
			await _check_restart()
		_check((await _host.close_world()).get("ok", false), "world closes")
	for failure in _failures:
		printerr(failure)
	print("PLAYER_EVENTS_RESTART failures=", _failures.size())
	quit(int(not _failures.is_empty()))


func _check_restart() -> void:
	var ext: DCWorldExt = _generator.get_data_core_world_ext()
	var bus: GameplayEventBus = _generator.get_gameplay_event_bus()
	for day in [2, 3]:
		if day == 3:
			_clock.pause(true)
			var restart := _host.restart_runtime_executor()
			_check(restart.get("ok", false) and ext.runtime_committed_day() == 2,
				"same-world executor resumes at D2")
			if not restart.get("ok", false):
				return
			_clock.pause(false)
		var report: Dictionary = ext.get_runtime_thread_report()
		_check(report.get("authoritative_domain_mask") == 0xfff, "D%d has full authority" % day)
		var append: Dictionary = bus.publish_events_batch({"count": 1, "type_scalar": EVENT_TYPE,
			"tick_scalar": day, "value_i64": PackedInt64Array([MARKER + day])})
		_check(append.get("ok", false) and append.get("events_bridge_queued") == 1,
			"D%d event admitted" % day)
		if not await _advance_day(day):
			return
		var events: Dictionary = bus.poll_events(&"restart_journal_test", 0, EVENT_TYPE, false, 0)
		var values: PackedInt64Array = events.get("value_i64", PackedInt64Array())
		_check(events.get("authority_source") == "runtime_events_worker"
			and events.get("committed_day") == day, "worker journal reaches D%d" % day)
		for sent_day in range(2, day + 1):
			var row := values.find(MARKER + sent_day)
			_check(values.count(MARKER + sent_day) == 1 and row >= 0
				and events.tick[row] == sent_day, "D%d journal retains the D%d event exactly once" % [day, sent_day])
		print("PLAYER_EVENTS_RESTART world_day=%d journal_day=%d events_enabled=%s marker_D2=%d marker_D3=%d" % [
			ext.runtime_committed_day(), events.get("committed_day", -1), report.get("events_probe_enabled"),
			values.count(MARKER + 2), values.count(MARKER + 3)])


func _advance_day(day: int) -> bool:
	if _host._admit_runtime_calendar(day + 1) != day:
		_check(false, "calendar declined D%d" % day)
		return false
	while _host.received_worker_day() < day:
		if _host.is_runtime_fault_paused():
			_check(false, "world fault on D%d: %s" % [day, _host.get_runtime_fault_diagnostics()])
			return false
		await process_frame
	return true


func _check(ok: bool, label: String) -> void:
	if not ok:
		_failures.append(label)
