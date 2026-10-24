extends SceneTree

const T = preload("res://scripts/war/tactical_battlefield.gd")
var failures: Array[String] = []

class DeploymentAgent extends Node:
	var model := "deployment-fixture"
	var metrics := {"fallbacks": 0}
	var requests := 0
	func choose_batch(contexts: Array) -> Dictionary:
		var output := {}
		for context in contexts:
			requests += 1
			var selected := "maintain"
			for option in context["candidates"]:
				if option["action"]["type"] == "deploy_corps" and option["action"]["posture"] == "assault": selected = option["id"]; break
			output[context["request_id"]] = {"candidate_id": selected, "source": "model", "reason_summary": "主帅亲自决定加强前锋部署"}
		return output

func _initialize() -> void: call_deferred("run")
func prepare_siege_fixture(store) -> void:
	store.prepare_battle_test(false,"plains_clash")
	# This checks autonomous deployment from two commanders at Xiaopei, not the
	# startup picker's default field-battle scenario.
	preload("res://scripts/war/xiaopei_battle.gd").setup(store,false)
func check(ok: bool, message: String) -> void:
	if not ok: failures.append(message); push_error(message)

func ledger(war, corps: Dictionary) -> int:
	var count := 0
	for id in corps["units"]:
		var army: Dictionary = war.state["armies"][id]
		count += war.Combat.strength(army) + int(army["dead"]) + int(army["wounded"]) + int(army["captured"]) + int(army["deposited"])
	return count

func position_attackers(war, corps: Dictionary) -> void:
	var city: int = war.state["battlefield"]["objectives"]["xiaopei"]
	var cells := []
	for cell in range(48400):
		if T.grid().walkable(cell) and T.cell_distance(cell, city) <= 2: cells.append(cell)
	check(cells.size() >= corps["units"].size(), "城下可展开格不足")
	for index in range(corps["units"].size()):
		var army: Dictionary = war.state["armies"][corps["units"][index]]
		army["tactical"]["cell"] = cells[index]
		army["corps_task"]["type"] = "main_attack"
		army["action"] = {"type": "continue"}
	for army in war.active_armies("liu_bei"): army["returning"] = true

