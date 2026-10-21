class_name CampaignDispatch
extends RefCounted
## 出征与动员：可用武将、出征预览与派遣、从城中抽兵组建军队、守城方自动出兵。
##
## 所有函数都是静态的，第一个参数 war 是 CampaignState 实例（不标类型，避免与它互相引用）。

const Traits = preload("res://scripts/officers/trait_registry.gd")
const Fate = preload("res://scripts/war/campaign/officer_fate.gd")
const Combat = preload("res://scripts/war/battle/combat_system.gd")
const Corps = preload("res://scripts/war/campaign/army_corps.gd")
const Edges = preload("res://scripts/war/campaign/officer_edges.gd")
const Operations = preload("res://scripts/war/campaign/campaign_operations.gd")


## 势力中可以出征的武将，按名字排序。
static func available_officers(war, faction: String) -> Array:
	var result: Array = []
	var deployed: Array = war.active_armies().map(func(army): return army["officer_id"])
	for officer in war.roster.officers.values():
		if str(officer["faction"]) == faction and not deployed.has(officer["id"]) and not Fate.unavailable(war, str(officer["id"])) and not str(officer["id"]).begins_with("militia:") and str(war.state["officer_states"].get(officer["id"], {}).get("status", "available")) == "available":
			result.append(officer)
	result.sort_custom(func(a, b): return str(a["name"]) < str(b["name"]))
	return result


## 校验出征条件并算出兵力、携粮、行军天数；不改动任何状态。
static func preview_dispatch(war, home: String, target: String, officer_id: String, defending: bool = false, troop_count: int = 0) -> Dictionary:
	if war.campaign_finished(): return {"ok": false, "message": "战役已经结束，请开始新的战役"}
	var city: Dictionary = war.store.city_state(home)
	var officer: Dictionary = war.roster.officers.get(officer_id, {})
	var failure: Dictionary = {"ok": false, "message": "请选择可用的主将与本方出发城。"}
	if city.is_empty() or officer.is_empty() or not city.has("garrison") or not war.graph.places.has(target):
		return failure
	if str(city.get("faction", "")) != str(officer.get("faction", "")):
		return failure
	if not defending and str(war.store.city_state(target).get("faction", "")) != str(city["faction"]) and not war.hostile(str(city["faction"]), str(war.store.city_state(target).get("faction", ""))):
		return {"ok": false, "message": "双方处于互不交战关系，不能进攻"}
	if str(war.state["officer_states"].get(officer_id, {}).get("status", "available")) != "available" or war.active_armies().any(func(army): return army["officer_id"] == officer_id) or Fate.unavailable(war, officer_id):
		return {"ok": false, "message": "这位将领已经在执行任务。"}
	var path: Dictionary = war.route(str(city["faction"]), home, target)
	if not bool(path["found"]):
		return {"ok": false, "message": "目标没有可用通路。"}
	if Operations.assembly_days(war, home, [officer_id]) < 0: return {"ok": false, "message": "主将无法从驻地到达出发城"}
	var garrison: int = int(city.get("garrison", 0))
	var reserve: int = maxi(int(war.rules["minimum_reserve"]), int(ceil(garrison * float(war.rules["reserve_ratio"]))))
	var count: int = mini(garrison - reserve, int(garrison * float(war.rules["mobilization_ratio"])))
	var food_per_day: float = float(war.rules["grain_per_soldier_day"])
	var reserve_food: int = int(ceil(reserve * food_per_day * 10))
	var food_available: int = maxi(0, int(city.get("grain", 0)) - reserve_food)
	if war.supply_enabled(): count = mini(count, int(food_available / (food_per_day * 12.0)))
	if count < int(war.rules["minimum_army"]):
		return {"ok": false, "message": "兵力不足，需保留至少 %d 名守军。" % reserve}
	var maximum: int = count
	if troop_count > 0:
		if troop_count < int(war.rules["minimum_army"]) or troop_count > maximum: return {"ok": false, "message": "所选兵力超出可动员范围。"}
		count = troop_count
	var food: int = mini(food_available, int(ceil(count * food_per_day * float(war.rules["carry_days"])) )) if war.supply_enabled() else 0
	return {"ok": true, "message": "", "home": home, "target": target, "officer_id": officer_id, "strength": count, "maximum": maximum, "grain": food, "grain_days": int(food / maxf(count * food_per_day, 1)) if war.supply_enabled() else 999, "reserve": garrison - count, "travel_days": int(ceil(float(path["cost"]) * float(war.rules["route_days_per_cost"]))), "mission_type": "defend" if defending or str(war.store.city_state(target).get("faction", "")) == str(city["faction"]) else "capture"}


