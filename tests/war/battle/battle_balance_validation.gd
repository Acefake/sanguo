extends SceneTree
const Combat = preload("res://scripts/war/battle/combat_system.gd")
const T = preload("res://scripts/war/battle/tactical_battlefield.gd")
var failures: Array[String] = []
func _initialize(): call_deferred("run")
func check(ok: bool, message: String):
	if not ok: failures.append(message); push_error(message)
func run():
	var store = root.get_node("GameState")
	store.persist_enabled = false
	store.prepare_battle_test(true)
	var war = store.war
	var own: Dictionary = war.active_armies("liu_bei")[1]
	var enemy: Dictionary = war.active_armies("yuan_shao")[1]
	for unit in war.active_armies():
		if unit["id"] not in [own["id"], enemy["id"]]: unit["status"] = "ended"
	var board: Dictionary = war.state["battlefield"]
	var pair: Array = []
	for cell in range(T.grid().COUNT):
		if not T.in_battlefield(board, cell): continue
		for neighbor in T.neighbors(cell):
			if T.in_battlefield(board, neighbor): pair = [cell, neighbor]; break
		if not pair.is_empty(): break
	own["tactical"]["cell"] = pair[0]
	enemy["tactical"]["cell"] = pair[1]
	for unit in [own, enemy]:
		unit["action"] = {"type": "hold"}
		unit["morale"] = 100.0
		unit["organization"] = 100.0
	war._observe_all()
	var a := Combat.strength(own)
	var b := Combat.strength(enemy)
	T.resolve(war)
	check(Combat.strength(own) < a and Combat.strength(enemy) < b, "双方近战待命仍然只有一方挨打")
	check(own["combat_tick"] == war.state["tick"] and enemy["combat_tick"] == war.state["tick"], "交战动画没有同时触发")
	own["morale"] = 60.0
	own["organization"] = 90.0
	for day in range(10):
		Combat.apply_loss(own, 10, false, 0.0)
		Combat.battle_morale(own, 10, 100, 2000, 2000, 6000, 3000)
	check(own["morale"] >= 60 and own["organization"] >= 90, "兵力占优且赢得轻伤交锋仍持续掉军心或组织")
	var morale: float = own["morale"]
	Combat.battle_morale(own, 400, 600, 2000, 2000, 10000, 1000)
	check(own["morale"] < morale, "优势兵力无视严重伤亡")
	own["morale"] = 10
	war._check_rout(own)
	check(own["returning"] and own.has("retreat_reason"), "严重崩溃不撤离或没有原因")
	store.prepare_battle_test(true)
	war = store.war
	var corps: Dictionary = war.state["corps"].values()[0]
	var summary: Dictionary = war.Corps.summary(war, corps)
	var front: Dictionary = summary["units"].filter(func(u): return u["task"]["type"] == "main_attack")[0]
	var reserve: Dictionary = summary["units"].filter(func(u): return u["task"]["type"] == "reserve")[0]
	var rallying: Dictionary = war.state["armies"][front["id"]]
	var support: Dictionary = war.state["armies"][reserve["id"]]
	support["tactical"]["cell"] = rallying["tactical"]["cell"]
	rallying["organization"] = 15.0
	rallying["morale"] = 80.0
	for day in range(3):
		war.state["tick"] += 1
		war._check_rout(rallying)
	check(not rallying["returning"] and rallying["corps_task"]["type"] == "regroup", "有兵有粮有友军的整阵部队次日直接退出战场")
	rallying["organization"] = 100.0
	rallying["corps_task"]["type"] = "main_attack"
	war.state["armies"][front["id"]]["fatigue"] = 85.0
	var context: Dictionary = war.Corps.commander_context(war, corps)
	var choice: Dictionary = war.Corps.fallback(context)
	var selected: Dictionary = context["candidates"].filter(func(c): return c["id"] == choice["candidate_id"])[0]
	check(selected["action"]["type"] == "rotate_front", "主帅没有调预备队接替疲惫前锋")
	check(war.Corps.issue(war, corps, selected["action"], "预备轮换")["ok"], "轮换命令没有通过军团校验")
	check(war.state["armies"][front["id"]]["corps_task"]["type"] == "regroup" and not war.state["armies"][front["id"]]["returning"] and war.state["armies"][reserve["id"]]["corps_task"]["type"] == "main_attack", "轮换变成全军逃跑或没有新前锋")
	store.restore_battle_test()
	print("BATTLE_BALANCE_OK: mutual melee, both animations, winning morale/cohesion, severe losses and justified rout" if failures.is_empty() else "BATTLE_BALANCE_FAILED")
	quit(0 if failures.is_empty() else 1)
