extends "res://tests/building/building_runtime_test.gd"

const BUILDINGS_DOMAIN := 1 << 5
const OWNED_DOMAIN := 1 << 17
const BUILDINGS_SECTION := 5
const OWNER_MOBILITY_BLOCK := 10
const FIXTURE_SEED := 297


func _run() -> void:
	var catalog := EconomyCatalogScript.compile_native_catalog()
	var profile: Dictionary = load("res://data/economy/default_economy.tres").to_native_profile()
	profile.market_runtime_mode = "ACTIVE"
	profile.economy_cadence_force_market_days = 5
	profile.economy_cadence_force_plan_days = 5
	profile.economy_cadence_force_investment_days = 10
	profile.startup_demand_runtime_mode = "OFF"
	profile.family_runtime_mode = "OFF"
	profile.investment_max_growth_share_q16 = 0
	var type_ids: PackedStringArray = catalog.building_type_ids
	var loom := type_ids.find("household_loom")
	var workshop := type_ids.find("knapping_workshop")
	_block_construction_except(catalog, PackedInt32Array(), _luxury_blocking_good(catalog))
	var signatures: PackedStringArray = catalog.signature_keys
	var artisan := signatures.find("artisan|default")
	var merchant := signatures.find("merchant|default")
	var stock := PackedInt64Array()
	stock.resize(catalog.good_ids.size() * 2)
	stock.fill(1_000_000)
	var source := _configured_world(catalog, profile)
	var boot: Dictionary = source.bootstrap_economy({
		"cell_indices": PackedInt32Array([0, 1, 1]),
		"signature_ids": PackedInt32Array([merchant, artisan, merchant]),
		"population": PackedInt64Array([1, 2, 1]),
		"funds": PackedInt64Array([100_000_000, 100_000_000, 100_000_000]),
	}, {
		"stock": stock,
		"building_cells": PackedInt32Array([0, 1, 1]),
		"building_type_ids": PackedInt32Array([loom, loom, workshop]),
		"building_owner_signature_ids": PackedInt32Array([artisan, artisan, artisan]),
		"building_counts": PackedInt64Array([1, 1, 1]),
		"building_owner_fill": PackedInt64Array([0, 1, 1]),
	})
	_expect("legacy building fixture bootstraps", bool(boot.get("ok", false)))
	if not bool(boot.get("ok", false)):
		return
	var opening := _run_day(source, 0)
	var vacant: Dictionary = source.get_building_cell_snapshot(0)
	_expect("legacy row initially contains a vacant building",
		bool(opening.get("done", false)) and not bool(opening.get("fatal", false))
		and _snapshot_i64(vacant, "group_counts", 0) == 1
		and _snapshot_i64(vacant, "filled_owner", 0) == 0)
	var captured: Dictionary = source.capture_economy_ecp2(0)
	_expect("source reaches a save boundary", bool(captured.get("ok", false)))
	if not bool(captured.get("ok", false)):
		return
	var legacy := _legacy_archive(captured.bytes)
	_expect("legacy archive encodes a zero group before two live groups", not legacy.is_empty())
	if legacy.is_empty():
		return
	var restored := _configured_world(catalog, profile)
	var restore: Dictionary = restored.restore_economy_ecp2(legacy)
	_expect("legacy archive with a zero group is accepted", bool(restore.get("ok", false)))
	if not bool(restore.get("ok", false)):
		print("legacy restore reason: ", restore.get("reason"))
		return
	var recaptured: Dictionary = restored.capture_economy_ecp2(0)
	var cooldown := _mobility_payload(recaptured.get("bytes", PackedByteArray()))
	_expect("recapture keeps the live pair under its new row numbers and drops stale rows",
		cooldown.size() == 24 and cooldown.decode_u32(0) == 1
		and cooldown.decode_s32(4) == 1 and cooldown.decode_s32(8) == 0
		and cooldown.decode_s32(12) == 1 and cooldown.decode_s64(16) == 200)
	var reloaded := _configured_world(catalog, profile)
	var reload: Dictionary = reloaded.restore_economy_ecp2(recaptured.get("bytes", PackedByteArray()))
	_expect("the normalized archive can be restored", bool(reload.get("ok", false)))
	if not bool(reload.get("ok", false)):
		return
	# Cell 1's market and planning bucket is due on simulation day 1.
	var resumed := _run_due_day(restored)
	var remaining: Dictionary = restored.get_building_cell_snapshot(1)
	print("legacy continuation: fatal=%s reason=%s live_rows=%s" % [
		resumed.get("fatal"), resumed.get("reason"), remaining.get("group_type_ids")])
	_expect("next settlement reaches the real buildings rather than the removed row",
		bool(resumed.get("done", false)) and not bool(resumed.get("fatal", false))
		and remaining.get("group_counts") == PackedInt64Array([1, 1])
		and int(resumed.get("population_error", 1)) == 0
		and int(resumed.get("money_error", 1)) == 0
		and int(resumed.get("goods_error", 1)) == 0)
	var replay := _run_due_day(reloaded)
	_expect("recaptured rows continue the same day with the same economy hash",
		bool(replay.get("done", false)) and not bool(replay.get("fatal", false))
		and restored.get_economy_state_hash() == reloaded.get_economy_state_hash())
	print("building tombstone restore: %d failures" % failures)