## 玩家派遣：预览通过后动员出征，有随军人员时组成军团。
static func dispatch(war, home: String, target: String, officer_id: String, companions: Array = [], as_corps: bool = false, troop_count: int = 0) -> Dictionary:
	companions = companions.filter(func(id): return id != officer_id)
	if war.store.busy:
		return {"ok": false, "message": "日期正在推进，请稍候。"}
	if str(war.store.city_state(home).get("faction", "")) != str(war.state["player_faction"]):
		return {"ok": false, "message": "只能派遣本方城池的军队。"}
	var preview: Dictionary = preview_dispatch(war, home, target, officer_id, false, troop_count)
	if not bool(preview["ok"]):
		return preview
	for id in companions:
		if id == officer_id or not available_officers(war, str(war.state["player_faction"])).any(func(officer): return officer["id"] == id): return {"ok": false, "message": "随军人员包含不可用武将"}
	if Operations.assembly_days(war, home, companions) < 0: return {"ok": false, "message": "随军人员没有可用的调任通路"}
	companions = Corps.select_members(war, officer_id, companions, home)
	var custom_plan: Dictionary = war.state.get("pending_corps_plan", {})
	if not custom_plan.is_empty():
		var validation: Dictionary = Corps.validate_plan(war, officer_id, companions, custom_plan, int(preview["strength"]))
		if not validation.get("ok", false): return validation
	var army: Dictionary = _mobilize(war, preview)
	if as_corps or not companions.is_empty():
		Corps.form(war, army, companions)
		if war.store.persist_enabled and war.store.agent.enabled and war.store.agent.has_method("supports_background_decisions"): Corps.plan_background(war, war.store.agent)
	war._observe_all()
	war._report(army, "出征", "%s奉命从%s出发，带兵%d，目标%s。" % [army["name"], war.graph.name_of(home), int(preview["strength"]), war.graph.name_of(target)], false)
	war.store._save()
	war.store.city_changed.emit(home)
	return {"ok": true, "army_id": army["id"], "message": "军队已出发，行军与作战由主将自主决定。"}


