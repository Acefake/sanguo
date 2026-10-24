extends SceneTree

const Strategic = preload("res://scripts/war/campaign/strategic_ai.gd")
var failures: Array = []


func check(value: bool, message: String) -> void:
	if not value: failures.append(message); push_error(message)


func _initialize() -> void: call_deferred("_run")


func keyed(decisions: Array) -> Array:
	var out: Array = []
	for decision in decisions: out.append([decision["kind"], decision["faction"], decision["home"], decision["target"], decision["officer"]])
	return out


func _run() -> void:
	var store := preload("res://scripts/core/game_state.gd").new()
	store.persist_enabled = false
	store._load_demo()
	var war = store.war
	war.state["player_faction"] = "liu_bei"
	war.state["tick"] = 10
	var exported: Dictionary = war.export_state()
	# 固定种子/状态下出兵决策可复现。
	var first: Array = Strategic.plan(war, store)
	var first_intel := {}
	for decision in first:
		first_intel[decision["target"]] = war.city_intel(str(decision["target"]))
	check(first.size() > 0, "战略层评估至少产生一次出兵或增援")
	var other := preload("res://scripts/core/game_state.gd").new()
	other.persist_enabled = false
	other._load_demo()
	other.war.setup(other, exported)
	var second: Array = Strategic.plan(other.war, other)
	check(keyed(first) == keyed(second), "同一状态两次评估的出兵决策一致")
	# 不派出已被占用的将领：全体在役军队将官不重复。
	var officer_ids := {}
	var duplicated := false
	for army in war.active_armies():
		var officer_id := str(army["officer_id"])
		if officer_ids.has(officer_id): duplicated = true
		officer_ids[officer_id] = true
	check(not duplicated, "没有重复派出已经在役的将领")
	for decision in first:
		check(str(war.state["officer_states"].get(str(decision["officer"]), {}).get("status", "")) != "available", "出征将领已占用")
	# 战线上限：反复评估后进攻军不超过上限，连续两次评估不越界。
	var cap := int(war.rules["strategy"]["front_limit"])
	for tick in [20, 30, 40]:
		war.state["tick"] = tick
		Strategic.plan(war, store)
		for faction in ["yuan_shao", "sun_jian"]:
			check(war.active_armies(faction).filter(func(army): return (not army.has("corps_id") or war.state["corps"][army["corps_id"]]["root_id"] == army["id"]) and str(army["mission_type"]) == "capture" and not bool(army["returning"])).size() <= cap, "战线上限未被突破（" + faction + "）")
	# 城市与守军数据直接读取实时状态，无观测误差。
	var lord: Dictionary = Strategic.lord_of(war.roster, "yuan_shao")
	check(not lord.is_empty(), "找到势力主公")
	var sample := 5173
	var estimate: int = Strategic.estimate(lord, sample)
	check(estimate == sample, "守军信息应为实时准确兵力")
	var attacks: Array = first.filter(func(decision): return decision["kind"] == "attack")
	check(attacks.size() > 0, "至少产生一次攻势出兵")
	if not attacks.is_empty():
		var attack_decision: Dictionary = attacks[0]
		var known: Dictionary = first_intel[attack_decision["target"]]
		check(int(known["uncertainty"]) == 0 and int(known["strength_estimate"]) == int(known["garrison"]), "城市信息不应含观测误差")
		check(Strategic._known_city(war, str(attack_decision["faction"]), str(attack_decision["target"])) == war.city_intel(str(attack_decision["target"])), "战略层未读取实时城池信息")
	# 性能：单次评估不超过 3 秒。
	var mark := Time.get_ticks_msec()
	war.state["tick"] = 50
	Strategic.plan(war, store)
	check(Time.get_ticks_msec() - mark < 3000, "单次势力评估耗时可接受")
	store.free()
	other.free()
	print("STRATEGIC_AI_VALIDATION: " + ("PASS" if failures.is_empty() else str(failures)))
	quit(0 if failures.is_empty() else 1)
