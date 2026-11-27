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
	print("modifier tax frame rejection: %d checks, %d failures" % [_checks, _failures])
	call_deferred("quit", int(_failures != 0))


func _sample_world(host: WorldRuntimeHost, clock: WorldClock, _stall: bool) -> Dictionary:
	var fixture := host as CatalogChangeHost
	var generator := host.get_generator()
	var ext: Object = generator.get_data_core_world_ext()
	var country = generator.get_country_facade()
	var cell := int(generator.gameplay_start_report().cell)
	var handle := int(country.cell_summary(cell).country_handle)
	clock.pause(false)
	_publish_day(host, clock, 1)
	if not await _wait_golden_read_boundary(host, generator.get_economy_facade(), 1):
		return {}
	var frame := _tax_rows(country, handle, cell)
	var cursor := int(host._runtime_last_commit.generation)
	_admit(ext, _apply_packet(fixture.definition_id, handle, FIRST_REQUEST, 2))
	var held := _run_hold(host, 2)
	_expect("D2 is committed and unclaimed", held.committed_after == 2 and held.display_after == 1)
	var settled: Dictionary = ext.sample_effect_metric_probe(INCOME_TAX_MEAN_BP, cell, handle)
	_expect("D1 and D2 have distinguishable rates", not frame.is_empty()
		and frame.national.income.effective_rates_basis_points[0] == 0 and settled.get("value") == 1001)
	fixture.replace_catalog = true
	var restart: Dictionary = host.restart_runtime_executor()
	_expect("changed the catalog at the stopped boundary and resumed the same world",
		restart.get("ok", false) and fixture.replacement.get("modifier_pod_ready", false))
	var result: Dictionary = ext.poll_runtime_commit(cursor, true)
	var days: Array = result.get("days", [])
	_expect("D2 is available to the display and retains its daily record",
		result.get("ok", false) and result.get("available", false) and result.get("committed_day") == 2
		and days.size() == 1 and days[0].day == 2)
	_expect("map updates, notices and command receipts stay in the publication",
		result.has_all(["display_dirty_cells", "display_class_cells", "notice_history", "receipts"]))
	_expect("D2 identifies the rejection and the retained day", result.get("modifier_display_error") == "modifier_display_frame_invalid"
		and result.get("modifier_display_retained_day") == 1)
	_expect("the panel still follows the received D2 Country snapshot", country.ui_snapshot(handle, 2).get("published_day") == 2)
	_expect("all three tax queries retain the accepted D1 frame", _tax_rows(country, handle, cell) == frame)
	var again: Dictionary = ext.poll_runtime_commit(cursor, true)
	_expect("the day is delivered once", again.get("ok", false) and again.get("pending", false))
	return {"done": true}