## 按预览从城中抽兵抽粮，登记军队、任务与武将状态，返回新军队。
static func _mobilize(war, preview: Dictionary) -> Dictionary:
	var city: Dictionary = war.store.city_state(str(preview["home"]))
	war._sync_inventory(city)
	var count: int = int(preview["strength"])
	var before: int = int(city["garrison"])
	var units: Dictionary = {"infantry": 0, "archers": 0, "cavalry": 0}
	var remaining: int = count
	for index in range(Combat.TYPES.size()):
		var type: String = Combat.TYPES[index]
		var take: int = mini(int(city["units"][type]), remaining if index == Combat.TYPES.size() - 1 else int(ceil(float(count) * int(city["units"][type]) / maxf(before, 1))))
		take = mini(take, remaining)
		units[type] = take
		city["units"][type] -= take
		remaining -= take
	# Rounding cannot discard unallocated soldiers.
	for type in Combat.TYPES:
		var take: int = mini(remaining, int(city["units"][type]))
		units[type] += take
		city["units"][type] -= take
		remaining -= take
	city["garrison"] = before - count
	if war.supply_enabled(): city["grain"] -= int(preview["grain"])
	var id: String = "army-%04d" % int(war.state["next_id"])
	war.state["next_id"] += 1
	var officer: Dictionary = war.roster.officers[str(preview["officer_id"])]
	var army: Dictionary = {"id": id, "officer_id": officer["id"], "name": officer["name"], "faction": city["faction"], "home": preview["home"], "target": preview["target"], "mission_type": preview["mission_type"], "status": "active", "location": {"node": preview["home"], "edge": "", "progress": 0.0}, "units": units, "initial_strength": count, "dead": 0, "wounded": 0, "captured": 0, "deposited": 0, "training": int(city.get("training", 50)), "equipment": int(city.get("equipment", 50)), "skills": officer["skills"].duplicate(true), "trait_ids": officer.get("trait_ids", []).duplicate(), "grain": float(preview["grain"]) if war.supply_enabled() else 0.0, "morale": 100.0, "organization": 100.0, "fatigue": 0.0, "started": int(war.state["tick"]), "deadline": int(war.state["tick"]) + int(war.rules["mission_days"]), "intel": {"cities": {}, "enemies": {}}, "action": {"type": "hold"}, "last_decision": -10, "last_report": {}, "last_reason": "正在准备出征。", "returning": false, "scouted_at": -10, "siege_progress": 0.0, "outcome": "", "last_support": -10, "trust": 0.0, "resentment": 0.0, "memory": [], "experience": {"enemy_notes": {}, "battle_log": [], "streak": {"wins": 0, "losses": 0}, "drift": {}}}
	var last_victory := int(war.state["battle_victories"].get(str(officer["id"]), -100000))
	army["victory_chain"] = not Traits.mechanism(army, "victory_chain").is_empty() and preview["mission_type"] == "capture" and int(war.state["tick"]) - last_victory <= int(Traits.mechanism(army, "victory_chain").get("window_days", 0))
	army["departure_at"] = int(war.state["tick"]) + Operations.assembly_days(war, str(preview["home"]), [officer["id"]])
	army["deadline"] += maxi(0, int(army["departure_at"]) - int(war.state["tick"]))
	Operations.detach_post(war, str(officer["id"]))
	army["edge"] = Edges.ensure(army, officer, true)
	war.state["armies"][id] = army
	war.state["missions"][id] = {"army_id": id, "home": preview["home"], "target": preview["target"], "status": "active", "type": preview["mission_type"], "result": ""}
	war.state["officer_states"][officer["id"]] = {"status": "commanding", "army_id": id}
	return army


## 敌军逼近且城池方针允许时，守城方自动派兵迎击。
static func _spawn_defenders(war) -> void:
	var approaching: Array = war.active_armies()
	for attacker in approaching:
		if bool(attacker.get("returning", false)) or str(attacker["mission_type"]) != "capture":
			continue
		var target: String = str(attacker["target"])
		var city: Dictionary = war.store.city_state(target)
		var faction: String = str(city.get("faction", ""))
		if faction == "" or not war.hostile(faction, str(attacker["faction"])) or not city.has("population"):
			continue
		var policy: Dictionary = Operations.policy(war, target)
		if policy["defense"] == "hold": continue
		if policy["defense"] == "adaptive" and int(city["garrison"]) < Combat.strength(attacker) * 0.7: continue
		var visible: Array = war.graph.visible_nodes(target)
		var location: Dictionary = attacker["location"]
		if not visible.has(location["node"]) and not visible.has(location.get("to", "")):
			continue
		var exists: bool = false
		for defender in war.active_armies(faction):
			if str(defender["home"]) == target:
				exists = true
		if exists or int(war.state["defense_cooldowns"].get(target, -100)) + 20 > int(war.state["tick"]):
			continue
		var officers: Array = available_officers(war, faction)
		var officer_id: String = str(officers[0]["id"]) if not officers.is_empty() else war.roster.militia(faction, target)
		if Fate.unavailable(war, officer_id): officer_id = war.roster.militia(faction, target + ":" + str(war.state["tick"]))
		var preview: Dictionary = preview_dispatch(war, target, target, officer_id, true)
		if bool(preview["ok"]):
			_mobilize(war, preview)
			war.state["defense_cooldowns"][target] = int(war.state["tick"])
			war.store.city_changed.emit(target)
