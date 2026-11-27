extends "res://tests/runtime/background_daily_self_sufficiency_test.gd"

const LOW := 1
const HIGH := (1 << 24) + LOW


func _background_config() -> NewGameConfig:
	var config := super._background_config()
	config.country.foreign_count = 1
	return config


func _run() -> void:
	# Two equivalent policies: a national low amount with one local exception,
	# and the same amounts expressed entirely as local defaults.
	var control := await _run_world(false)
	var local := await _run_world(true)
	_expect("both configurations settle", not control.is_empty() and not local.is_empty())
	if not control.is_empty() and not local.is_empty():
		_expect("each occupied cell pays the same income tax under equivalent policies",
			control.paid == local.paid)
		_expect("the country receives the same income tax under equivalent policies",
			control.collected == local.collected)
	print("occupied cell tax settlement: %d checks, %d failures" % [_checks, _failures])
	call_deferred("quit", int(_failures != 0))


func _sample_world(host: WorldRuntimeHost, clock: WorldClock, both_local: bool) -> Dictionary:
	var generator := host.get_generator()
	var country = generator.get_country_facade()
	var economy = generator.get_economy_facade()
	var start := generator.gameplay_start_report()
	var capital := int(start.cell)
	var second := int(start.foreign_cells[0])
	var player := int(country.cell_summary(capital).country_handle)
	var other := int(country.cell_summary(second).country_handle)
	var cells := [capital, second]
	var report: Dictionary = generator.get_runtime_thread_report()
	_expect("two independent capitals start on the full worker",
		capital != second and player != other and player != 0 and other != 0
		and report.get("whole_graph_requested", false) and not report.get("native_daily_inline", true))
	clock.pause(false)
	var transfer: Dictionary = country.transfer_territory(second, player, 1, 76401, true)
	_expect("the populated cell transfer is admitted on D1", transfer.get("effective_day") == 1)
	for cell: int in cells:
		economy.population_cell_snapshot(cell)
	country.fiscal_snapshot(player)
	_publish_day(host, clock, 1)
	if not await _wait_golden_read_boundary(host, economy, 1):
		return {}
	for cell: int in cells:
		var opening := await _published_economy(func(): return economy.population_cell_snapshot(cell), 1)
		_expect("both cells belong to the player and have residents before the tax",
			country.cell_summary(cell).get("country_handle") == player and opening.get("population", 0) > 0)
	var before := await _published_economy(func(): return country.fiscal_snapshot(player), 1)
	if before.is_empty():
		return {}
	var lower: Dictionary
	if both_local:
		lower = country.set_cell_tax_default_basis_points(player, capital, 0, LOW, 2, 76402, 1)
	else:
		lower = country.set_tax_default_basis_points(player, 0, LOW, 2, 76402, 1)
	var higher: Dictionary = country.set_cell_tax_default_basis_points(player, second, 0, HIGH, 2, 76403, 1)
	_expect("both absolute income tax amounts are admitted for D2",
		lower.get("effective_day") == 2 and higher.get("effective_day") == 2)
	_publish_day(host, clock, 2)
	if not await _wait_golden_read_boundary(host, economy, 2):
		return {}
	var paid := PackedInt64Array()
	for cell: int in cells:
		var pop := await _published_economy(func(): return economy.population_cell_snapshot(cell), 2)
		if pop.is_empty():
			return {}
		var total := 0
		for amount in pop.epoch_tax_paid_by_cohort:
			total += amount
		paid.append(total)
	var fiscal := await _published_economy(func(): return country.fiscal_snapshot(player), 2)
	if fiscal.is_empty():
		return {}
	var collected := int(fiscal.cumulative_collected[0]) - int(before.cumulative_collected[0])
	print("D2 both_local=%s cells=%s paid=%s country_collected=%d" % [both_local, cells, paid, collected])
	_expect("the income tax actually received equals the two populated cells' payments",
		paid[0] > 0 and paid[1] > 0 and paid[0] + paid[1] == collected)
	if not both_local:
		_expect("the high fixed charge collects more than the low charge", paid[1] > paid[0])
	return {"paid": paid, "collected": collected}
