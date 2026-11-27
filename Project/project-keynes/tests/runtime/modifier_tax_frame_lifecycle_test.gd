extends "res://tests/runtime/modifier_tax_frame_test.gd"

class LifecycleHost extends TaxHost:
	func _prepare_world_restore() -> Dictionary:
		# 同一份测试目录在 PKSV 恢复 Modifier 各段之前就绪。
		_configure_tax_catalog()
		return super._prepare_world_restore()


func _create_host() -> WorldRuntimeHost:
	return LifecycleHost.new()


func _run() -> void:
	var temp_slots := DirAccess.create_temp("keynes-tax-frame-")
	_expect("private PKSV directory created", temp_slots != null)
	if temp_slots != null:
		var save = root.get_node("GameSave")
		save._repository = SaveRepository.new(temp_slots.get_current_dir())
		var result := await _run_world(false)
		_expect("new world replaced the loaded tax frame", result.get("done", false))
	print("modifier tax frame lifecycle: %d checks, %d failures" % [_checks, _failures])
	call_deferred("quit", int(_failures != 0))


func _sample_world(host: WorldRuntimeHost, clock: WorldClock, _stall: bool) -> Dictionary:
	var save = root.get_node("GameSave")
	save.bind_runtime(host, clock, null)
	var fixture := host as LifecycleHost
	var generator := host.get_generator()
	var ext: Object = generator.get_data_core_world_ext()
	var country = generator.get_country_facade()
	var economy = generator.get_economy_facade()
	var start: Dictionary = generator.gameplay_start_report()
	var cell := int(start.cell)
	var handle := int(country.cell_summary(cell).country_handle)
	root.get_node("GameFlow").set_session({"new_game_config": host.session_config(),
		"player_country_id": "country.player", "player_country_handle": handle,
		"start_cell": cell, "precious_resource": start.get("precious_resource", "")})
	clock.pause(false)
	for day in [1, 2]:
		if day == 2:
			_admit(ext, _apply_packet(fixture.definition_id, handle, FIRST_REQUEST, day))
		_publish_day(host, clock, day)
		if not await _wait_golden_read_boundary(host, economy, day):
			return {}
	clock.pause(true)
	# 夹具直接封存每日输入；存档仍使用游戏的时钟与提供方。
	clock.current_day = 2.0
	var frozen: Dictionary = ext.sample_effect_metric_probe(INCOME_TAX_MEAN_BP, cell, handle)
	_expect("D2 settlement sampled every profession at 1001 bp", frozen.get("ok") and frozen.value == 1001)
	var expected := _tax_rows(country, handle, cell)
	_check_inherited(expected, 1001, "D2 before save")
	var archive: Dictionary = await save.request_manual_save("manual_1")
	_expect("D2 PKSV written (%s)" % archive.get("code"), archive.get("ok", false))
	if not archive.get("ok", false):
		return {}
	var epoch := int(ext.get_country_worker_protocol_status().session_epoch)
	var restarted: Dictionary = host.restart_runtime_executor()
	_expect("same-world executor restarted", restarted.get("ok", false))
	_expect("restart retained the session and D2", ext.get_country_worker_protocol_status().session_epoch == epoch
		and ext.runtime_committed_day() == 2)
	_compare_frame(_tax_rows(country, handle, cell), expected, "D2 restart")

	# 同一 Host 关闭旧局并新建生成器、Country 和 C++ 世界；暂停至首帧读取完成。
	var load: Dictionary = host.configure_session({"kind": "load_game", "slot_id": "manual_1"})
	_expect("cold PKSV open accepted (%s)" % load.get("code"), load.get("ok", false))
	if not load.get("ok", false):
		return {}
	await host.generate_world()
	var restored := host.get_generator()
	if not host.is_runtime_ready_for_ticks():
		_expect("cold world reaches its saved display frame: %s" % str(host.last_world_generation_error), false)
		return {}
	var cold_ext: Object = restored.get_data_core_world_ext()
	_expect("cold first frame has a different C++ world at D2", cold_ext != ext
		and cold_ext.runtime_committed_day() == 2 and host._runtime_commit_day == 2)
	_compare_frame(_tax_rows(restored.get_country_facade(), handle, cell), expected, "D2 cold PKSV")

	var config := _background_config()
	config.base.initial_seed += 1
	var fresh := host.configure_session({"kind": "new_game", "config": config.to_dictionary()})
	if not fresh.get("ok", false):
		return {}
	clock.current_day = 37.0
	await host.generate_world()
	if not host.is_runtime_ready_for_ticks():
		return {}
	var other := host.get_generator()
	var other_country = other.get_country_facade()
	var other_cell := int(other.gameplay_start_report().cell)
	var other_handle := int(other_country.cell_summary(other_cell).country_handle)
	_expect("new world opens with a fresh C++ owner on calendar day 37", other.get_data_core_world_ext() != cold_ext
		and other.get_data_core_world_ext().runtime_committed_day() == 37)
	var new_rows := _tax_rows(other_country, other_handle, other_cell)
	_check_inherited(new_rows, 0, "new world opening at D37")
	return {"done": true}


func _compare_frame(actual: Dictionary, expected: Dictionary, label: String) -> void:
	for key in ["national", "local", "panel"]:
		# 元数据的目录/环境代次随恢复过程变化；界面消费的全部税行应逐字段相同。
		for kind in ["income", "consumption", "business", "import", "export"]:
			var row: Dictionary = actual.get(key, {}).get(kind, {})
			var saved: Dictionary = expected.get(key, {}).get(kind, {})
			if row != saved:
				var changed := PackedStringArray()
				for field in saved:
					if saved[field] != row.get(field):
						changed.append(field)
				print("TAX_LIFECYCLE_DIFF ", label, " ", key, ".", kind, " ", changed)
			_expect("%s %s %s matches every saved field" % [label, key, kind],
				not row.is_empty() and row == saved)
	if not actual.is_empty():
		print("TAX_LIFECYCLE ", label, " national_bp=", actual.national.income.effective_rates_basis_points[0],
			" cell_bp=", actual.local.income.effective_rates_basis_points[0],
			" panel_bp=", actual.panel.income.effective_rates_basis_points[0])
