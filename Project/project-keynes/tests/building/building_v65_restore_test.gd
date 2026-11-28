extends "res://tests/building/building_lifecycle_test.gd"

func _run() -> void:
	# Captured from d1824c348 after the D8 suspension, before vacancy and loss were split.
	var path := "res://tests/building/fixtures/legacy_loom_v65.ecp2"
	var wire := FileAccess.get_file_as_bytes(path)
	var cursor := 28 + wire.decode_u32(24)
	while cursor + 8 < wire.size() and wire.decode_u32(cursor) != 1 << 5:
		cursor += 8 + wire.decode_u32(cursor + 4)
	var records := cursor + 8
	var valid := (records + 16 + 219 < wire.size() and wire.decode_u32(records) == 0x43454b50
		and wire.decode_u16(records + 4) == 65 and wire.decode_u16(records + 6) == 5
		and wire.decode_u32(records + 8) == 1 and wire.decode_s64(records + 16 + 12) == 1
		and wire.decode_u16(records + 16 + 217) == 1)
	_expect("actual PKEC65 fixture contains a suspended building with mixed loss history", valid)
	if not valid:
		return
	var fixture := _fixture(1, 1, 1, 2_000_000_000)
	var ext: Object = fixture.ext
	var restored: Dictionary = ext.restore_economy_ecp2(wire)
	_expect("PKEC65 / ECP2 archive restores", restored.get("ok", false))
	if not restored.get("ok", false):
		print(restored)
		return
	var migrated: Dictionary = ext.get_building_cell_snapshot(1)
	_expect("legacy stopped state survives, mixed history supplies no vacancy evidence",
		migrated.operating_state == PackedByteArray([1])
		and migrated.severe_loss_cycles == PackedInt32Array([0])
		and migrated.owner_vacancy_cycles == PackedInt32Array([0])
		and migrated.vacant_buildings == PackedInt64Array([0]))
	_expect("D9 is balanced and keeps the building", _balanced(_settle(ext, 9))
		and ext.get_building_cell_snapshot(1).group_counts == PackedInt64Array([1]))
	_expect("D10 hires and produces", _balanced(_settle(ext, 10))
		and ext.get_building_cell_snapshot(1).last_output[0] > 0)
	print("legacy v65 continuation: %d failures" % failures)