func _run_due_day(ext: Object) -> Dictionary:
	var report: Dictionary = ext.run_economy_slice({"day_index": 1})
	while not bool(report.get("done", false)) and not bool(report.get("fatal", false)):
		report = ext.run_economy_slice({"day_index": 1})
	return report


func _configured_world(catalog: Dictionary, profile: Dictionary) -> Object:
	var ext := _new_ext(catalog, 2)
	_expect("legacy building fixture configures country and economy",
		CountryTestHelper.configure_all_technologies(ext, catalog, 2, FIXTURE_SEED)
		and bool(ext.configure_economy(catalog, profile, 2, FIXTURE_SEED).get("ok", false)))
	return ext


func _domain_offset(wire: PackedByteArray, domain: int) -> int:
	if wire.size() < 28 or wire.decode_u32(0) != 0x32504345:
		return -1
	var cursor := 28 + wire.decode_u32(24)
	while cursor + 8 <= wire.size():
		if wire.decode_u32(cursor) == domain:
			return cursor
		cursor += 8 + wire.decode_u32(cursor + 4)
	return -1


func _mobility_offset(wire: PackedByteArray, owned: int) -> int:
	if owned < 0:
		return -1
	var cursor := owned + 8 + 40
	var end := owned + 8 + wire.decode_u32(owned + 4)
	while cursor + 8 <= end:
		if wire.decode_u32(cursor) == OWNER_MOBILITY_BLOCK:
			return cursor
		cursor += 8 + wire.decode_u32(cursor + 4)
	return -1


func _mobility_payload(wire: PackedByteArray) -> PackedByteArray:
	var block := _mobility_offset(wire, _domain_offset(wire, OWNED_DOMAIN))
	if block < 0:
		return PackedByteArray()
	return wire.slice(block + 8, block + 8 + wire.decode_u32(block + 4))


func _legacy_archive(wire: PackedByteArray) -> PackedByteArray:
	var groups := _domain_offset(wire, BUILDINGS_DOMAIN) + 8
	var owned := _domain_offset(wire, OWNED_DOMAIN)
	var mobility := _mobility_offset(wire, owned)
	if groups < 8 or mobility < 0 or wire.decode_u16(groups + 6) != BUILDINGS_SECTION:
		return PackedByteArray()
	var legacy := wire.duplicate()
	# Both building records begin with cell, type, owner signature, then count.
	var first_pkec_row := groups + 16
	var owned_building_block := owned + 8 + 40
	var first_owned_row := owned_building_block + 8
	if legacy.decode_u32(owned_building_block) != 1 or \
			legacy.decode_s32(first_pkec_row) != 0 or legacy.decode_s32(first_owned_row) != 0 or \
			legacy.decode_s64(first_pkec_row + 12) != 1 or legacy.decode_s64(first_owned_row + 12) != 1:
		return PackedByteArray()
	legacy.encode_s64(first_pkec_row + 12, 0)
	legacy.encode_s64(first_owned_row + 12, 0)
	var end := mobility + 8 + legacy.decode_u32(mobility + 4)
	# The legacy wire stored row positions. Row 0 is gone, rows 1 and 2 survive.
	var pairs := PackedByteArray()
	pairs.resize(44)
	pairs.encode_u32(0, 2)
	pairs.encode_s32(4, 1)
	pairs.encode_s32(8, 1)
	pairs.encode_s32(12, 2)
	pairs.encode_s64(16, 200)
	pairs.encode_s32(24, 1)
	pairs.encode_s32(28, 0)
	pairs.encode_s32(32, 2)
	pairs.encode_s64(36, 300)
	var rebuilt := legacy.slice(0, mobility + 8)
	rebuilt.encode_u32(mobility + 4, pairs.size())
	rebuilt.append_array(pairs)
	rebuilt.append_array(legacy.slice(end))
	var owned_size := legacy.decode_u32(owned + 4) + rebuilt.size() - legacy.size()
	rebuilt.encode_u32(owned + 4, owned_size)
	rebuilt.encode_s64(owned + 40, _wire_hash(rebuilt.slice(owned + 48, owned + 8 + owned_size)))
	rebuilt.encode_s64(16, _wire_hash(rebuilt.slice(24)))
	return rebuilt


func _wire_hash(bytes: PackedByteArray) -> int:
	var value := 1469598103934665603
	for byte in bytes:
		value = (value ^ byte) * 1099511628211
	return value
