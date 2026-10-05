extends SceneTree

const Tactical = preload("res://scripts/war/tactical_battlefield.gd")
var failures: Array[String] = []

func _initialize() -> void: call_deferred("_run")

func check(value: bool, message: String) -> void:
	if not value:
		failures.append(message)
		push_error(message)

func _run() -> void:
	var store: Node = root.get_node("GameState")
	store.persist_enabled = false
	store.prepare_battle_test(true)
	var board: Dictionary = store.war.state["battlefield"]
	var anchor: int = int(board["anchor"])
	check(Tactical.column_of(anchor) == int(board["min_column"]) + 7 and Tactical.row_of(anchor) == int(board["min_row"]) + 9, "全局格战场原点错误")
	var path_board: Dictionary = board.duplicate(true)
	path_board["blocked"] = [Tactical.offset_cell(board, -3, 0), Tactical.offset_cell(board, -3, 1)]
	check(Tactical.neighbors(anchor).size() == 6 and Tactical.cell_distance(anchor, Tactical.neighbors(anchor)[0]) == 1, "六边格邻接错误")
	var cell: int = Tactical.offset_cell(board, -4, 0)
	var goal: int = Tactical.offset_cell(board, -2, 0)
	var detour := false
	for index in range(10):
		cell = Tactical._path_step(cell, goal, {}, path_board, 0)
		check(not path_board["blocked"].has(cell), "绕路穿过障碍")
		if Tactical.row_of(cell) != Tactical.row_of(goal): detour = true
		if cell == goal: break
	check(cell == goal and detour, "没有沿可通行格绕过障碍")
	var roles := {}
	for army in store.war.active_armies(): roles[army["operation"]["role"]] = true
	check(roles.has("main_attack") and roles.has("command") and roles.has("flank") and roles.has("reserve"), "缺少完整协同职责")
	for army in store.war.active_armies():
		var candidate_context: Dictionary = store.war.context_for(army)
		for candidate in candidate_context["candidates"]:
			var kind: String = candidate["action"]["type"]
			if army["operation"]["role"] == "reserve": check(kind not in ["continue", "engage", "flank", "support", "pursue"], "预备队擅自出击")
			if army["operation"]["role"] == "main_attack": check(kind not in ["support", "flank"], "主攻可擅自改做支援或侧翼")
			if army["operation"]["role"] == "flank" and kind == "engage": check(Tactical.distance(army, store.war.state["armies"][candidate["action"]["enemy"]]) <= 1, "侧翼可放弃绕行去远处正面冲锋")
	var context: Dictionary = store.war.context_for(store.war.active_armies()[0])
	var original_key: String = store.war._decision_key(context)
	context["operation"]["plan_until"] = 999
	context["operation"]["change_reason"] = "仅改变说明文字"
	for enemy in context["enemies"]: enemy["observed_at"] += 1
	check(store.war._decision_key(context) == original_key, "说明或计划截止日导致无意义重判")
	context["army"]["organization"] = 10
	check(store.war._decision_key(context) != original_key, "组织崩溃未触发重判")
	var front: Array = store.war.active_armies("liu_bei").filter(func(army): return army["tactical"]["role"] == "main_attack")
	front[0]["returning"] = true
	front[1]["returning"] = true
	store.war._update_operations()
	var reserves: Array = store.war.active_armies("liu_bei").filter(func(army): return army["tactical"]["role"] == "reserve")
	check(reserves[0]["operation"]["role"] == "reserve", "预备队自行改变主帅任务")
	var corps: Dictionary = store.war.state["corps"][reserves[0]["corps_id"]]
	check(store.war.Corps.issue(store.war, corps, {"type": "assign_task", "unit": reserves[0]["id"], "task": "main_attack"}, "主帅令预备队补线")["ok"], "主帅无法调动预备队")
	store.war._update_operations()
	check(reserves[0]["operation"]["role"] == "main_attack", "部将未执行主帅命令")
	store.prepare_battle_test(true)
	for tick in range(8):
		await store.war.step()
		var occupied := {}
		for army in store.war.active_armies():
			var position: int = int(army["tactical"]["cell"])
			check(not occupied.has(position) and not store.war.state["battlefield"]["blocked"].has(position), "战线推进出现重叠或穿障")
			occupied[position] = true
	store.prepare_battle_test(true)
	var board2: Dictionary = store.war.state["battlefield"]
	var own: Dictionary = store.war.active_armies("liu_bei")[0]
	var enemy: Dictionary = store.war.active_armies("yuan_shao")[0]
	for army in store.war.active_armies():
		if army["id"] not in [own["id"], enemy["id"]]: army["status"] = "ended"
	own["tactical"]["cell"] = Tactical.offset_cell(board2, 0, -2)
	own["tactical"]["role"] = "support"
	own["action"] = {"type": "support", "ally": own["id"]}
	enemy["tactical"]["cell"] = Tactical.offset_cell(board2, 0, 1)
	enemy["action"] = {"type": "hold"}
	store.war._observe_all()
	var before: int = store.war.Combat.strength(enemy)
	store.war._resolve_contacts({})
	check(store.war.Combat.strength(enemy) < before, "三格内远程支援未造成伤害")
	enemy["tactical"]["cell"] = Tactical.offset_cell(board2, 0, 3)
	before = store.war.Combat.strength(enemy)
	store.war._resolve_contacts({})
	check(store.war.Combat.strength(enemy) == before, "超出射程仍能攻击")
	enemy["status"] = "ended"
	own["returning"] = true
	var home_before: int = store.city_state("xiaopei")["garrison"]
	var return_count: int = store.war.Combat.strength(own)
	for tick in range(12):
		store.war._move_all()
		if own["status"] == "ended": break
	check(own["status"] == "ended" and store.city_state("xiaopei")["garrison"] == home_before + return_count, "撤退没有穿过安全边界归营或兵力不守恒")
	store.restore_battle_test()
	if failures.is_empty(): print("TACTICAL_BATTLEFIELD_OK: obstacle detour, four roles, eight-day collision checks, ranged limits, retreat and conservation")
	quit(0 if failures.is_empty() else 1)
