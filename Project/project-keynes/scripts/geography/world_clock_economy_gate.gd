extends RefCounted

## Holds the displayed date when it outruns the economy's committed day.

## 经济闸门去抖：连续这么多个心跳（5 秒/次）都超限才真的停。去抖会放行第一个心跳，
## 因此实际出现的最大滞后 = bound + 一个心跳的推进量（10x 下约 +50 天），
## 不是 bound 本身。验收别拿 bound 当最大滞后。
const _ECO_GATE_TRIP_HEARTBEATS: int = 2
const _ECO_GATE_LOG_MS: int = 5000

var _economy_settled_day: int = -1            # newest_state_day；-1 = 尚未喂入
var _eco_settled_day_last_msec: int = 0       # 仅诊断：eco_day 最后一次前进的时刻
var _eco_gate_blocked: bool = false           # 闸门已闭（去抖之后）
var _eco_gate_over_count: int = 0             # 连续超限的心跳数
var _eco_gate_hold_start_msec: int = 0
var _eco_gate_last_log_msec: int = 0
var _eco_gate_trip_count: int = 0
var _last_display_day: int = -1
## GM 出口：真冻结时只放行不静默 —— 日志照打，并多一个 force_open=1。
var _eco_gate_force_open: bool = false


## 方案 A 的滞后上限（天）。依据盘上 12 份 11-19 跑批：1x 全程 gap ≤2；10x 峰值 40，
## 而 eco_day 是 5 秒缓存、只会偏旧，10x 下陈旧量约 5×dps ≈ 50，故 10x 端要 ~90。
## 换算成「每倍速 10 天」：1x=20（下限）、10x=100、20x 封顶 200。
static func _eco_lag_bound(speed_multiplier: float) -> float:
	return clampf(maxf(speed_multiplier, 1.0) * 10.0, 20.0, 200.0)


## 每次心跳使用最近一帧发布的经济日结。实际日历继续跟随已提交日。
func observe(day: int, calendar_day: int, speed_multiplier: float) -> void:
	if day < 0:
		return
	var now := Time.get_ticks_msec()
	if day > _economy_settled_day:
		_economy_settled_day = day
		_eco_settled_day_last_msec = now
	var display_day := _last_display_day if _last_display_day >= 0 else calendar_day
	var over := float(display_day - _economy_settled_day) > _eco_lag_bound(speed_multiplier)
	if over:
		_eco_gate_over_count += 1
	else:
		_eco_gate_over_count = 0
	if over and not _eco_gate_blocked and _eco_gate_over_count >= _ECO_GATE_TRIP_HEARTBEATS:
		_eco_gate_blocked = true
		_eco_gate_trip_count += 1
		_eco_gate_hold_start_msec = now
		_eco_gate_last_log_msec = 0
	if _eco_gate_blocked and not over:
		_eco_gate_blocked = false
		_log_eco_gate(true, display_day, speed_multiplier)
	elif _eco_gate_blocked:
		_log_eco_gate(false, display_day, speed_multiplier)


## 开局和读档重置上一个世界的展示日期和经济日结。
func reset() -> void:
	_economy_settled_day = -1
	_eco_settled_day_last_msec = 0
	_eco_gate_blocked = false
	_eco_gate_over_count = 0
	_eco_gate_hold_start_msec = 0
	_eco_gate_last_log_msec = 0
	_last_display_day = -1


## GM 强制放行出口：只放行，不静默 —— 日志照打并带 force_open=1。
func set_force_open(enabled: bool) -> void:
	_eco_gate_force_open = enabled


func is_blocked() -> bool:
	return _eco_gate_blocked and not _eco_gate_force_open


func display_day(published_day: int) -> int:
	if not is_blocked() or _last_display_day < 0:
		_last_display_day = published_day
	return _last_display_day


func _log_eco_gate(recovered: bool, display_day: int, speed_multiplier: float) -> void:
	var now := Time.get_ticks_msec()
	if recovered:
		_eco_gate_last_log_msec = now
		print("[calendar/eco-gate] recovered day=%d eco_day=%d bound=%d held_ms=%d trips=%d" % [
			display_day, _economy_settled_day, int(_eco_lag_bound(speed_multiplier)),
			now - _eco_gate_hold_start_msec, _eco_gate_trip_count])
		return
	if _eco_gate_last_log_msec != 0 and now - _eco_gate_last_log_msec < _ECO_GATE_LOG_MS:
		return
	_eco_gate_last_log_msec = now
	var idle_ms := -1
	if _eco_settled_day_last_msec > 0:
		idle_ms = now - _eco_settled_day_last_msec
	print("[calendar/eco-gate] day=%d eco_day=%d bound=%d speed=%.2f held_days=%d held_ms=%d eco_idle_ms=%d over_heartbeats=%d trips=%d force_open=%d" % [
		display_day, _economy_settled_day, int(_eco_lag_bound(speed_multiplier)), speed_multiplier,
		display_day - _economy_settled_day, now - _eco_gate_hold_start_msec,
		idle_ms, _eco_gate_over_count, _eco_gate_trip_count,
		1 if _eco_gate_force_open else 0])
