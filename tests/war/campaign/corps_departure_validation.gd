extends SceneTree
## 回归：新建军团出发当日不应整体撤退（见 docs/validation/演示军团当日撤退-诊断.md）。
##
## A. 演示剧本纯规则推进 21 日：第 10、20 日两批新建军团当日不出现「部队单独撤退、代理主帅接着撤」的连锁；
##    第 10 日这批次日多数仍在征途且已离开出发城。修复前全图敌军都算进危险度，两批军团当日几乎全部撤完。
## B. 尚未启程的军团，邻城驻有数倍于己的敌军：主帅当日判断撤退，整支军团取消出征、兵员回城，
##    不经「代理主帅」逐个接任再撤；兵员守恒。

const Store = preload("res://scripts/core/game_state.gd")
var failures: Array[String] = []


func _initialize() -> void: call_deferred("_run")


func check(value: bool, message: String) -> void:
	if not value:
		failures.append(message)
		push_error(message)


func _run() -> void:
	await _departure_waves()
	_cancelled_before_departure()
	if failures.is_empty(): print("CORPS_DEPARTURE_OK: new corps keep marching after the dispatch day; a corps withdrawing before departure is cancelled as a whole")
	quit(0 if failures.is_empty() else 1)


## A：每批（同日新建 3 支以上）军团。建成当日：结束的部队只能是整支军团取消出征，不能单支撤退、由代理主帅接着撤；
## 第 10 日这一批（开局后第一次出兵，周边还没有敌方野战军）次日多数仍在征途，并且已经离开出发城。
## 之后的批次会遇到真正在附近的敌军，取消出征是合理的，只检查不出现逐个接任的连锁撤退。
func _departure_waves() -> void:
	var sandbox := Store.new()
	sandbox.persist_enabled = false
	sandbox._load_demo()
	var war = sandbox.war
	var waves := {}
	for day in 21:
		await war.step(null)
		var tick := int(war.state["tick"])
		for corps in war.state["corps"].values():
			var formed_at := int(corps.get("formed_at", -1))
			if formed_at != tick and formed_at != tick - 1: continue
			var wave: Dictionary = waves.get(formed_at, {"formed": 0, "on_campaign": 0, "left_home": 0, "chain": 0})
			var root: Dictionary = war.state["armies"][corps["root_id"]]
			if formed_at == tick:
				wave["formed"] += 1
				var ended: Array = corps["units"].filter(func(id): return str(war.state["armies"][id]["status"]) == "ended")
				var cancelled: bool = bool(corps.get("ended", false)) and ended.size() == corps["units"].size() and ended.all(func(id): return str(war.state["armies"][id]["outcome"]) == "取消出征")
				if (not ended.is_empty() and not cancelled) or corps["appointments"].values().has("代理主帅"): wave["chain"] += 1
			elif str(root["status"]) != "ended" and not bool(root["returning"]):
				wave["on_campaign"] += 1
				if str(root["location"].get("edge", "")) != "" or str(root["location"]["node"]) != str(root["home"]): wave["left_home"] += 1
			waves[formed_at] = wave
	var checked := 0
	for formed_at in waves:
		var wave: Dictionary = waves[formed_at]
		print("DEPARTURE_WAVE day=%d formed=%d on_campaign_next_day=%d left_home=%d same_day_chain=%d" % [formed_at, wave["formed"], wave["on_campaign"], wave["left_home"], wave["chain"]])
		if int(wave["formed"]) < 3: continue
		checked += 1
		check(int(wave["chain"]) == 0, "第%d日新建的军团有%d个当日由部队单独撤退或代理主帅接任（应整体取消出征）" % [formed_at, wave["chain"]])
	check(checked >= 2, "演示剧本 21 日内应有两批（第 10、20 日）新建军团，实际 %d 批" % checked)
	var first: Dictionary = waves.get(10, {"formed": 0, "on_campaign": 0, "left_home": 0})
	check(int(first["formed"]) >= 3 and int(first["on_campaign"]) * 2 > int(first["formed"]), "第10日新建的%d个军团次日只剩%d个仍在征途" % [first["formed"], first["on_campaign"]])
	check(int(first["left_home"]) * 2 > int(first["formed"]), "第10日新建的%d个军团次日只有%d个离开出发城" % [first["formed"], first["left_home"]])
	sandbox.free()


