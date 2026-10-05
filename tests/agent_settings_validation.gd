extends SceneTree

const Adapter = preload("res://scripts/agents/agent_adapter.gd")

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	var store: Node = root.get_node("GameState")
	store.persist_enabled = false
	var first := Adapter.new()
	first.settings_path = "user://agent-settings-test-%d.cfg" % Time.get_ticks_usec()
	first.configure({"enabled": true, "endpoint": "http://localhost/v1/chat/completions", "model": "test", "api_key": "fake-test-key", "concurrency": 7, "decision_budget": 5, "disable_reasoning": false})
	var second := Adapter.new()
	second.settings_path = first.settings_path
	second.load_settings()
	var valid: bool = second.api_key == "fake-test-key" and second.model == "test" and second.enabled
	valid = valid and second.concurrency == 7 and second.decision_budget_seconds == 5 and not second.disable_reasoning
	DirAccess.remove_absolute(ProjectSettings.globalize_path(first.settings_path))
	first.free()
	second.free()
	store.open_settings()
	valid = valid and store.settings_menu.window.visible and store.settings_menu.key.secret
	store.settings_menu.window.hide()
	print("AGENT_SETTINGS_OK: restart reload, isolated fixture, main settings menu, masked key" if valid else "AGENT_SETTINGS_FAILED")
	quit(0 if valid else 1)
