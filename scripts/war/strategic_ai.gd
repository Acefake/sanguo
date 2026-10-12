extends RefCounted

# 势力战略 AI：非玩家势力每旬评估一次出兵与增援，复用 preview_dispatch/_mobilize，
# 不另建战争通道。评分使用实时城池与军队信息。

const Battle = preload("res://scripts/war/officer_battle.gd")


static func plan(war, store) -> Array:
	var section: Dictionary = war.rules.get("strategy", {})
	if section.is_empty() or bool(store.get("battle_test")): return []
	var interval := int(section.get("eval_interval", 10))
	if interval < 1 or int(war.state["tick"]) % interval != 0: return []
	var factions := {}
	for node in store.scenario.get("places", {}):
		var name := str(store.city_state(str(node)).get("faction", ""))
		if name != "" and name != str(war.state["player_faction"]): factions[name] = true
	var decisions: Array = []
	var faction_ids: Array = factions.keys()
	faction_ids.sort()
	for faction in faction_ids:
		_govern(war, store, str(faction))
		decisions.append_array(_plan_faction(war, store, str(faction), section))
	_govern(war, store, str(war.state["player_faction"]))
	if not decisions.is_empty():
		if not war.state.has("strategy_log"): war.state["strategy_log"] = []
		for decision in decisions: war.state["strategy_log"].append(decision)
		while war.state["strategy_log"].size() > 40: war.state["strategy_log"].pop_front()
	return decisions


static func lord_of(roster, faction: String, officer_states: Dictionary = {}) -> Dictionary:
	var best := {}
	var best_score := -1.0
	var ids: Array = roster.officers.keys()
	ids.sort()
	for id in ids:
		var officer: Dictionary = roster.officers[id]
		if str(officer["faction"]) != faction or str(officer["id"]).begins_with("militia:"): continue
		if officer_states.get(officer["id"], {}).get("status", "") in ["dead", "captured"]: continue
		var score := Battle.skill(officer, "名望") + Battle.skill(officer, "威仪") * 0.3 + float(officer.get("personality", {}).get("野心", 50)) * 0.1
		if "核心位置：君主" in str(officer.get("positions", "")): score += 50.0
		if score > best_score:
			best_score = score
			best = officer
	return best


static func estimate(_officer: Dictionary, strength: int) -> int:
	return strength

static func _known_city(war, _faction: String, node: String) -> Dictionary:
	return war.city_intel(node)

static func _govern(war, store, faction: String) -> void:
	var cities := _faction_cities(store, faction)
	for attempt in range(3):
		if store.faction_action_points(faction) <= 0: break
		var choices: Array = []
		for node in cities:
			var city: Dictionary = store.city_state(node)
			var policy: Dictionary = war.Operations.policy(war, node)
			if faction == str(war.state["player_faction"]) and not policy["delegated"]: continue
			var action := "develop"
			var priority := 100.0 - float(city.get("economy", 0))
			if int(city.get("order", 0)) < 55: action = "govern"; priority = 200.0 - float(city["order"])
			elif int(city.get("grain", 0)) < 3000: action = "buy_grain"; priority = 180.0
			elif int(city.get("treasury", 0)) < 400 and int(city.get("order", 0)) >= 40: action = "tax"; priority = 160.0
			elif int(city.get("garrison", 0)) < 5000: action = "recruit"; priority = 150.0 - float(city["garrison"]) / 1000.0
			elif int(city.get("defense", 0)) < 50: action = "fortify"; priority = 140.0 - float(city["defense"])
			elif int(city.get("training", 0)) < 65: action = "train"; priority = 120.0 - float(city["training"])
			if policy["rebuild"] == "civil" and int(city.get("order", 0)) < 80: action = "govern"; priority = 190.0
			elif policy["rebuild"] == "military" and int(city.get("equipment", 50)) < 70 and int(city.get("garrison", 0)) >= 5000: action = "forge"; priority = 170.0
			if store.faction_action_error(node, action, faction) == "": choices.append({"node": node, "action": action, "priority": priority})
		if choices.is_empty(): break
		choices.sort_custom(func(a, b): return a["priority"] > b["priority"] if not is_equal_approx(a["priority"], b["priority"]) else a["node"] < b["node"])
		store.apply_faction_action(choices[0]["node"], choices[0]["action"], faction)

static func _city_value(war, faction: String, node: String, section: Dictionary) -> float:
	var known := _known_city(war, faction, node)
	if known.is_empty(): return float(section.get("unscouted_value", 1.0))
	return float(known.get("population", 0)) / 5000.0 + float(known.get("defense", 0)) * 0.2


