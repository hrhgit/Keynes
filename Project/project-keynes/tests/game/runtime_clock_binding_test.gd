extends SceneTree

const Binding = preload("res://scripts/game/runtime_clock_binding.gd")
var calls: Array = []
var states: Array = []
var checks := 0
var failures := 0

func _init() -> void:
	var clock := WorldClock.new()
	var binding := Binding.new()
	clock.paused = true
	clock.speed_multiplier = 20.0
	binding.attach(clock, _apply, _running)
	_expect("attach replays state after executor creation", calls[-1] == [true, 20.0] and states[-1] == false)
	clock.paused = false
	_expect("direct pause changes reach executor without UI", calls[-1] == [false, 20.0] and states[-1])
	clock.pause(true)
	clock.set_speed(20.0)
	_expect("same speed resumes a paused executor", calls[-1] == [false, 20.0])
	clock.speed_multiplier = 0.0
	_expect("zero speed stops session admission", calls[-1] == [false, 0.0] and not states[-1])
	clock.latch_authority_fault_hold()
	clock.paused = false
	clock.set_speed(50.0)
	_expect("fault hold cannot be bypassed by direct assignment or speed", clock.paused and calls[-1] == [true, 50.0])
	var next := WorldClock.new()
	binding.attach(next, _apply, _running)
	var count := calls.size()
	clock.speed_multiplier = 10.0
	_expect("old clock cannot control a replacement session", calls.size() == count)
	binding.detach()
	count = calls.size()
	next.pause(true)
	_expect("closed session receives no clock commands", calls.size() == count)
	binding.attach(next, _apply, _running)
	next.free()
	binding.synchronize()
	binding.detach()
	_expect("scene destruction permits idempotent detach", true)
	clock.free()
	_test_economy_calendar_display_hold()
	if DisplayServer.get_name() == "headless":
		_test_fast_headless_sessions()
	print("runtime clock binding: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)

func _test_economy_calendar_display_hold() -> void:
	var clock := WorldClock.new()
	clock.speed_multiplier = 1.0
	clock.set_native_climate_calendar(true)
	var admitted: Array[int] = []
	clock.bind_runtime_calendar(func(day: int) -> int:
		admitted.append(day)
		return day)
	clock.publish_runtime_date(100)
	_expect("calendar starts at the published day", clock.economy_limited_display_day(101) == 101)
	_expect("an absent economy publication cannot trip the hold",
		not clock.set_economy_settled_day(-1) and not clock.is_economy_gate_blocked())
	var before_hold := clock.export_state()
	_expect("the first over-limit heartbeat does not hold the display",
		not clock.set_economy_settled_day(20) and not clock.is_economy_gate_blocked())
	_expect("the second over-limit heartbeat holds only the display",
		clock.set_economy_settled_day(20) and clock.is_economy_gate_blocked()
		and clock.export_state() == before_hold)
	clock.publish_runtime_date(102)
	clock._process_runtime_calendar(1.0)
	_expect("hold preserves the player date while publication, save and admission advance",
		clock.economy_limited_display_day(102) == 101 and clock.day_index() == 103
		and int(clock.export_state().last_day) == 103 and admitted.size() == 1)
	_expect("catch-up unholds the display without another simulation commit",
		clock.set_economy_settled_day(81) and clock.economy_limited_display_day(102) == 102
		and clock.day_index() == 103)
	clock.publish_runtime_date(161)
	clock.economy_limited_display_day(161)
	clock.set_economy_settled_day(81)
	clock.set_economy_settled_day(81)
	clock.set_economy_gate_force_open(true)
	_expect("GM force open bypasses the display hold",
		not clock.is_economy_gate_blocked() and clock.economy_limited_display_day(162) == 162)
	clock.set_economy_gate_force_open(false)
	var saved := clock.export_state()
	_expect("restore clears the old display hold",
		bool(clock.restore_state(saved).ok) and not clock.is_economy_gate_blocked()
		and clock.economy_limited_display_day(161) == 161 and clock.day_index() == 162)
	clock.free()

func _test_fast_headless_sessions() -> void:
	var original := OS.low_processor_usage_mode_sleep_usec
	OS.low_processor_usage_mode_sleep_usec = 8000
	var first := WorldClock.new()
	var second := WorldClock.new()
	var a := Binding.new()
	var b := Binding.new()
	first.set_speed(100.0)
	second.set_speed(200.0)
	a.attach(first, _apply, _running)
	var fast := OS.low_processor_usage_mode_sleep_usec
	_expect("a fast headless session services commits more frequently", fast > 0 and fast < 8000)
	first.pause(true)
	_expect("pausing restores the original engine sleep", OS.low_processor_usage_mode_sleep_usec == 8000)
	first.pause(false)
	b.attach(second, _apply, _running)
	a.detach()
	_expect("the other fast session still needs frequent service", OS.low_processor_usage_mode_sleep_usec == fast)
	second.set_speed(50.0)
	_expect("lower speed releases the last fast session", OS.low_processor_usage_mode_sleep_usec == 8000)
	second.set_speed(100.0)
	OS.low_processor_usage_mode_sleep_usec = 3200
	b.detach()
	_expect("detach respects a newer engine setting", OS.low_processor_usage_mode_sleep_usec == 3200)
	OS.low_processor_usage_mode_sleep_usec = 50
	a.attach(first, _apply, _running)
	_expect("an already shorter sleep is preserved", OS.low_processor_usage_mode_sleep_usec == 50)
	a.detach()
	OS.low_processor_usage_mode_sleep_usec = 8000
	a.attach(first, _apply, _running)
	first.free()
	a.synchronize()
	_expect("losing the clock releases its fast session", OS.low_processor_usage_mode_sleep_usec == 8000)
	b.attach(second, _apply, _running)
	b = null
	_expect("destroying an active binding restores the engine setting", OS.low_processor_usage_mode_sleep_usec == 8000)
	second.free()
	OS.low_processor_usage_mode_sleep_usec = original


func _apply(paused: bool, speed: float) -> void:
	calls.append([paused, speed])

func _running(running: bool) -> void:
	states.append(running)

func _expect(label: String, ok: bool) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error("[FAIL] " + label)
