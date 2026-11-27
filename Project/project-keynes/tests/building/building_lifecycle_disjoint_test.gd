extends "res://tests/building/building_lifecycle_test.gd"


func _run() -> void:
	_test_disjoint_calendars()
	print("building lifecycle disjoint calendars: %d failures" % failures)