# 该敌军是否已被本方任何部队看见；未见到的部队不能用来推断威胁。
static func _visible_from_faction(_war, _faction: String, enemy: Dictionary) -> bool:
	return str(enemy.get("status", "active")) != "ended"

static func lord_orders(lord: Dictionary, posture: String) -> Dictionary:
	var personality: Dictionary = lord.get("personality", {})
	var ambition := float(personality.get("野心", 50))
	var risk := float(personality.get("风险承受", 50))
	var control := float(personality.get("自制", 50))
	var suspicion := float(personality.get("猜疑", 50))
	var intent := "稳扎"
	if ambition >= 60.0 and risk >= 50.0: intent = "速胜"
	elif risk <= 35.0: intent = "保存实力"
	elif suspicion >= 65.0: intent = "牵制"
	var allowance := "常规"
	if risk >= 70.0 and ambition >= 60.0: allowance = "放手"
	elif control >= 65.0 or risk <= 30.0: allowance = "保守"
	var line := {"strength": 0.35, "morale": 20.0} if posture == "attack" else {"strength": 0.5, "morale": 25.0}
	return {"engage": true, "retreat": true, "pursue": true, "after_battle": "withdraw", "intent": intent, "risk_allowance": allowance, "retreat_line": line, "report_level": "重大事件"}


static func _faction_cities(store, faction: String) -> Array:
	var result: Array = []
	for node in store.scenario.get("places", {}):
		var city: Dictionary = store.city_state(str(node))
		if city.has("population") and str(city.get("faction", "")) == faction: result.append(str(node))
	result.sort()
	return result


static func _front_count(war, faction: String) -> int:
	var count := 0
	for army in war.active_armies(faction):
		if army.has("corps_id") and war.state["corps"][army["corps_id"]]["root_id"] != army["id"]: continue
		if str(army["mission_type"]) == "capture" and not bool(army["returning"]): count += 1
	return count


static func _distances(graph, sources: Array) -> Dictionary:
	var distance := {}
	var origin := {}
	for source in sources:
		distance[source] = 0.0
		origin[source] = source
	var visited := {}
	while true:
		var best := ""
		var best_cost := INF
		for node in distance:
			if visited.has(node): continue
			if float(distance[node]) < best_cost:
				best_cost = float(distance[node])
				best = str(node)
		if best == "": break
		visited[best] = true
		for link in graph.neighbors(best):
			var next := str(link["node"])
			var cost := float(distance[best]) + float(graph.edges[link["edge"]].get("cost", 1))
			if not distance.has(next) or cost < float(distance[next]):
				distance[next] = cost
				origin[next] = origin[best]
	return {"distance": distance, "origin": origin}


static func _plan_faction(war, store, faction: String, section: Dictionary) -> Array:
	var decisions: Array = []
	var cities := _faction_cities(store, faction)
	if cities.is_empty(): return decisions
	var officers: Array = war.available_officers(faction).filter(func(officer): return not str(officer["id"]).begins_with("militia:"))
	if officers.is_empty(): return decisions
	officers.sort_custom(func(a, b): return float(a["skills"].get("带兵", 50)) + float(a["skills"].get("智计", 50)) + float(a["skills"].get("名望", 50)) > float(b["skills"].get("带兵", 50)) + float(b["skills"].get("智计", 50)) + float(b["skills"].get("名望", 50)))
	var lord := lord_of(war.roster, faction, war.state["officer_states"])
	var defense := _defend(war, store, faction, cities, officers, lord, section)
	if not defense.is_empty(): decisions.append(defense)
	if _front_count(war, faction) < int(section.get("front_limit", 2)):
		var attack := _attack(war, store, faction, cities, officers, lord, section)
		if not attack.is_empty(): decisions.append(attack)
	return decisions


