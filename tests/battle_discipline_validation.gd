extends SceneTree

const T = preload("res://scripts/war/tactical_battlefield.gd")
var failures: Array[String] = []

func _initialize() -> void: call_deferred("run")
func check(ok: bool, message: String) -> void:
	if not ok: failures.append(message); push_error(message)

func run() -> void:
	var store: Node = root.get_node("GameState")
	store.persist_enabled = false
	store.prepare_battle_test(true, "plains_clash")
	var war = store.war
	var own: Dictionary = war.active_armies("liu_bei").filter(func(a): return a["corps_task"]["type"] == "flank")[0]
	var enemy: Dictionary = war.active_armies("yuan_shao")[1]
	var board: Dictionary = war.state["battlefield"]
	board["blocked"] = []
	for unit in war.active_armies():
		if unit["id"] not in [own["id"], enemy["id"]]: unit["status"] = "ended"
	own["tactical"]["cell"] = T.offset_cell(board, -3, 0)
	enemy["tactical"]["cell"] = T.neighbors(int(own["tactical"]["cell"]))[0]
	own["action"] = {"type": "flank", "enemy": enemy["id"]}
	enemy["action"] = {"type": "flank", "enemy": own["id"]}
	var first: int = own["tactical"]["cell"]
	var second: int = enemy["tactical"]["cell"]
	for day in range(6):
		war.state["tick"] += 1
		war._observe_all()
		T.move(war)
		check(own["tactical"]["cell"] == first and enemy["tactical"]["cell"] == second, "近战侧翼仍绕圈")
	store.prepare_battle_test(true, "plains_clash")
	war = store.war
	board = war.state["battlefield"]
	board["blocked"] = []
	own = war.active_armies("liu_bei").filter(func(a): return a["corps_task"]["type"] == "flank")[0]
	enemy = war.active_armies("yuan_shao")[0]
	for unit in war.active_armies():
		if unit["id"] not in [own["id"], enemy["id"]]: unit["status"] = "ended"
	own["tactical"]["cell"] = T.offset_cell(board, -5, -5)
	enemy["tactical"]["cell"] = T.offset_cell(board, -2, -1)
	own["action"] = {"type": "flank", "enemy": enemy["id"]}
	enemy["action"] = {"type": "hold"}
	war._observe_all()
	T.move(war)
	var waypoint: int = own["tactical"]["flank_goal"]
	enemy["tactical"]["cell"] = T.offset_cell(board, -1, 0)
	war.state["tick"] += 1
	war._observe_all()
	T.move(war)
	check(own["tactical"]["flank_goal"] == waypoint, "侧翼绕行点仍逐日跟敌军移动")
	var corps: Dictionary = war.state["corps"][own["corps_id"]]
	var issue: Dictionary = war.Corps.issue(war, corps, {"type": "assign_task", "unit": own["id"], "task": "main_attack"}, "测试重新编入阵线")
	check(issue["ok"] and own["tactical"]["lane"] == T.column_of(own["tactical"]["cell"]), "调任仍沿用旧侧翼阵线")
	check(not war.Corps.issue(war, corps, {"type": "assign_task", "unit": own["id"], "task": "flank"}, "反复换令")["ok"], "同日允许反复改变任务")
	check(war.Corps.issue(war, corps, {"type": "assign_task", "unit": own["id"], "task": "rear_guard"}, "紧急掩护")["ok"], "换令限制阻断紧急掩护")
	store.prepare_battle_test(true, "plains_clash")
	war = store.war
	board = war.state["battlefield"]
	board["blocked"] = []
	own = war.active_armies("liu_bei").filter(func(a): return a["corps_task"]["type"] == "flank")[0]
	var enemies: Array = war.active_armies("yuan_shao")
	enemy = enemies[0]
	var alternative: Dictionary = enemies[1]
	for unit in war.active_armies():
		if unit["id"] not in [own["id"], enemy["id"], alternative["id"]]: unit["status"] = "ended"
	own["tactical"]["cell"] = T.offset_cell(board, 0, -3)
	enemy["tactical"]["cell"] = T.offset_cell(board, 0, 1)
	alternative["tactical"]["cell"] = T.offset_cell(board, 1, 1)
	own["tactical"]["attack_target"] = enemy["id"]
	own["tactical"]["target_until"] = int(war.state["tick"]) + 4
	war._observe_all()
	check(T.ordered_target(war, own).get("id", "") == enemy["id"], "微小距离变化打断目标承诺")
	alternative["tactical"]["cell"] = T.neighbors(int(own["tactical"]["cell"]))[0]
	war._observe_all()
	check(T.ordered_target(war, own).get("id", "") == alternative["id"], "目标承诺忽略贴身威胁")
	alternative["status"] = "ended"
	own["tactical"]["cell"] = T.offset_cell(board, 0, -1)
	own["tactical"]["flank_ready"] = true
	own["tactical"]["flank_target"] = enemy["id"]
	own["action"] = {"type": "flank", "enemy": enemy["id"]}
	enemy["returning"] = true
	var chase_origin: int = own["tactical"]["cell"]
	for day in range(8):
		war.state["tick"] += 1
		war._observe_all()
		T.move(war)
		check(T.cell_distance(chase_origin, int(own["tactical"]["cell"])) <= 3, "侧翼无限追赶溃退部队")
	store.prepare_battle_test(true, "plains_clash")
	var occupied_checks := 0
	for day in range(30):
		await store.war.step(null)
		var occupied := {}
		for unit in store.war.active_armies():
			var cell: int = unit["tactical"]["cell"]
			check(not occupied.has(cell) and T.grid().walkable(cell), "长战斗出现重叠或穿地形")
			occupied[cell] = true
			occupied_checks += 1
	print("BATTLE_DISCIPLINE_OK: stationary melee, fixed flank waypoint, rebased line, order commitment, 30-day cells=%d" % occupied_checks if failures.is_empty() else "BATTLE_DISCIPLINE_FAILED")
	quit(0 if failures.is_empty() else 1)
