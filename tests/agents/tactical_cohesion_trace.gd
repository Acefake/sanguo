extends SceneTree

func _initialize() -> void: call_deferred("run")

func run() -> void:
	var store: Node = root.get_node("GameState")
	store.persist_enabled = false
	var adapter = preload("res://scripts/agents/agent_adapter.gd").new()
	root.add_child(adapter)
	store.prepare_battle_test(true, "mountain_pass", 42)
	var war = store.war
	var corps: Dictionary = war.state.corps.values()[0]
	var root_army: Dictionary = war.state.armies[corps.root_id]
	var front: Dictionary = war.state.armies[corps.units[1]]
	front.tactical.cell = war.Tactical.neighbors(root_army.tactical.cell)[0]
	front.morale = 22.0
	front.organization = 15.0
	front.aura = 0.0
	war._check_rout(front)
	if front.returning or front.corps_task.type != "regroup":
		push_error("Supported front must try regrouping before retreat")
		store.restore_battle_test()
		quit(1)
		return
	war.state.tick += 6
	war._check_rout(front)
	if not front.returning:
		push_error("Failed rally must not postpone retreat indefinitely")
		store.restore_battle_test()
		quit(1)
		return
	print("RALLY_WINDOW_VALIDATION passed")
	store.prepare_battle_test(false, "mountain_pass", 42)
	for day in range(100):
		await store.war.step(adapter)
		if day % 10 == 9:
			for unit in store.war.active_armies():
				print("TRACE ", day + 1, " ", JSON.stringify({"id":unit.id,"task":unit.corps_task,"strength":store.war.Combat.strength(unit),"morale":unit.morale,"organization":unit.organization,"fatigue":unit.fatigue,"returning":unit.returning,"tactical":unit.tactical,"action":unit.action}))
		if store.war.state.battlefield.has("winner"): break
	store.restore_battle_test()
	quit()