static func _attack(war, store, faction: String, cities: Array, officers: Array, lord: Dictionary, section: Dictionary) -> Dictionary:
	var graph = war.graph
	var reach := _distances(graph, cities)
	var distance: Dictionary = reach["distance"]
	var origin: Dictionary = reach["origin"]
	var targets: Array = []
	for node in store.scenario.get("places", {}):
		var id := str(node)
		if not distance.has(id): continue
		var city: Dictionary = store.city_state(id)
		if not city.has("garrison") or not war.hostile(faction, str(city.get("faction", ""))): continue
		targets.append({"node": id, "cost": float(distance[id]), "home": str(origin[id])})
	# JSON saves reorder dictionary keys. Resolve equal travel costs by city ID
	# before sampling, so reloads retain the same set of possible attack targets.
	targets.sort_custom(func(a, b): return a["cost"] < b["cost"] if not is_equal_approx(a["cost"], b["cost"]) else a["node"] < b["node"])
	targets = targets.slice(0, int(section.get("target_sample", 10)))
	var aggression := ((float(lord.get("personality", {}).get("野心", 50)) + float(lord.get("personality", {}).get("风险承受", 50))) / 2.0 - 50.0) / 50.0
	var fronts := float(_front_count(war, faction))
	var best: Dictionary = {}
	for target in targets:
		var known := _known_city(war, faction, str(target["node"]))
		if known.is_empty(): continue
		for officer in officers:
			var preview: Dictionary = war.preview_dispatch(target["home"], target["node"], str(officer["id"]))
			if not bool(preview["ok"]): continue
			var estimate := int(known.get("garrison", 0))
			var strength := maxf(float(preview["strength"]), 1.0)
			var ratio := float(estimate) / strength
			if ratio > float(section.get("max_ratio", 1.8)): continue
			if float(preview["grain_days"]) < float(section.get("min_grain_days", 20)): continue
			var value := _city_value(war, faction, str(target["node"]), section)
			var command_score: float = war.Corps.suitability(officer, "主帅") * 0.10
			var assembly: int = war.Operations.assembly_days(war, str(target["home"]), [officer["id"]])
			if assembly < 0: continue
			var score: float = command_score - assembly * 0.5 + 25.0 + value - ratio * 25.0 - float(target["cost"]) * 0.6 - fronts * 8.0 + aggression * 15.0
			if score <= float(section.get("threshold", 0.0)): continue
			if best.is_empty() or score > float(best["score"]):
				best = {"score": score, "home": target["home"], "target": target["node"], "officer": officer, "preview": preview, "estimate": estimate, "ratio": ratio}
	if best.is_empty(): return {}
	var preview: Dictionary = best["preview"]
	var army: Dictionary = war._mobilize(preview)
	army["orders"] = lord_orders(lord, "attack")
	_form_corps(war, army)
	army["last_reason"] = "势力战略：攻取%s（守军%d，评分%.1f）" % [war.graph.name_of(str(best["target"])), int(best["estimate"]), float(best["score"])]
	war._report(army, "势力出兵", "%s率兵%d出征%s。" % [army["name"], int(preview["strength"]), war.graph.name_of(str(best["target"]))], false)
	return {"kind": "attack", "tick": int(war.state["tick"]), "faction": faction, "home": str(best["home"]), "target": str(best["target"]), "officer": str(best["officer"]["id"]), "estimate": int(best["estimate"]), "score": float(best["score"]), "army_id": str(army["id"])}


static func _defend(war, store, faction: String, cities: Array, officers: Array, lord: Dictionary, section: Dictionary) -> Dictionary:
	var graph = war.graph
	for node in cities:
		var city: Dictionary = store.city_state(str(node))
		if int(city.get("garrison", 0)) <= int(war.rules.get("minimum_reserve", 1000)): continue
		var covered := false
		for army in war.active_armies(faction):
			if str(army["target"]) == str(node) and str(army["mission_type"]) == "defend" and not bool(army["returning"]): covered = true
		if covered: continue
		var threatened := false
		for enemy in war.active_armies():
			if not war.hostile(str(enemy["faction"]), faction) or bool(enemy["returning"]): continue
			if not _visible_from_faction(war, faction, enemy): continue
			var location: Dictionary = enemy["location"]
			var near := str(location.get("node", "")) == str(node) or str(location.get("to", "")) == str(node)
			if not near: continue
			threatened = true
			break
		if not threatened: continue
		for home in cities:
			if str(home) == str(node): continue
			var home_city: Dictionary = store.city_state(str(home))
			if int(home_city.get("garrison", 0)) <= int(war.rules.get("minimum_reserve", 1000)): continue
			for officer in officers:
				var preview: Dictionary = war.preview_dispatch(str(home), str(node), str(officer["id"]), true)
				if not bool(preview["ok"]): continue
				var army: Dictionary = war._mobilize(preview)
				army["orders"] = lord_orders(lord, "defend")
				_form_corps(war, army)
				army["last_reason"] = "势力战略：增援%s" % graph.name_of(str(node))
				war._report(army, "势力增援", "%s率兵%d增援%s。" % [army["name"], int(preview["strength"]), graph.name_of(str(node))], false)
				return {"kind": "defend", "tick": int(war.state["tick"]), "faction": faction, "home": str(home), "target": str(node), "officer": str(officer["id"]), "estimate": 0, "score": 0.0, "army_id": str(army["id"])}
	return {}

static func _form_corps(war, army: Dictionary) -> void:
	var candidates: Array = war.available_officers(str(army["faction"])).filter(func(o): return not str(o["id"]).begins_with("militia:")).map(func(o): return o["id"])
	var companions: Array = war.Corps.select_members(war, str(army["officer_id"]), candidates, str(army["home"]))
	war.Corps.form(war, army, companions, true)
