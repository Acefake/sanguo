extends SceneTree
## 战场分边（BattleSides）验收：参战势力与主帅由数据声明，人物按名册势力归边。
##
## 用真实人物卡、campaign_rules 的 faction_mapping 与演示剧本的生成将建名册，再按 data/war/xiaopei_battle.json 分边：
##   1. 每方武将数 > 0，主帅属于本方，没有跨阵营武将，没有一人两边；未参战势力的人一个不进。
##   2. 声明的主帅在本方时就是他；不在本方时告警并改由本方择帅。
##   3. 一方没有人物卡武将：用该势力的生成将补位并告警；生成将也没有：返回错误，不建任何一方。
##   4. 人物卡带 faction_id 时优先于显示名映射。
##
##   godot --headless --path . --script res://tests/war/battle/battle_sides_validation.gd

const Sides = preload("res://scripts/war/battle/battle_sides.gd")
const Roster = preload("res://scripts/agents/officer_context.gd")
const Repository = preload("res://scripts/officers/officer_repository.gd")

var failures: Array[String] = []


func check(value: bool, message: String) -> void:
	if not value:
		failures.append(message)
		push_error(message)


func roster() -> Roster:
	var rules: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/war/campaign_rules.json"))
	var result := Roster.new()
	result.setup(Repository.cards(), rules.get("faction_mapping", {}))
	result.ensure_factions(JSON.parse_string(FileAccess.get_file_as_string("res://data/scenario_demo.json")))
	return result


## 名册里排第一的成员当主帅，测试不依赖择帅打分。
func first(members: Array) -> String:
	return str(members[0]) if not members.is_empty() else ""


func check_plan(officers: Dictionary, declared: Array, plan: Dictionary, label: String) -> void:
	check(str(plan["error"]).is_empty(), label + "：不应报错 " + str(plan["error"]))
	check(plan["sides"].size() == declared.size(), label + "：方数与声明不符")
	var seen := {}
	for side in plan["sides"]:
		var faction := str(side["faction"])
		check(not side["members"].is_empty(), "%s：%s 方没有武将" % [label, faction])
		check(side["members"].has(side["leader"]), "%s：%s 方主帅 %s 不在本方" % [label, faction, side["leader"]])
		for id in side["members"]:
			check(str(officers[id]["faction"]) == faction, "%s：%s 被划进 %s 方" % [label, id, faction])
			check(not seen.has(id), "%s：%s 两边都在" % [label, id])
			seen[id] = true


func _initialize() -> void:
	var book := roster()
	var config: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/war/xiaopei_battle.json"))
	var declared: Array = config["sides"]
	var plan := Sides.plan(book.officers, declared, first)
	check_plan(book.officers, declared, plan, "小沛")
	var factions: Array = declared.map(func(side): return str(side["faction"]))
	var outsiders: Array = book.officers.values().filter(func(o): return not factions.has(str(o.get("faction", ""))) and not bool(o.get("generated", false)))
	check(not outsiders.is_empty(), "名册里应有未参战势力的人物卡（否则第 1 条的排除没被检验）")
	for side in plan["sides"]:
		var spec: Dictionary = declared.filter(func(d): return d["faction"] == side["faction"])[0]
		if book.officers.has(str(spec.get("leader", ""))) and str(book.officers[spec["leader"]]["faction"]) == side["faction"]:
			check(side["leader"] == spec["leader"], "%s 方应由声明的主帅 %s 统领" % [side["faction"], spec["leader"]])
		var named: Array = side["members"].filter(func(id): return not bool(book.officers[id].get("generated", false)))
		check(bool(side["filled"]) == named.is_empty(), "%s 方补位标记与成员不符" % side["faction"])
		print("SIDES 小沛 %s：%d 人（人物卡 %d）主帅 %s%s" % [side["faction"], side["members"].size(), named.size(), book.officers[side["leader"]]["name"], "（生成将补位）" if side["filled"] else ""])
	for warning in plan["warnings"]: print("SIDES 告警：" + warning)
	check(plan["sides"].any(func(side): return side["filled"]) == plan["warnings"].any(func(w): return w.contains("生成将")), "补位必须伴随告警")

	# 声明的主帅不在本方：告警并由本方择帅。
	var wrong := declared.duplicate(true)
	var foreign: String = plan["sides"][1]["members"][0]
	wrong[0]["leader"] = foreign
	var replanned := Sides.plan(book.officers, wrong, first)
	check_plan(book.officers, wrong, replanned, "主帅错方")
	check(replanned["sides"][0]["leader"] != foreign and replanned["warnings"].any(func(w): return w.contains(foreign)), "主帅不在本方时应告警并改由本方择帅")

	# 只有生成将的势力：补位；连生成将都没有：报错且不建任何一方。
	var officers := {
		"a1": {"id": "a1", "faction": "alpha"},
		"a2": {"id": "a2", "faction": "alpha"},
		"g1": {"id": "g1", "faction": "beta", "generated": true},
		"m1": {"id": "militia:beta:x", "faction": "beta"},
	}
	var pair := [{"faction": "alpha", "role": "defender", "leader": "a2"}, {"faction": "beta", "role": "attacker", "leader": ""}]
	var filled := Sides.plan(officers, pair, first)
	check_plan(officers, pair, filled, "补位")
	check(filled["sides"][0]["leader"] == "a2" and not filled["sides"][0]["filled"], "有人物卡武将的一方不补位")
	check(filled["sides"][1]["members"] == ["g1"] and filled["sides"][1]["filled"], "无人物卡武将的一方用生成将补位，不收乡勇")
	check(filled["warnings"].size() == 1, "补位告警一条：%s" % str(filled["warnings"]))
	var empty := Sides.plan(officers, [pair[0], {"faction": "gamma", "role": "attacker", "leader": ""}], first)
	check(not str(empty["error"]).is_empty() and empty["sides"].is_empty(), "一方无任何武将时应报错且不建军")
	print("SIDES 无武将：" + str(empty["error"]))
	var twice := Sides.plan(officers, [pair[0], {"faction": "alpha", "role": "attacker", "leader": ""}], first)
	check(not str(twice["error"]).is_empty(), "同一势力不能两边都参战")
	var roles := Sides.plan(officers, [pair[0], {"faction": "beta", "role": "defender", "leader": ""}], first)
	check(not str(roles["error"]).is_empty(), "必须恰好一方守、一方攻")

	# 人物卡带 faction_id：优先于显示名映射。
	var card: Dictionary = Repository.cards()[0]
	card["faction_id"] = "alpha"
	var direct := Roster.new()
	direct.setup([card], {str(card["faction"]): "beta"})
	check(direct.officers[str(card["id"])]["faction"] == "alpha", "人物卡的 faction_id 应优先于 faction 显示名映射")
	card.erase("faction_id")
	direct.setup([card], {str(card["faction"]): "beta"})
	check(direct.officers[str(card["id"])]["faction"] == "beta", "没有 faction_id 时按 faction_mapping 映射")

	print("BATTLE_SIDES_VALIDATION: " + ("PASS" if failures.is_empty() else "FAIL %d 项" % failures.size()))
	quit(0 if failures.is_empty() else 1)
