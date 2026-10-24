extends SceneTree
func _initialize() -> void: call_deferred("run")
func run() -> void:
	var args := OS.get_cmdline_user_args()
	var scenario_id := str(args[0]) if args.size() > 0 else "marsh_battle"
	var seed_value := int(args[1]) if args.size() > 1 else 1910901
	var duration := int(args[2]) if args.size() > 2 else 160
	var store: Node = root.get_node("GameState")
	store.persist_enabled = false
	store.prepare_battle_test(false, scenario_id, seed_value)
	var adapter := preload("res://scripts/agents/agent_adapter.gd").new()
	root.add_child(adapter)
	var war = store.war
	for day in range(duration):
		await war.step(adapter)
		if war.state["battlefield"].has("winner"): break
	for corps in war.state["corps"].values():
		var units: Array = []
		for id in corps["units"]:
			var army: Dictionary = war.state["armies"][id]
			if army["status"] == "ended": continue
			units.append({"name": army["name"], "task": army["corps_task"], "strength": war.Combat.strength(army), "morale": army["morale"], "org": army["organization"], "cell": army["tactical"]["cell"], "returning": army["returning"], "phase": army["tactical"].get("phase", ""), "action": army["action"]})
		print("TRACE ", JSON.stringify({"units": units, "orders": corps["orders"].slice(-3), "assessment": war.Corps.commander_context(war, corps)["retreat_assessment"]}))
	print("SCENARIO_TRACE_RESULT ", scenario_id, " tick=", war.state["tick"], " winner=", war.state["battlefield"].get("winner", "unfinished"))
	quit()