func run() -> void:
	var store: Node = root.get_node("GameState")
	store.persist_enabled = false
	prepare_siege_fixture(store)
	var war = store.war
	check(war.active_armies().size() == 2, "军团开场已经预先拆队")
	var agent := DeploymentAgent.new()
	root.add_child(agent)
	await war.step(agent)
	var corps: Dictionary = war.state["corps"].values().filter(func(c): return c["faction"] == "yuan_shao")[0]
	check(agent.requests == 2 and corps.get("deployment_posture", "") == "assault", "不是由主帅代理决定展开兵力")
	check(corps["units"].size() > 1 and ledger(war, corps) == 20000, "分兵产生或丢失士兵")
	var stock_before: float = float(corps["supply"]["stock"])
	var food := stock_before
	for id in corps["units"]: food += float(war.state["armies"][id]["grain"])
	check(absf(food) < 0.01, "停用系统后分兵仍携带口粮")
	position_attackers(war, corps)
	corps["siege_approach"] = true
	var root_army: Dictionary = war.state["armies"][corps["root_id"]]
	var city: Dictionary = store.city_state("xiaopei")
	var initial_defenders: int = city["garrison"]
	war.state["tick"] += 1
	war._resolve_sieges()
	var siege: Dictionary = war.state["sieges"].get("xiaopei", {})
	check(not siege.is_empty() and siege["phase"] == "准备" and siege["wall"] == siege["wall_max"] and city["faction"] == "liu_bei", "没有准备阶段或瞬间破城")
	var progress: float = siege["preparation"]
	var walls: float = siege["wall"]
	war._resolve_sieges()
	check(siege["preparation"] == progress and siege["wall"] == walls, "同一天重复结算攻城")
	var relief: Dictionary = war.active_armies("liu_bei")[0]
	relief["returning"] = false
	relief["tactical"]["cell"] = T.neighbors(int(root_army["tactical"]["cell"]))[0]
	war.state["tick"] += 1
	war._resolve_sieges()
	check(siege["phase"] == "援军阻断" and siege["preparation"] == progress and siege["wall"] == walls, "敌援军未阻断攻城")
	check(war.Feedback.book(war).get("pending_events",[]).any(func(e):return e["kind"] == "援军阻断"),"真实援军阻断没有写入会战事件")
	relief["returning"] = true
	relief["status"] = "ended"
	# 其余撤退守军也离场：避免他们在新城规则下走回小沛补入守军（fixture 清场）。
	for defender in war.active_armies("liu_bei"):
		defender["returning"] = true
		defender["status"] = "ended"
	check(not war.Corps.issue(war, corps, {"type": "set_siege_mode", "mode": "blockade"}, "围困待粮")["ok"], "移除系统后仍能选择断粮围困")
	war.state["tick"] += 1
	war._resolve_sieges()
	check(siege["mode"] == "assault", "移除围困后没有改用强攻")
	city["grain"] = 0
	war.state["tick"] += 1
	war._resolve_sieges()
	check(siege["grain_days"] == 999, "围城仍提供断粮判断")
	city["grain"] = 18000
	war.Corps.issue(war, corps, {"type": "set_siege_mode", "mode": "assault"}, "破墙入城")
	# Force a final wall breach so its actual callback is covered independently of surrender.
	siege["wall"] = 1.0
	siege["morale"] = 100.0
	siege["organization"] = 100.0
	var capture_day := -1
	for day in range(50):
		war.state["tick"] += 1
		# 新规则：驻军只吃“真正入城”的巷战伤害，因此破口开放后按真实移动进城。
		if bool(siege.get("breach_open", false)): T.move(war)
		war._resolve_sieges()
		if city["faction"] == "yuan_shao": capture_day = day + 1; break
	check(capture_day > 0 and siege["phase"] == "occupied", "无法完成破城占领")
	check(war.Feedback.book(war).get("pending_events",[]).any(func(e):return e["kind"] == "破墙"),"真实攻城破墙没有写入会战事件")
	check(ledger(war, corps) == 20000 and city["garrison"] > 0, "攻城与留守兵力不守恒")
	check(int(city["war_dead"]) + int(city["wounded"]) + int(city.get("prisoners", 0)) == initial_defenders, "守军损失与俘虏不守恒")
	check(corps["units"].all(func(id): return war.state["armies"][id].get("objective_complete", false) and war.state["armies"][id]["returning"]), "破城后全军没有按军令撤回")
	var saved: Dictionary = war.export_state()
	war.setup(store, saved)
	check(war.state["sieges"]["xiaopei"]["phase"] == "occupied", "读档丢失攻城状态")
	prepare_siege_fixture(store)
	war = store.war
	await war.step(null)
	corps = war.state["corps"].values().filter(func(c): return c["faction"] == "yuan_shao")[0]
	# Withdraw defenders through the actual movement rules, then march to the city.
	for defender in war.active_armies("liu_bei"):
		# Evacuate to another friendly city; returning to Xiaopei reinforces its guard.
		defender["home"] = "xiapi"
		war._execute(defender, {"type": "withdraw"})
	# 新规则要求真实破门入城、驻军不再被远程强攻磨死；本段物理攻城需要有
	# 器械与足够步兵的围城军团，fixture 按围城编制补足（不改城市守军）。
	var siege_units := 0
	for id in corps["units"]:
		var troop: Dictionary = war.state["armies"][id]
		if troop["status"] == "ended" or troop["returning"]: continue
		var strength: int = maxi(4000, war.Combat.strength(troop))
		troop["units"] = {"infantry": strength, "archers": 0, "cavalry": 0}
		troop["siege_engines"] = 0
		siege_units += 1
	if siege_units > 0: war.state["armies"][corps["root_id"]]["siege_engines"] = 4
	var reached := false
	for day in range(35):
		await war.step(null)
		if war.state["sieges"].has("xiaopei"): reached = true; break
	check(reached, "野战结束后军团不能沿全局格推进到城下")
	var physically_captured := false
	# 新规则下城墙必须真正被打破、部队入城才能占领，给足真实破墙时间。
	for day in range(110):
		await war.step(null)
		if store.city_state("xiaopei")["faction"] == "yuan_shao": physically_captured = true; break
	if not physically_captured:
		print("FAILED_SIEGE_TRACE ", JSON.stringify(war.state["sieges"]))
		for unit in war.state["armies"].values(): print("FAILED_SIEGE_UNIT ", JSON.stringify({"id":unit["id"], "status":unit["status"], "returning":unit["returning"], "strength":war.Combat.strength(unit), "tactical":unit.get("tactical", {}), "task":unit["corps_task"], "morale":unit["morale"], "grain":unit["grain"]}))
	check(physically_captured and war.state["battlefield"].get("winner", "") == "yuan_shao", "城下推进后无法完成战役攻取目标")
	store.restore_battle_test()
	agent.queue_free()
	print("SIEGE_CORPS_OK: commander deployment, grain/troop conservation, preparation, relief pause, blockade/starvation, capture days=%d, garrison, orders, save, physical city approach" % capture_day if failures.is_empty() else "SIEGE_CORPS_FAILED")
	quit(0 if failures.is_empty() else 1)
