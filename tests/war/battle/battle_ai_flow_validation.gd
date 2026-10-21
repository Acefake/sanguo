extends SceneTree
const T = preload("res://scripts/war/battle/tactical_battlefield.gd")
var failures: Array[String] = []
var store
func _initialize() -> void: call_deferred("run")
func check(ok: bool, message: String) -> void:
	if not ok: failures.append(message); push_error(message)
func run() -> void:
	store = root.get_node("GameState")
	store.persist_enabled = false
	store.agent.enabled = false
	store.prepare_battle_test(true,"plains_clash",42)
	var war = store.war
	var own: Dictionary = war.active_armies("liu_bei")[1]
	var foe: Array = war.active_armies("yuan_shao").slice(0,3)
	for army in war.active_armies():
		if army != own and not foe.has(army): army["status"] = "ended"
	var board: Dictionary = war.state["battlefield"]
	var cell := -1
	for q in range(int(board["min_column"])+2,int(board["max_column"])-6):
		for r in range(int(board["min_row"])+2,int(board["max_row"])-2):
			var candidate := T.cell_at(q,r)
			if range(6).all(func(i): return T.can_enter(war,own,candidate+i) and T.terrain_class(candidate+i) == "plains"):
				cell = candidate
				break
		if cell >= 0: break
	assert(cell >= 0)
	own["units"] = {"infantry":3000,"cavalry":0,"archers":0}
	own["tactical"]["cell"] = cell
	own["tactical"]["lane"] = T.column_of(cell)
	own["tactical"]["role"] = "main_attack"
	own["operation"]["role"] = "main_attack"
	own["corps_task"]["type"] = "main_attack"
	own["action"] = {"type":"engage","enemy":foe[1]["id"]}
	foe[0]["tactical"]["cell"] = cell+1
	var side: int = Array(T.neighbors(cell)).filter(func(c): return c != cell+1 and T.can_enter(war,foe[1],c))[0]
	foe[1]["tactical"]["cell"] = side
	foe[2]["tactical"]["cell"] = cell+4
	own["tactical"]["attack_target"] = foe[1]["id"]
	war._observe_all()
	T.clear_target_cache()
	check(T.ordered_target(war,own)["id"] == foe[0]["id"],"Exposed adjacent commander loses to stale target stickiness")
	own["action"] = {"type":"request_support"}
	T.move(war)
	check(own["tactical"]["attack_target"] == foe[0]["id"],"Nearby commander ignored during movement")
	own["intel"]["enemies"][foe[0]["id"]]["observed_at"] = int(war.state["tick"])-1
	T.clear_target_cache()
	check(not T.targets(war,own).has(foe[0]),"Stale sighting used for direct targeting")
	own["action"] = {"type":"engage","enemy":foe[0]["id"]}
	own["tactical"]["attack_target"] = foe[0]["id"]
	T.move(war)
	check(own["tactical"]["attack_target"] != foe[0]["id"],"Stale explicit target survives movement validation")
	# A cavalry detachment can choose a nearby exposed bow unit over its old
	# infantry target when both are adjacent and neither is the commander.
	foe[0]["status"] = "ended"
	own["tactical"]["cell"] = cell
	own["units"] = {"infantry":0,"cavalry":3000,"archers":0}
	foe[1]["tactical"]["cell"] = side
	foe[1]["units"] = {"infantry":3000,"cavalry":0,"archers":0}
	foe[2]["tactical"]["cell"] = cell+1
	foe[2]["units"] = {"infantry":0,"cavalry":0,"archers":3000}
	own["tactical"]["attack_target"] = foe[1]["id"]
	own.erase("last_enemy_id")
	war._observe_all()
	check(T.ordered_target(war,own)["id"] == foe[2]["id"],"Cavalry ignores favorable adjacent bow target")
	# A lone surviving front must continue instead of waiting forever for dead allies.
	foe[0]["status"] = "ended"
	foe[1]["status"] = "ended"
	foe[2]["tactical"]["cell"] = cell+4
	own["units"] = {"infantry":3000,"cavalry":0,"archers":0}
	own["tactical"]["cell"] = cell
	own["action"] = {"type":"engage","enemy":foe[2]["id"]}
	own["tactical"]["attack_target"] = foe[2]["id"]
	war._observe_all()
	T.move(war)
	check(own["tactical"]["cell"] != cell,"Last front waits for ended or retreating comrades")
	# Bows already able to shoot do not move toward a support anchor into melee.
	own["units"] = {"infantry":0,"cavalry":0,"archers":3000}
	own["tactical"]["cell"] = cell
	own["operation"]["role"] = "support"
	own["corps_task"]["type"] = "support"
	own["action"] = {"type":"support","ally":own["id"]}
	foe[2]["tactical"]["cell"] = cell+2
	war._observe_all()
	T.move(war)
	check(own["tactical"]["cell"] == cell and own["action"]["type"] == "engage","Bow detachment leaves valid two-hex firing position")
	var before: int = war.Combat.strength(foe[2])
	war._resolve_contacts({})
	check(war.Combat.strength(foe[2]) < before,"Holding firing range produces no shot")
	# Player permissions take precedence over immediate reactions.
	own["orders"] = {"engage":false}
	own["action"] = {"type":"hold"}
	war._observe_all()
	T.move(war)
	check(own["action"]["type"] == "hold","Automatic targeting overrides disengage order")
	# Strategic assignments also use sightings; serialized key ordering must not
	# change which target is suggested after reloading a campaign.
	war.state["corps"] = {}
	own.erase("corps_id")
	own.erase("tactical")
	own["intel"]["enemies"] = {"z":{"id":"z","observed_at":war.state["tick"]},"a":{"id":"a","observed_at":war.state["tick"]},"stale":{"id":"stale","observed_at":int(war.state["tick"])-1}}
	war._update_operations()
	var first: String = own["operation"]["suggested_target"]
	own["intel"]["enemies"] = JSON.parse_string(JSON.stringify(own["intel"]["enemies"]))
	war._update_operations()
	check(first == "a" and own["operation"]["suggested_target"] == first,"Serialized sighting order changes strategic target")
	print("BATTLE_AI_FLOW ","PASS" if failures.is_empty() else failures)
	quit(0 if failures.is_empty() else 1)
