extends "res://tests/runtime/modifier_tax_frame_test.gd"

class CatalogChangeHost extends TaxHost:
	var replace_catalog := false
	var replacement: Dictionary

	func _start_runtime_executor() -> void:
		if replace_catalog:
			# The previous executor has stopped, with an unclaimed day still in its queue.
			var ext: Object = _generator.get_data_core_world_ext()
			var original: Dictionary = _generator.get_modifier_facade().compiled_catalog()
			replacement = ext.configure_modifiers(original, get_current_map().cell_count())
		super._start_runtime_executor()


func _create_host() -> WorldRuntimeHost:
	return CatalogChangeHost.new()


func _run() -> void:
	var result := await _run_world(false)
	_expect("checked a mismatched publication", result.get("done", false))
	var batch := await _run_world(true)
	_expect("checked a mismatched publication with multiple days", batch.get("done", false))
	print("modifier tax frame rejection: %d checks, %d failures" % [_checks, _failures])
	call_deferred("quit", int(_failures != 0))


func _sample_world(host: WorldRuntimeHost, clock: WorldClock, hold_batch: bool) -> Dictionary:
	var fixture := host as CatalogChangeHost
	var generator := host.get_generator()
	var ext: Object = generator.get_data_core_world_ext()
	var country = generator.get_country_facade()
	var cell := int(generator.gameplay_start_report().cell)
	var handle := int(country.cell_summary(cell).country_handle)
	if hold_batch:
		# Normal speed admits one day ahead. Select the existing batch path.
		clock.set_speed(SPEED)
	clock.pause(false)
	_publish_day(host, clock, 1)
	if not await _wait_golden_read_boundary(host, generator.get_economy_facade(), 1):
		return {}
	var frame := _tax_rows(country, handle, cell)
	var cursor := int(host._runtime_last_commit.generation)
	_admit(ext, _apply_packet(fixture.definition_id, handle, FIRST_REQUEST, 2))
	if hold_batch:
		_admit(ext, _apply_packet(fixture.definition_id, handle, SECOND_REQUEST, 3))
	var held_day := 3 if hold_batch else 2
	var held := _run_hold(host, held_day)
	_expect("D%d is committed and unclaimed" % held_day,
		held.committed_after == held_day and held.display_after == 1)
	var settled: Dictionary = ext.sample_effect_metric_probe(INCOME_TAX_MEAN_BP, cell, handle)
	var expected_rate := 2001 if hold_batch else 1001
	_expect("D1 and D%d have distinguishable rates" % held_day, not frame.is_empty()
		and frame.national.income.effective_rates_basis_points[0] == 0 and settled.get("value") == expected_rate)
	fixture.replace_catalog = true
	var restart: Dictionary = host.restart_runtime_executor()
	_expect("changed the catalog at the stopped boundary and resumed the same world",
		restart.get("ok", false) and fixture.replacement.get("modifier_pod_ready", false))
	var result: Dictionary = ext.poll_runtime_commit(cursor, true)
	var days: Array = result.get("days", [])
	var expected_days := [2, 3] if hold_batch else [2]
	var request_ids := [FIRST_REQUEST, SECOND_REQUEST] if hold_batch else [FIRST_REQUEST]
	_expect("D%d is available to the display with all unclaimed days in order" % held_day,
		result.get("ok", false) and result.get("available", false) and result.get("committed_day") == held_day
		and days.map(func(record: Dictionary) -> int: return int(record.get("day", -1))) == expected_days)
	_expect("map updates, notices and command receipts stay in the publication",
		result.has_all(["display_dirty_cells", "display_class_cells", "notice_history", "receipts"]))
	for index in expected_days.size():
		var receipts: Array = days[index].get("receipts", []) if index < days.size() else []
		_expect("D%d retains its exact command receipt once" % expected_days[index],
			_has_command_receipt(receipts, request_ids[index], expected_days[index]))
	_expect("the latest publication also exposes the last day's command receipt",
		_has_command_receipt(result.get("receipts", []), request_ids.back(), held_day))
	_expect("D%d identifies the rejection and the retained day" % held_day,
		result.get("modifier_display_error") == "modifier_display_frame_invalid"
		and result.get("modifier_display_retained_day") == 1)
	_expect("the panel still follows the received D%d Country snapshot" % held_day,
		country.ui_snapshot(handle, held_day).get("published_day") == held_day)
	_expect("all three tax queries retain the accepted D1 frame", _tax_rows(country, handle, cell) == frame)
	var again: Dictionary = ext.poll_runtime_commit(cursor, true)
	_expect("the day is delivered once", again.get("ok", false) and again.get("pending", false))
	_expect("a repeated take replays neither daily records nor command receipts",
		not again.has("days") and not again.has("receipts"))
	return {"done": true}


func _has_command_receipt(receipts: Array, request_id: int, day: int) -> bool:
	var matches := receipts.filter(func(receipt: Dictionary) -> bool: return receipt.get("request_id") == request_id)
	return matches.size() == 1 and matches[0].get("producer_id") == 707 \
		and matches[0].get("sequence") == request_id and matches[0].get("effective_day") == day \
		and matches[0].get("code") == 0