## B：军团还在出发城时主帅撤退 = 取消出征。
func _cancelled_before_departure() -> void:
	var sandbox := Store.new()
	sandbox.persist_enabled = false
	sandbox._load_demo()
	var war = sandbox.war
	var player := str(war.state["player_faction"])
	var home := "luoyang"
	var enemy_city := str(war.graph.neighbors(home)[0]["node"])
	var enemy_faction := ""
	for faction in sandbox.scenario["factions"]:
		var id := str(faction["id"]) if faction is Dictionary else str(faction)
		if id != player and war.hostile(id, player) and not war.available_officers(id).is_empty(): enemy_faction = id; break
	check(enemy_faction != "", "演示剧本没有可用的敌对势力")
	if enemy_faction == "": sandbox.free(); return
	sandbox.city_state(home).merge({"faction": player, "garrison": 20000, "units": {"infantry": 20000, "archers": 0, "cavalry": 0}, "grain": 100000}, true)
	sandbox.city_state(enemy_city).merge({"faction": enemy_faction, "garrison": 90000, "units": {"infantry": 90000, "archers": 0, "cavalry": 0}, "grain": 100000}, true)
	# 邻城一支大军，原地未动（还没出发）；它是本军出发城一跳内唯一的敌军。
	var enemy_preview: Dictionary = war.preview_dispatch(enemy_city, home, str(war.available_officers(enemy_faction)[0]["id"]))
	check(bool(enemy_preview.get("ok", false)), "无法在邻城动员敌军：" + str(enemy_preview.get("message", "")))
	if not bool(enemy_preview.get("ok", false)): sandbox.free(); return
	war._mobilize(enemy_preview)
	var garrison_before := int(sandbox.city_state(home)["garrison"])
	var members: Array = war.available_officers(player).filter(func(o): return str(war.state["officer_states"].get(o["id"], {}).get("city", home)) == home).map(func(o): return o["id"])
	if members.size() < 2: members = war.available_officers(player).map(func(o): return o["id"])
	var commander: String = war.Corps.best_member(war, members, "主帅")
	var dispatched: Dictionary = war.dispatch(home, enemy_city, commander, members, true)
	check(bool(dispatched.get("ok", false)), "无法从%s派出军团：%s" % [home, dispatched.get("message", "")])
	if not bool(dispatched.get("ok", false)): sandbox.free(); return
	var corps: Dictionary = war.state["corps"][war.state["armies"][dispatched["army_id"]]["corps_id"]]
	var units: Array = corps["units"].duplicate()
	var sent := 0
	for id in units: sent += war.Combat.strength(war.state["armies"][id])
	check(units.size() >= 2, "测试军团没有展开分队，无法检验逐个接任")
	var tick := int(war.state["tick"]) + 1
	# 随军武将都在出发城，集结 0 日：下一日就是出发日。
	await war.step(null)
	var outcomes := {}
	for id in units:
		var unit: Dictionary = war.state["armies"][id]
		outcomes[str(unit["outcome"])] = int(outcomes.get(str(unit["outcome"]), 0)) + 1
		check(str(unit["status"]) == "ended" and str(unit["location"]["node"]) == home, "%s没有在出发城结束（status=%s node=%s）" % [unit["name"], unit["status"], unit["location"]["node"]])
	print("CANCEL_CHECK tick=%d units=%d outcomes=%s appointments=%s" % [tick, units.size(), JSON.stringify(outcomes), JSON.stringify(corps["appointments"].values())])
	check(outcomes.keys() == ["取消出征"], "未启程军团撤退应整体记为取消出征，实际 %s" % JSON.stringify(outcomes))
	check(bool(corps.get("ended", false)), "取消出征后军团没有结束")
	check(not corps["appointments"].values().has("代理主帅"), "取消出征仍经代理主帅逐个接任")
	check(int(sandbox.city_state(home)["garrison"]) == garrison_before, "取消出征的兵员没有全部回城（动员前守军 %d，出征 %d，回城后 %d）" % [garrison_before, sent, int(sandbox.city_state(home)["garrison"])])
	for officer in corps["members"]:
		check(str(war.state["officer_states"].get(officer, {}).get("status", "")) != "deployed", "取消出征后武将%s仍处于出征状态" % officer)
	sandbox.free()
