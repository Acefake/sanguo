extends SceneTree

func _initialize() -> void: call_deferred("run")

func run() -> void:
	var store: Node = root.get_node("GameState")
	store.persist_enabled = false
	store.prepare_battle_test(true)
	var rows: Array = []
	for day in range(40):
		await store.war.step(null)
		var row := {"day": day + 1, "corps": [], "units": []}
		for corps in store.war.state["corps"].values():
			row.corps.append({"faction": corps.faction, "withdrawing": corps.get("withdrawing", false), "orders": corps.orders.slice(-1), "context": store.war.Corps.commander_context(store.war, corps).battlefield})
		for army in store.war.active_armies():
			row.units.append({"name": army.name, "task": army.corps_task.type, "strength": store.war.Combat.strength(army), "morale": army.morale, "organization": army.organization, "returning": army.returning, "reason": army.last_reason, "retreat_reason": army.get("retreat_reason", ""), "action": army.action})
		rows.append(row)
		if row.units.any(func(u): return u.returning): print("RETREAT day=", day+1, " ", JSON.stringify(row))
	var file := FileAccess.open("res://docs/validation/battle-ai-after.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(rows, "\t"))
	store.restore_battle_test()
	quit()
