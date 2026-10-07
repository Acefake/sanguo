extends SceneTree
const Tactical = preload("res://scripts/war/tactical_battlefield.gd")
const Pressure = preload("res://scripts/war/ranged_pressure.gd")
var failures: Array[String] = []
func _initialize() -> void: call_deferred("run")
func check(ok: bool, message: String) -> void:
	if not ok: failures.append(message); push_error(message)
func run() -> void:
	var store = root.get_node("GameState")
	store.persist_enabled = false
	store.prepare_battle_test(true,"plains_clash",42)
	var war = store.war
	var corps: Dictionary = war.state["corps"][war.active_armies("liu_bei")[0]["corps_id"]]
	var own: Dictionary = war.state["armies"][corps["root_id"]]
	var enemy: Dictionary = war.active_armies("yuan_shao")[0]
	for unit in war.active_armies():
		if unit["id"] not in [own["id"],enemy["id"]]: unit["status"] = "ended"
	var board: Dictionary = war.state["battlefield"]
	board["blocked"] = []
	board["terrain"] = {}
	own["units"] = {"infantry":2000,"archers":0,"cavalry":0}
	enemy["units"] = {"infantry":0,"archers":1000,"cavalry":0}
	own["tactical"]["cell"] = Tactical.offset_cell(board,0,-2)
	enemy["tactical"]["cell"] = Tactical.offset_cell(board,0,0)
	enemy["tactical"]["role"] = "support"
	enemy["action"] = {"type":"engage","enemy":own["id"]}
	own["action"] = {"type":"hold"}
	war._observe_all()
	var before: int = war.Combat.strength(own)
	war._resolve_contacts({})
	check(war.Combat.strength(own) < before,"两格弓兵未命中")
	war._observe_all()
	Pressure.respond(war,corps)
	check(own["action"]["type"] == "engage","受射中军仍待命")
	var start: int = own["tactical"]["cell"]
	Tactical.move(war)
	check(own["tactical"]["cell"] != start and Tactical.distance(own,enemy) == 1,"中军未逼近到近战格")
	var enemy_before: int = war.Combat.strength(enemy)
	war._resolve_contacts({})
	check(war.Combat.strength(enemy) < enemy_before,"逼近后未反击")
	own["tactical"]["cell"] = Tactical.offset_cell(board,0,-3)
	enemy["tactical"]["cell"] = Tactical.offset_cell(board,0,0)
	own["action"] = {"type":"hold"}
	war._observe_all()
	before = war.Combat.strength(own)
	war._resolve_contacts({})
	check(war.Combat.strength(own) == before,"弓兵越过两格射程")
	own["tactical"]["cell"] = Tactical.offset_cell(board,0,-2)
	own["units"] = {"infantry":500,"archers":0,"cavalry":0}
	own["last_enemy_id"] = enemy["id"]
	own["last_enemy_tick"] = war.state["tick"]
	war._observe_all()
	Pressure.respond(war,corps)
	check(own["action"]["type"] == "evade","弱势中军未避射")
	Tactical.move(war)
	check(Tactical.distance(own,enemy) >= 3,"避射后仍留在箭阵射程")
	own["tactical"]["cell"] = Tactical.offset_cell(board,0,-2)
	own["orders"] = {"engage":false,"retreat":false}
	own["action"] = {"type":"hold"}
	war._observe_all()
	Pressure.respond(war,corps)
	check(own["action"]["type"] == "hold","受射反应越过玩家许可")
	own["orders"] = {}
	own["intel"]["enemies"][enemy["id"]]["observed_at"] = int(war.state["tick"])-1
	Pressure.respond(war,corps)
	check(own["action"]["type"] == "hold","根据过期情报追击射手")
	# Exercise the real day pipeline: ordinary officer proposals run before the
	# immediate reaction and must not turn it back into hold.
	own["units"] = {"infantry":2000,"archers":0,"cavalry":0}
	own["morale"] = 80.0
	own["organization"] = 80.0
	own["last_enemy_tick"] = war.state["tick"]
	own["last_decision"] = -10
	corps["last_plan"] = 999
	enemy["corps_task"]["type"] = "support"
	war.state["corps"][enemy["corps_id"]]["last_plan"] = 999
	war.rules["duel"]["enabled"] = false
	war._observe_all()
	await war.step()
	check(own["action"]["type"] == "engage" and Tactical.distance(own,enemy) <= 1,"日循环将受射反应覆盖为待命")
	var escort: Dictionary = war.state["armies"][corps["units"][1]]
	escort["status"] = "active"
	escort["returning"] = false
	escort["units"] = {"infantry":1000,"archers":0,"cavalry":0}
	escort["corps_task"]["type"] = "main_attack"
	escort["tactical"]["cell"] = Tactical.offset_cell(board,0,-3)
	own["tactical"]["cell"] = Tactical.offset_cell(board,0,-2)
	enemy["tactical"]["cell"] = Tactical.offset_cell(board,0,0)
	own["units"] = {"infantry":500,"archers":0,"cavalry":0}
	own["last_enemy_tick"] = war.state["tick"]
	escort["action"] = {"type":"hold"}
	war._observe_all()
	Pressure.respond(war,corps)
	check(own["action"]["type"] == "evade" and escort["action"].get("enemy","") == enemy["id"] and escort["tactical"]["attack_target"] == enemy["id"],"弱势中军未调动友军压制射手")
	escort["orders"] = {"engage":false}
	escort["action"] = {"type":"hold"}
	Pressure.respond(war,corps)
	check(escort["action"]["type"] == "hold","压制命令越过部将交战许可")
	print("RANGED_PRESSURE_VALIDATION ","PASS" if failures.is_empty() else failures)
	quit(0 if failures.is_empty() else 1)
