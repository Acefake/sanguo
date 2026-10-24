extends SceneTree

# Exercise the actual AI/movement/combat flow with default duel probabilities.
func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var store = root.get_node("GameState")
	store.persist_enabled = false
	store.prepare_battle_test(true)
	var war = store.war
	for day in range(40):
		await war.step(null)
		if not war.state["duels"]["records"].is_empty(): break
	var records: Array = war.state["duels"]["records"]
	if records.is_empty():
		push_error("默认战场正常推进40天未产生单挑")
		quit(1)
		return
	for record in records:
		print("DUEL_CONTACT_FLOW tick=", record["tick"], " result=", record["result"], " ", record["message"])
	print("VALIDATION OK duel_contact_flow")
	quit(0)
