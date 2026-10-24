extends SceneTree

const T = preload("res://scripts/war/battle/tactical_battlefield.gd")
var failures: Array[String] = []
func _initialize() -> void: call_deferred("run")
func check(ok: bool, message: String) -> void:
	if not ok: failures.append(message); push_error(message)
func run() -> void:
	var store = root.get_node("GameState")
	store.persist_enabled = false
	for counter_only in [false,true]:
		store.prepare_battle_test(true,"plains_clash",42)
		var war = store.war
		war.rules["duel"]["enabled"] = false
		var own: Dictionary = war.active_armies("liu_bei")[1]
		var enemies: Array = war.active_armies("yuan_shao").slice(0,3)
		for unit in war.active_armies(): unit["status"] = "ended"
		var anchor: int = war.state["battlefield"]["anchor"]
		var cells := T.neighbors(anchor)
		own["tactical"]["cell"] = anchor
		for i in range(enemies.size()): enemies[i]["tactical"]["cell"] = cells[i]
		for unit in [own]+enemies:
			unit["status"] = "active"
			unit["returning"] = false
			unit["units"] = {"infantry":6000,"archers":0,"cavalry":0}
			unit["initial_strength"] = 6000
			unit["morale"] = 100.0
			unit["organization"] = 100.0
			unit["action"] = {"type":"hold"}
		if counter_only: own["action"] = {"type":"march"}
		war._observe_all()
		T.resolve(war)
		check(own.get("combat_targets",[]).size() == 3,"Missing contact sector counter=%s" % counter_only)
		for enemy in enemies:
			check(war.Combat.strength(enemy) < 6000,"Secondary enemy takes no damage counter=%s" % counter_only)
			check(enemy.get("daily_loss_tick",-1) == war.state["tick"],"Secondary loss missing from presentation")
			check(war.Combat.strength(enemy)+enemy["dead"]+enemy["wounded"]+enemy["captured"] == 6000,"Multi-contact soldier ledger mismatch")
		check(war.Combat.strength(own) < 6000,"Surrounded unit takes no damage")
	print("MULTI_CONTACT_OK" if failures.is_empty() else "MULTI_CONTACT_FAILED")
	quit(0 if failures.is_empty() else 1)
