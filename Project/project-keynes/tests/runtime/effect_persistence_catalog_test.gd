extends SceneTree

# 每个目录只有一种程序；原生持久化自测负责为换程序场景提供自己的合法目录。
func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures := 0
	for lifecycle in [0, 1]:
		var catalog := EffectCatalog.new()
		var definition := EffectDefinition.new()
		definition.key = &"test.single"
		definition.lifecycle = lifecycle
		definition.duration_days = -1 if lifecycle == 0 else 10
		var emit := EffectInstruction.new()
		emit.op = 11 # EMIT_COMMAND
		definition.instructions = [emit]
		var command := EffectCommand.new()
		command.action = 1 # MODIFIER_COMMAND
		command.domain = 3
		command.opcode = 1
		command.target_resolver = 1
		command.value_mode = 0 # VALUE_CONSTANT
		command.command_key = &"test.command"
		command.definition_key = &"test.definition"
		definition.commands = [command]
		catalog.definitions = [definition]

		var ext = ClassDB.instantiate("DCWorldExt")
		var configured: Dictionary = ext.configure_effects(catalog.compile_native_catalog())
		var ok := bool(configured.get("ok", false)) and bool(ext.runtime_effect_pod_self_test())
		print("[%s] single program lifecycle=%d, catalog=%s, persistence self-test=%s"
			% ["PASS" if ok else "FAIL", lifecycle, configured, ok])
		if not ok:
			failures += 1
	print("=== Effect persistence catalogs: 2 checks, %d failures ===" % failures)
	quit(0 if failures == 0 else 1)
