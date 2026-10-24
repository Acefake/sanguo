extends SceneTree

const Scenarios = preload("res://scripts/war/battle/battle_scenarios.gd")
const Objectives = preload("res://scripts/war/battle/battle_objectives.gd")
var failures: Array[String] = []
func _initialize() -> void: call_deferred("run")
func check(ok: bool, message: String) -> void:
	if not ok: failures.append(message); push_error(message)

func run() -> void:
	var store: Node = root.get_node("GameState")
	store.persist_enabled = false
	store.agent.enabled = false
	var native_words = store.war.Tactical.grid().words.duplicate()
	check(Scenarios.definitions().size() == 8, "八种战场配置未齐全")
	for spec in Scenarios.definitions():
		for preformed in [true, false]:
			store.prepare_battle_test(preformed, spec["id"], 42)
			var war = store.war
			var board: Dictionary = war.state["battlefield"]
			check(board["objective_text"] == spec["objective_text"], "目标未进入规则状态")
			if spec.has("terrain"): check(war.Tactical.terrain_class(board["anchor"]) == spec["terrain"], "战场没有使用匹配的原生地形")
			var occupied := {}
			if spec["kind"] == "field": check(board["fortifications"].is_empty(), "野战区域混入非参战城防")
			for army in war.active_armies():
				var cell: int = army["tactical"]["cell"]
				check(war.Tactical.can_enter(war, army, cell) and not occupied.has(cell), "开局出现不可通行或重复位置")
				occupied[cell] = true
				if board.has("deployment_cells"): check(board["deployment_cells"].has(cell), "部队与目标不在同一可通行区域")
			for corps in war.state["corps"].values():
				var unique: Dictionary = {}
				for id in corps["members"]:
					check(not unique.has(id), "军团成员重复")
					unique[id] = true
					check(corps["appointments"].has(id), "成员缺少自定义岗位")
					check(preload("res://scripts/war/campaign/corps_structure.gd").depth_of(corps, str(id)) >= 0, "指挥层级形成循环")
			for faction in spec["strengths"]:
				var total := 0
				for army in war.active_armies(faction): total += war.Combat.strength(army)
				if spec["kind"] == "siege" and faction == "liu_bei":
					check(store.city_state("xiaopei")["garrison"] == spec["strengths"][faction] + spec["garrison"], "归城守军兵员丢失")
				else: check(total == spec["strengths"][faction], "配置与实际兵力不一致")
			var saved: Dictionary = war.export_state()
			war.setup(store, saved)
			check(war.state["battlefield"].get("control_point", {}) == board.get("control_point", {}), "据点状态读档丢失")
	check(store.war.Tactical.grid().words == native_words, "场景改写了原生地形")
	store.prepare_battle_test(true, "dingjun_hill", 42)
	var war = store.war
	var board: Dictionary = war.state["battlefield"]
	var point: Dictionary = board["control_point"]
	var own: Dictionary = war.active_armies("liu_bei")[1]
	var enemy: Dictionary = war.active_armies("yuan_shao")[1]
	for army in war.active_armies():
		if army != own and army != enemy: army["status"] = "ended"
	own["tactical"]["cell"] = point["cell"]
	enemy["tactical"]["cell"] = war.Tactical.offset_cell(board, 4, 5)
	war.state["tick"] = 1
	Objectives.update(war)
	check(point["progress"] == 1 and point["owner"] == "liu_bei", "据点不按物理到达计时")
	Objectives.update(war)
	check(point["progress"] == 1, "同日重复调用增加占领进度")
	war.state["tick"] = 2
	enemy["tactical"]["cell"] = war.Tactical.neighbors(point["cell"])[0]
	Objectives.update(war)
	check(point["contested"] and point["progress"] == 0, "敌军接近未中断占领")
	war.state["tick"] = 3
	enemy["returning"] = true
	Objectives.update(war)
	check(point["progress"] == 1 and not point["contested"], "撤退敌军仍然争夺据点")
	war.state["tick"] = 4
	own["tactical"]["cell"] = war.Tactical.offset_cell(board, -4, -5)
	Objectives.update(war)
	check(point["progress"] == 0 and point["owner"] == "", "离开据点仍继续计时")
	own["tactical"]["cell"] = point["cell"]
	for day in range(int(point["hold_days"])):
		war.state["tick"] += 1
		Objectives.update(war)
	check(board.get("winner", "") == "liu_bei" and board.has("victory_reason"), "控制胜利未进入真实结算")
	store.restore_battle_test()
	if failures.is_empty(): print("BATTLE_OBJECTIVES_OK: eight scenes, real terrain, connected deployment, free corps membership/tree, configured strength, siege garrison, save reload and contested objective victory")
	quit(0 if failures.is_empty() else 1)
