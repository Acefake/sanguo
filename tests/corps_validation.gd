extends SceneTree

const Corps = preload("res://scripts/war/army_corps.gd")
const Tactical = preload("res://scripts/war/tactical_battlefield.gd")
var failures: Array[String] = []

class CommanderFixture extends Node:
	var model := "fixture"
	var last_status := "fixture"
	var metrics := {"fallbacks": 0}
	var requests := 0
	var commander_only := true
	func choose_batch(contexts: Array) -> Dictionary:
		var result := {}
		for context in contexts:
			requests += 1
			commander_only = commander_only and context.get("level", "") == "commander"
			result[context["request_id"]] = {"candidate_id": "maintain", "reason_summary": "保持军团部署", "source": "fixture"}
		return result

class ResetFixture extends Node:
	var store: Node
	func choose_batch(_contexts: Array) -> Dictionary:
		await get_tree().process_frame
		store.prepare_battle_test(true)
		return {}

func _initialize() -> void: call_deferred("_run")

func check(value: bool, message: String) -> void:
	if not value:
		failures.append(message)
		push_error(message)

func _run() -> void:
	var store: Node = root.get_node("GameState")
	store.persist_enabled = false
	store.prepare_battle_test(true)
	var war = store.war
	# This regression checks coordinated obedience; independent refusal has its own suite.
	war.rules["corps"] = {"autonomy": {"forced_stance": "obey"}}
	var corps: Dictionary = war.state["corps"].values().filter(func(c): return c["faction"] == "liu_bei")[0]
	var opposing: Dictionary = war.state["corps"].values().filter(func(c): return c["faction"] != "liu_bei")[0]
	var root_army: Dictionary = war.state["armies"][corps["root_id"]]
	check(war.roster.officers[corps["commander_id"]]["positions"].contains("主帅"), "主帅没有按人物位置选任")
	check(corps["members"].size() == corps["appointments"].size(), "自由编制存在未任职成员")
	var fixture := CommanderFixture.new()
	root.add_child(fixture)
	await war.step(fixture)
	check(fixture.requests == 2 and fixture.commander_only, "部将仍独立请求战略决策")
	var context: Dictionary = Corps.commander_context(war, corps)
	check(context["corps"]["strength"] > war.Combat.strength(root_army), "主帅只观察自身兵力")
	root_army["orders"] = war.orders_for(root_army)
	root_army["orders"]["retreat"] = false
	context = Corps.commander_context(war, corps)
	check(not context["candidates"].any(func(c): return c["id"] == "withdraw_corps"), "主帅可违反禁止自主撤退军令")
	check(not Corps.issue(war, corps, {"type": "withdraw_corps"}, "测试")["ok"], "非法撤退没有被执行层拒绝")
	root_army["orders"]["retreat"] = true
	# Isolate logistics tests from nearby combat; no real campaign save is written.
	war.state["battlefield"]["blocked"] = []
	var board: Dictionary = war.state["battlefield"]
	for id in opposing["units"]: war.state["armies"][id]["tactical"]["cell"] = Tactical.offset_cell(board, 7, 8)
	root_army["tactical"]["cell"] = Tactical.offset_cell(board, -7, -8)
	# In the six-person roster all four field leaders deploy. Regroup one reserve
	# before testing a new real detachment; the adviser must stay with command.
	var reserve_id: String = corps["units"].filter(func(id): return war.state["armies"][id]["corps_task"]["type"] == "reserve")[0]
	Corps.merge(war, corps, war.state["armies"][reserve_id], root_army)
	var active_officers: Array = corps["units"].map(func(id): return war.state["armies"][id]["officer_id"])
	var free: Array = corps["members"].filter(func(id): return not active_officers.has(id))
	var officer: String = Corps.best_member(war, free.filter(func(id): return corps["appointments"][id] != "参军"), "护军")
	var before: int = war.Combat.strength(root_army)
	var food: float = root_army["grain"]
	var initial: int = root_army["initial_strength"]
	var result: Dictionary = Corps.split(war, corps, root_army, officer, 500, "raid_rear", Tactical.offset_cell(board, -4, -6))
	check(result["ok"], "无法拆出奇袭小队")
	if not result["ok"]: quit(1); return
	var child: Dictionary = war.state["armies"][result["army_id"]]
	check(war.Combat.strength(root_army) + war.Combat.strength(child) == before and root_army["initial_strength"] + child["initial_strength"] == initial and is_equal_approx(root_army["grain"] + child["grain"], food), "拆队创造了兵力或粮食")
	check(Tactical.distance(root_army, child) == 1, "小队瞬移到敌后")
	for army in war.active_armies(): army["action"] = {"type": "hold"}
	for day in range(12):
		var old_cell: int = int(child["tactical"]["cell"])
		Tactical.move(war)
		check(Tactical.cell_distance(old_cell, child["tactical"]["cell"]) <= 1, "奇袭小队没有逐格移动")
		Corps.logistics(war)
		if child["corps_task"].get("stage", "") == "attack": break
	check(child["corps_task"].get("stage", "") == "attack", "奇袭小队没有抵达后方并转入攻击")
	var flank: Dictionary = war.state["armies"][corps["units"].filter(func(id): return war.state["armies"][id]["corps_task"]["type"] == "flank")[0]]
	check(Corps.issue(war, corps, {"type": "assign_task", "unit": flank["id"], "task": "raid_rear", "cell": Tactical.offset_cell(board, -4, -6)}, "派现有奇兵绕后")["ok"], "主帅无法派现有奇兵独立绕后")
	check(not Corps.split(war, corps, root_army, officer, 500, "raid_rear", Tactical.offset_cell(board, 0, 4))["ok"], "同一人物重复领队")
	check(not Corps.split(war, corps, war.state["armies"][opposing["root_id"]], free[1], 500, "raid_rear", Tactical.offset_cell(board, 0, 4))["ok"], "主帅可拆敌方军队")
	war.state["armies"][opposing["root_id"]]["tactical"]["cell"] = Tactical.neighbors(root_army["tactical"]["cell"])[0]
	war._observe_all()
	check(not Corps.split(war, corps, root_army, free[1], 500, "raid_rear", Tactical.offset_cell(board, 0, 4))["ok"], "接战拆队绕过包围")
	war.state["armies"][opposing["root_id"]]["tactical"]["cell"] = Tactical.offset_cell(board, 7, 8)
	war._observe_all()
	check(not Corps.issue(war, corps, {"type": "detach", "source": root_army["id"], "officer": free[1], "strength": 500, "task": "cut_supply", "cell": opposing["supply"]["cell"], "enemy_corps": opposing["id"]}, "断粮")["ok"], "主帅攻击未发现的粮道")
	corps["known_supplies"][opposing["id"]] = {"cell": int(opposing["supply"]["cell"]), "observed_at": war.state["tick"]}
	child["corps_task"] = {"type": "cut_supply", "cell": int(opposing["supply"]["cell"]), "enemy_corps": opposing["id"], "issued_by": corps["commander_id"]}
	var enemy_food: float = opposing["supply"]["stock"]
	Corps.logistics(war)
	check(opposing["supply"]["blocked_until"] == 0 and opposing["supply"]["stock"] == enemy_food, "未抵达粮道就断粮成功")
	child["tactical"]["cell"] = int(opposing["supply"]["cell"])
	var child_food: float = child["grain"]
	Corps.logistics(war)
	check(opposing["supply"]["blocked_until"] == 0 and opposing["supply"]["stock"] == enemy_food and child["grain"] == child_food, "停用系统后截粮仍生效")
	var enemy_army: Dictionary = war.state["armies"][opposing["root_id"]]
	enemy_army["grain"] = 0.0
	Corps.update(war)
	check(enemy_army["grain"] == 0.0, "粮道已断仍能补给")
	war.state["tick"] += 4
	Corps.update(war)
	check(enemy_army["grain"] == 0, "停用系统后仍在补给")
	check(Corps.issue(war, corps, {"type": "assign_task", "unit": child["id"], "task": "regroup"}, "归建")["ok"], "主帅无法收拢分队")
	child["tactical"]["cell"] = Tactical.neighbors(root_army["tactical"]["cell"])[0]
	war._observe_all()
	var merged_food: float = root_army["grain"] + child["grain"]
	Corps.logistics(war)
	check(child["status"] == "ended" and war.Combat.strength(root_army) == before and is_equal_approx(root_army["grain"], merged_food) and root_army["initial_strength"] == initial, "归建丢失或重复计算兵粮")
	var saved: Dictionary = war.export_state()
	war.setup(store, saved)
	check(war.state["corps"].size() == 2 and war.state.has("battlefield") and war.state["corps"][corps["id"]]["known_supplies"].is_empty(), "军团存档恢复失败")
	store.prepare_battle_test(true)
	corps = war.state["corps"].values()[0]
	check(Corps.issue(war, corps, {"type": "withdraw_corps"}, "全军有序撤退")["ok"], "主帅无法统一撤军")
	Corps.update(war)
	var guards: Array = corps["units"].filter(func(id): return war.state["armies"][id]["corps_task"].get("cover_withdrawal", false) and not war.state["armies"][id]["returning"])
	check(guards.size() == 1 and corps["units"].filter(func(id): return war.state["armies"][id]["returning"]).size() == corps["units"].size() - 1, "全军撤退没有留下受命掩护队")
	store.prepare_battle_test(true)
	corps = war.state["corps"].values()[0]
	root_army = war.state["armies"][corps["root_id"]]
	root_army["units"] = {"infantry": 0, "archers": 0, "cavalry": 0}
	war._finish(root_army, "军队覆没")
	check(corps["root_id"] != root_army["id"] and war.state["armies"][corps["root_id"]]["status"] != "ended", "中军覆没后无人接替指挥")
	for id in corps["units"].duplicate():
		var unit: Dictionary = war.state["armies"][id]
		if unit["status"] == "ended": continue
		unit["location"] = {"node": unit["home"], "edge": "", "progress": 0.0}
		war._finish(unit, "撤退归营")
	check(corps.get("ended", false) and corps["members"].all(func(id): return war.state["officer_states"][id]["status"] != "deployed"), "结束任务后随军人物仍被占用")
	store.prepare_battle_test(true)
	var reset := ResetFixture.new()
	reset.store = store
	root.add_child(reset)
	await Corps.plan(war, reset)
	check(war.state["corps"].values().all(func(c): return c["orders"].is_empty()), "旧模型回复污染重置后的军团")
	store._load_demo()
	war.rules["corps"] = {"autonomy": {"forced_stance": "obey"}}
	var city: Dictionary = store.city_state("luoyang")
	city.merge({"faction": "liu_bei", "garrison": 20000, "units": {"infantry": 14000, "archers": 4000, "cavalry": 2000}, "grain": 100000}, true)
	var members: Array = war.available_officers("liu_bei").map(func(o): return o["id"])
	var commander: String = Corps.best_member(war, members, "主帅")
	var dispatched: Dictionary = war.dispatch("luoyang", "hongnong", commander, members, true)
	check(dispatched["ok"], "普通战役不能编军出征")
	if dispatched["ok"]:
		var army: Dictionary = war.state["armies"][dispatched["army_id"]]
		var formation: Dictionary = war.state["corps"][army["corps_id"]]
		await war.step(fixture)
		check(army["location"]["edge"] != "" and float(army["location"]["progress"]) > 0, "普通军团停在原地无法行军")
		for id in formation["units"]:
			var unit: Dictionary = war.state["armies"][id]
			check(unit["location"]["edge"] == army["location"]["edge"] and absf(float(unit["location"]["progress"]) - float(army["location"]["progress"])) < 0.02, "普通分队脱离军团行军")
		store.city_state("hongnong").merge({"faction": "yuan_shao", "garrison": 0, "units": {"infantry": 0, "archers": 0, "cavalry": 0}}, true)
		# 行军途中演示剧本守军曾经出动；本段只验证攻取流程，先让场上敌军离场
		for other in war.active_armies():
			if str(other["faction"]) != "liu_bei" and str(other["location"].get("node", "")) == "hongnong":
				other["status"] = "ended"
		for id in formation["units"]:
			war.state["armies"][id]["location"] = {"node": "hongnong", "edge": "", "progress": 0.0}
		army["action"] = {"type": "besiege"}
		war._resolve_sieges()
		check(store.city_state("hongnong")["faction"] == "yuan_shao", "空城的完好城防被直接绕过")
		for day in range(160):
			war.state["tick"] += 1
			war._resolve_sieges()
			if store.city_state("hongnong")["faction"] == "liu_bei": break
		check(store.city_state("hongnong")["faction"] == "liu_bei" and formation["units"].all(func(id): return war.state["armies"][id].get("objective_complete", false)), "军团攻取后分队未统一结束目标")

	store._load_demo()
	city = store.city_state("luoyang")
	city.merge({"faction": "liu_bei", "garrison": 20000, "units": {"infantry": 20000, "archers": 0, "cavalry": 0}, "grain": 100000}, true)
	members = war.available_officers("liu_bei").map(func(o): return o["id"])
	commander = Corps.best_member(war, members, "主帅")
	dispatched = war.dispatch("luoyang", "hongnong", commander, members, true)
	var departing: Dictionary = war.state["armies"][dispatched["army_id"]]
	var departing_corps: Dictionary = war.state["corps"][departing["corps_id"]]
	for id in departing_corps["units"]: war.state["armies"][id]["location"] = {"node": "luoyang", "from": "luoyang", "to": "hongnong", "edge": war.graph.path("luoyang", "hongnong")["edges"][0], "progress": 0.3}
	check(war.command_army(departing["id"], {}, true)["ok"] and departing_corps["units"].all(func(id): return war.state["armies"][id]["returning"]), "主公全军撤退命令未传达全部分队")
	store.restore_battle_test()
	fixture.queue_free()
	reset.queue_free()
	if failures.is_empty(): print("CORPS_OK: hierarchy, appointments, authority, real split and regroup, contact pinning, discovered supply interception, conservation, succession, release, save and canceled model response")
	quit(0 if failures.is_empty() else 1)

