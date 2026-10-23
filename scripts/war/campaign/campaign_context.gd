class_name CampaignContext
extends RefCounted
## 观察与决策上下文：情报刷新、战线职责分配、给决策用的观察快照与候选行动、决策校验与重判门槛。
##
## 所有函数都是静态的，第一个参数 war 是 CampaignState 实例（不标类型，避免与它互相引用）。

const Combat = preload("res://scripts/war/battle/combat_system.gd")
const Corps = preload("res://scripts/war/campaign/army_corps.gd")
const Tactical = preload("res://scripts/war/battle/tactical_battlefield.gd")
const ReportPolicy = preload("res://scripts/war/campaign/report_policy.gd")
const Dissent = preload("res://scripts/agents/officer_dissent.gd")
const Forecast = preload("res://scripts/agents/forecast.gd")
const Experience = preload("res://scripts/agents/experience.gd")
const StateKeys = preload("res://scripts/war/campaign/war_state_keys.gd")
const ObservationReuse = preload("res://scripts/war/campaign/observation_reuse.gd")


## 城池情报（全图实时可见）。
static func city_intel(war, node: String) -> Dictionary:
	var city: Dictionary = war.store.city_state(node)
	if city.is_empty(): return {}
	var result := city.duplicate(true)
	result["node"] = node
	result["strength_estimate"] = int(city.get("garrison", 0))
	result["uncertainty"] = 0
	result["observed_at"] = int(war.state[StateKeys.TICK])
	result["source"] = "live_state"
	return result


## 敌军情报（全图实时可见）。
static func enemy_intel(war, enemy: Dictionary) -> Dictionary:
	var result := {"id": enemy["id"], "location": enemy["location"].duplicate(true), "strength_estimate": Combat.strength(enemy), "observed_at": int(war.state[StateKeys.TICK]), "uncertainty": 0, "routing": bool(enemy.get("returning", false)), "fighting": int(enemy.get("combat_tick", -1)) == int(war.state[StateKeys.TICK]), "unit_mix_estimate": enemy["units"].duplicate(true), "source": "live_state"}
	if enemy.has("tactical"): result["tactical_cell"] = int(enemy["tactical"]["cell"])
	return result


## 玩家看到的城池情报，与 city_intel 相同。
static func player_city_intel(war, node: String) -> Dictionary:
	return city_intel(war, node)


## 城池是否为玩家势力所有。
static func player_has_city_access(war, node: String) -> bool:
	return not war.store.city_state(node).is_empty() and str(war.store.city_state(node).get("faction", "")) == str(war.state[StateKeys.PLAYER_FACTION])


## 刷新每支在役军队的城池与敌军情报。城池情报没变时沿用上一份（见 observation_reuse.gd）。
static func _observe_all(war) -> void:
	Tactical.clear_target_cache()
	var cities := {}
	for node in war.store.scenario.get("places", {}):
		cities[node] = city_intel(war, str(node))
	var armies: Array = war.active_armies()
	for army in armies:
		# Keep the intelligence schema for saves and decision snapshots, with no sight limits.
		army["intel"] = {"cities": ObservationReuse.cities_for(army.get("intel"), cities), "enemies": {}}
		for enemy in armies:
			if war.hostile(str(enemy["faction"]), str(army["faction"])):
				army["intel"]["enemies"][enemy["id"]] = enemy_intel(war, enemy)
	ReportPolicy.observe(war)


## 给相邻作战的友军编组并分配职责（主攻、侧翼、支援、预备、殿后）与建议目标。
static func _update_operations(war) -> void:
	if not war.state[StateKeys.CORPS].is_empty(): Corps.update(war)
	var assigned := {}
	for anchor in war.active_armies():
		if anchor.has("corps_id"): continue
		if assigned.has(anchor["id"]): continue
		var group: Array = []
		for friend in war.active_armies(str(anchor["faction"])):
			if not friend.has("corps_id") and not assigned.has(friend["id"]) and _near_battle(war, anchor["location"], friend["location"]): group.append(friend)
		group.sort_custom(func(a, b):
			var left := int(a["skills"].get("带兵",50))+int(a["skills"].get("治军",50))-(10000 if a["returning"] else 0)
			var right := int(b["skills"].get("带兵",50))+int(b["skills"].get("治军",50))-(10000 if b["returning"] else 0)
			return left > right if left != right else str(a["id"]) < str(b["id"]))
		if group.is_empty(): continue
		var covered_retreats := {}
		for index in range(group.size()):
			var army: Dictionary = group[index]
			assigned[army["id"]] = true
			var operation: Dictionary = army.get("operation", {})
			var previous_role: String = str(operation.get("role", ""))
			var role := "main_attack" if index < 2 else "flank" if index == 2 else "support" if index < group.size() - 1 else "reserve"
			if army.has("tactical"): role = army["tactical"]["role"]
			var fleeing: Array = group.filter(func(friend): return bool(friend["returning"]))
			var covered_friend := ""
			if role in ["reserve", "support"] and not fleeing.is_empty() and not bool(army["returning"]):
				if army.has("tactical"):
					fleeing.sort_custom(func(a, b): return Tactical.distance(army, a) < Tactical.distance(army, b))
					for friend in fleeing:
						if not covered_retreats.has(friend["id"]) and Tactical.distance(army, friend) <= 3:
							covered_friend = friend["id"]
							covered_retreats[covered_friend] = true
							role = "rear_guard"
							break
				else:
					role = "rear_guard"
					covered_friend = fleeing[0]["id"]
			if army.get("tactical", {}).get("role", "") == "reserve":
				var frontline: Array = group.filter(func(friend): return friend.get("tactical", {}).get("role", "") == "main_attack" and not friend["returning"])
				if frontline.size() < 2: role = "main_attack"
			operation["role"] = "withdraw" if bool(army["returning"]) else role
			operation["role_label"] = Tactical.ROLES.get(operation["role"], "自主行动")
			operation["commander"] = group[0]["id"]
			operation["support_id"] = group[0]["id"] if index > 0 else ""
			if army.has("tactical") and role == "support": operation["support_id"] = army["tactical"]["support_id"]
			if role == "rear_guard": operation["support_id"] = covered_friend
			operation["objective"] = war.graph.name_of(str(army["target"]))
			# JSON saves reorder dictionary keys. Target assignment must depend on
			# current sightings and explicit tie-breaks, never their insertion order.
			var enemies: Array = army["intel"]["enemies"].values().filter(func(sight): return int(sight.get("observed_at",-1)) == int(war.state[StateKeys.TICK]))
			enemies.sort_custom(func(a,b): return str(a["id"]) < str(b["id"]))
			if army.has("tactical"):
				enemies.sort_custom(func(a, b):
					var left := Tactical.cell_distance(int(army["tactical"]["cell"]),int(a.get("tactical_cell",-1))) if int(a.get("tactical_cell",-1)) >= 0 else 10000
					var right := Tactical.cell_distance(int(army["tactical"]["cell"]),int(b.get("tactical_cell",-1))) if int(b.get("tactical_cell",-1)) >= 0 else 10000
					return left < right if left != right else str(a["id"]) < str(b["id"]))
				var previous_target: String = str(operation.get("suggested_target", ""))
				if not enemies.any(func(sight): return sight["id"] == previous_target): operation["suggested_target"] = enemies[0]["id"] if not enemies.is_empty() else ""
			else: operation["suggested_target"] = enemies[index % enemies.size()]["id"] if not enemies.is_empty() else ""
			operation["plan_until"] = operation.get("plan_until", 0)
			operation["change_reason"] = operation.get("change_reason", "主帅按部队能力安排作战职责")
			if previous_role != "" and previous_role != operation["role"]:
				operation["change_reason"] = "战线发生变化，职责调整为" + operation["role_label"]
				operation["plan_until"] = 0
			army["operation"] = operation


## 两个位置是否近到可算同一战场。
static func _near_battle(war, a: Dictionary, b: Dictionary) -> bool:
	var edge_a := str(a.get("edge", ""))
	var edge_b := str(b.get("edge", ""))
	if edge_a != "" and edge_a == edge_b:
		return absf(war._edge_coordinate(a) - war._edge_coordinate(b)) <= 0.3
	if edge_a == "" and edge_b == "": return a["node"] == b["node"]
	if edge_a == "": return _near_battle(war, b, a)
	if edge_b != "": return false
	return (b["node"] == a.get("from", "") and float(a.get("progress", 0)) <= 0.3) or (b["node"] == a.get("to", "") and float(a.get("progress", 0)) >= 0.7)


## 友军支援情况与战场兵力对比。
static func _support_context(war, army: Dictionary) -> Dictionary:
	var allies: Array = []
	var ready := Combat.strength(army)
	var nearby: Array = war.graph.visible_nodes(str(army["location"]["node"]), 1)
	for friend in war.active_armies(str(army["faction"])):
		if friend["id"] == army["id"]: continue
		var local := _near_battle(war, army["location"], friend["location"])
		if army.has("tactical") and friend.has("tactical"): local = Tactical.distance(army, friend) <= 5
		if not local and not nearby.has(friend["location"]["node"]): continue
		var available: bool = not bool(friend["returning"]) and float(friend["morale"]) >= 30 and float(friend["organization"]) >= 25 and (not war.supply_enabled() or float(friend["grain"]) > 0) and bool(war.orders_for(friend)["engage"])
		if friend.get("operation", {}).get("role", "") == "reserve" and friend["action"]["type"] == "hold": available = false
		var strength := Combat.strength(friend)
		if local and available: ready += strength
		allies.append({"id": friend["id"], "name": friend["name"], "strength": strength, "location": friend["location"].duplicate(true), "morale": friend["morale"], "organization": friend["organization"], "returning": friend["returning"], "last_action": friend["action"].duplicate(true), "target": war.graph.name_of(str(friend["target"])), "near_battle": local, "can_support": local and available, "reinforcement_possible": not local and available, "role": friend.get("operation", {}).get("role", ""), "tactical_cell": int(friend.get("tactical", {}).get("cell", -1))})
	var enemy_total := 0
	var uncertainty := 0
	for enemy in army["intel"]["enemies"].values():
		if army.has("tactical") and int(enemy.get("tactical_cell", -1)) >= 0:
			var cell: int = int(army["tactical"]["cell"])
			var enemy_cell: int = int(enemy["tactical_cell"])
			if Tactical.cell_distance(cell, enemy_cell) > 5: continue
		if not bool(enemy.get("routing", false)) and _near_battle(war, army["location"], enemy["location"]):
			enemy_total += int(enemy["strength_estimate"])
			uncertainty += int(enemy.get("uncertainty", 0))
	return {"allies": allies, "battlefield": {"friendly_ready_strength": ready, "enemy_estimated_strength": enemy_total, "enemy_strength_min": maxi(0, enemy_total - uncertainty), "enemy_strength_max": enemy_total + uncertainty, "enemy_to_friendly_ratio": float(enemy_total) / maxf(ready, 1), "note": "友军计划为上一轮行动；可支援表示邻近且状态允许，不保证本轮行动。远处援军与撤退、低士气、低组织、断粮友军不计入可用兵力。敌军兵力为实时信息。"}}


## 只依据已观测敌情的接敌状态（相邻、被夹击、撤离准备）。
static func _observed_contact(war, army: Dictionary) -> Dictionary:
	var cell := int(army.get("tactical", {}).get("cell", -1))
	if cell < 0: return {"adjacent_enemies": 0, "engaged_by": [], "flanked": false, "attackers": 0, "required_preparation": 0}
	var engaged: Array = []
	var adjacent := 0
	var attackers := 0
	var cover := 0
	var flanked := false
	var observed: Dictionary = army.get("intel", {}).get("enemies", {})
	for record in observed.values():
		# Old sightings remain intelligence, but cannot pin a formation in
		# immediate melee after the opponent has left or ceased reporting.
		if int(record.get("observed_at",-100)) < int(war.state[StateKeys.TICK])-1: continue
		var enemy_cell := int(record.get("tactical_cell", -1))
		if enemy_cell >= 0 and enemy_cell == cell: continue
		if enemy_cell < 0: continue
		var separation := Tactical.cell_distance(cell, enemy_cell)
		if separation <= 1: adjacent += 1
		if separation <= 1 and not bool(record.get("routing", false)):
			engaged.append(str(record.get("id", "")))
			attackers += 1
		if separation <= 2 and not bool(record.get("routing", false)): flanked = true
	# Observed friendly rear guards count as cover, matching contact_state's intent.
	for other in war.active_armies(str(army["faction"])):
		if other["id"] == army["id"] or not other.has("tactical"): continue
		if bool(other["returning"]) or str(other.get("operation", {}).get("role", "")) != "rear_guard": continue
		if Tactical.cell_distance(cell, int(other["tactical"]["cell"])) <= 1: cover += 1
	# context_for hands required_preparation to the forecast for withdraw candidates, so
	# the key has to stay present or disengagement would look free.
	var preparation := maxi(1, 1 + maxi(0, attackers - cover))
	return {"adjacent_enemies": adjacent, "engaged_by": engaged, "flanked": flanked, "attackers": attackers, "covered_by": cover, "required_preparation": preparation}


## 给决策用的完整观察快照，含按军令过滤后的候选行动。
static func context_for(war, army: Dictionary) -> Dictionary:
	var target: String = str(army["home"] if bool(army["returning"]) else army["target"])
	var location: Dictionary = army["location"]
	var own: Dictionary = {"strength": Combat.strength(army), "initial_strength": int(army.get("initial_strength", 0)), "units": army["units"].duplicate(true), "morale": army["morale"], "organization": army["organization"], "fatigue": army["fatigue"], "grain_days": war.food_days(army), "location": location.duplicate(true), "training": army["training"], "equipment": army["equipment"]}
	if army.has("tactical"):
		own["cell"] = int(army["tactical"]["cell"])
		own["blocked"] = army["tactical"]["blocked"]
		own["blocked_days"] = int(army["tactical"].get("blocked_days", 0))
		own["phase"] = army["tactical"]["phase"]
		# Observed contact only. contact_state() counts adjacent enemies by true
		# distance, and this drives model-call gating and escape readiness, so
		# feeding it unobserved truth let the harness spend calls on hidden threats.
		own["contact"] = _observed_contact(war, army)
		own["withdraw_preparation"] = army["tactical"].get("withdraw_preparation", 0)
	var candidates: Array = []
	var support := _support_context(war, army)
	var operation: Dictionary = army.get("operation", {})
	if army.has("tactical"):
		_add_candidate(war, candidates, "hold", {"type": "hold"}, "保持战线或预备位置，等待战局变化。")
		var partner: String = str(operation.get("support_id", ""))
		if partner != "" and operation.get("role", "") in ["support", "rear_guard"]:
			var partner_army: Dictionary = war.state[StateKeys.ARMIES].get(partner, {})
			var relation_name := Dissent.relation(war.roster.officers.get(str(army["officer_id"]), {}), war.roster.officers.get(str(partner_army.get("officer_id", "")), {}))
			_add_candidate(war, candidates, "support:" + partner, {"type": "support", "ally": partner}, "跟随指定友军提供远程支援。", {"relation": relation_name})
	if str(location.get("edge", "")) != "":
		_add_candidate(war, candidates, "continue", {"type": "continue"}, "按既定计划继续行军。")
	else:
		_add_candidate(war, candidates, "hold", {"type": "hold"}, "驻守当前位置，整顿组织并恢复疲劳。")
		var current: String = str(location["node"])
		var current_path: Dictionary = war.route(str(army["faction"]), current, target)
		for link in war.graph.neighbors(current):
			var node: String = str(link["node"])
			if node != target and not war.can_cross(str(army["faction"]), node): continue
			var alternative: Dictionary = war.route(str(army["faction"]), node, target)
			if not alternative["found"]: continue
			_add_candidate(war, candidates, "march:" + node, {"type": "march", "target": node, "edge": link["edge"]}, "向%s行军，按局势选择通路。" % war.graph.name_of(node), {"progress_gain": float(current_path.get("cost", 0)) - float(alternative.get("cost", 999))})
		var city: Dictionary = war.store.city_state(current)
		if str(city.get("faction", "")) == str(army["faction"]) and int(city.get("grain", 0)) > 0:
			_add_candidate(war, candidates, "resupply", {"type": "resupply"}, "在友城补充携粮。")
		if current == str(army["target"]) and str(army["mission_type"]) == "capture" and war.hostile(str(city.get("faction", "")), str(army["faction"])):
			var intel: Dictionary = army["intel"]["cities"].get(current, {})
			_add_candidate(war, candidates, "besiege", {"type": "besiege"}, "继续围城，寻找攻城机会。", {"defender_ratio": float(intel.get("strength_estimate", 0)) / maxf(Combat.strength(army), 1)})
	for enemy in army["intel"]["enemies"].values():
		var observed: Dictionary = enemy["location"]
		if str(observed.get("node", "")) == str(location["node"]) or str(location.get("edge", "")) != "" and str(observed.get("edge", "")) == str(location["edge"]):
			_add_candidate(war, candidates, "engage:" + str(enemy["id"]), {"type": "engage", "enemy": enemy["id"]}, "与已发现的敌军交战。")
			if army.has("tactical") and operation.get("role", "") == "flank":
				_add_candidate(war, candidates, "flank:" + str(enemy["id"]), {"type": "flank", "enemy": enemy["id"]}, "绕向敌军侧翼，通路被阻挡时重新判断。")
			if bool(enemy.get("routing", false)):
				_add_candidate(war, candidates, "pursue:" + str(enemy["id"]), {"type": "pursue", "enemy": enemy["id"]}, "追击已发现的败退敌军。")
	var orders: Dictionary = war.orders_for(army)
	candidates = candidates.filter(func(candidate):
		var type: String = candidate["action"]["type"]
		if type in ["engage", "flank", "support"] and not bool(orders["engage"]): return false
		if army.has("tactical") and operation.get("role", "") == "flank" and type == "engage":
			# Use the observed cell, not the authoritative one: an unscouted enemy
			# silently removing the option hides it from the officer and the model alike.
			var seen: Dictionary = army.get("intel", {}).get("enemies", {}).get(str(candidate["action"].get("enemy", "")), {})
			var seen_cell := int(seen.get("tactical_cell", -1))
			var own_cell := int(army["tactical"]["cell"])
			if seen_cell >= 0 and own_cell >= 0 and Tactical.cell_distance(own_cell, seen_cell) > 1: return false
		if army.has("tactical") and operation.get("role", "") == "reserve" and type not in ["hold", "scout", "resupply", "request_support"]: return false
		if army.has("tactical") and operation.get("role", "") == "rear_guard" and type not in ["hold", "support", "resupply", "request_support"]: return false
		return type != "pursue" or bool(orders["pursue"])
	)
	candidates = war.filter_candidates(candidates, orders)
	if bool(orders["retreat"]):
		_add_candidate(war, candidates, "withdraw", {"type": "withdraw"}, "保存兵力，撤往安全的本方城池。")
	if int(army["last_support"]) < int(war.state[StateKeys.TICK]) - 7:
		_add_candidate(war, candidates, "request_support", {"type": "request_support"}, "等待支援并向后方报告军情。")
	candidates.sort_custom(func(a, b): return str(a["id"]) < str(b["id"]))
	var forecast_terrain: String = Tactical.terrain_class(int(own.get("cell", 0))) if own.has("cell") else war._terrain(str(location["node"]))
	candidates = candidates.filter(func(c): return war.supply_enabled() or c["action"]["type"] != "resupply")
	Forecast.annotate(war, army, candidates, {"terrain": forecast_terrain, "enemies": army["intel"]["enemies"], "required_preparation": int(own.get("contact", {}).get("required_preparation", 0))})
	# Snapshot arrays are sorted so decision records replay identically after a save round-trip.
	var known_cities: Array = army["intel"]["cities"].values().duplicate(true)
	known_cities.sort_custom(func(a, b): return str(a["node"]) < str(b["node"]))
	var known_enemies: Array = army["intel"]["enemies"].values().duplicate(true)
	known_enemies.sort_custom(func(a, b): return str(a["id"]) < str(b["id"]))
	var local_map: Dictionary = Tactical.board_for(war, army).duplicate()
	# Decision snapshots need geometry, not the growing authoritative battle ledger.
	local_map.erase("log")
	local_map.erase("pending_events")
	return {"request_id": "%s:%d" % [army["id"], int(war.state[StateKeys.TICK])], "army_id": army["id"], "observation_revision": war.state[StateKeys.TICK], "date": war.store.date_text(), "officer": war.roster.officers.get(str(army["officer_id"]), {"id": str(army["officer_id"]), "name": str(army.get("name", "")), "skills": army.get("skills", {}), "personality": {}, "trait_ids": army.get("trait_ids", [])}).duplicate(true), "army": own, "mission_type": army["mission_type"], "objective": war.graph.name_of(target), "at_objective": str(location["node"]) == target and str(location.get("edge", "")) == "", "supply_enabled": war.supply_enabled(), "returning": army["returning"], "target_known": army["intel"]["cities"].has(target), "cities": known_cities, "enemies": known_enemies, "allies": support["allies"], "battlefield": support["battlefield"], "operation": operation.duplicate(true), "orders": orders.duplicate(true), "local_map": local_map.duplicate(true), "current_action": army["action"].duplicate(true), "memory": army["memory"].duplicate(true), "experience": Experience.summary(army), "candidates": candidates}


## 向候选列表追加一个行动。
static func _add_candidate(war, list: Array, id: String, action: Dictionary, description: String, extra: Dictionary = {}) -> void:
	var candidate: Dictionary = {"id": id, "action": action, "description": description}
	candidate.merge(extra)
	list.append(candidate)


## 校验决策结果：请求未过期且选中的是授权候选。
static func validate_decision(war, context: Dictionary, result: Dictionary) -> Dictionary:
	var army: Dictionary = war.state[StateKeys.ARMIES].get(context.get("army_id", ""), {})
	if army.is_empty() or str(army["status"]) == "ended" or int(context.get("observation_revision", -1)) != int(war.state[StateKeys.TICK]) or int(army["last_decision"]) == int(war.state[StateKeys.TICK]):
		return {"ok": false, "message": "行动请求过期或已经执行。"}
	var choice: Variant = result.get("candidate_id", null)
	if not choice is String:
		return {"ok": false, "message": "未返回有效选择。"}
	for candidate in context.get("candidates", []):
		if str(candidate["id"]) == choice:
			return {"ok": true, "action": candidate["action"].duplicate(true)}
	return {"ok": false, "message": "选择了授权范围之外的行动。"}


## 某个决策 key（army:/unit:/corps: 开头）的情境是否仍有效：部队覆没或溃退、军团撤退后不再需要模型答案。
## war_ref 是弱引用，避免 DecisionScheduler 与 CampaignState 互相持有。其他前缀一律视为有效。
static func decision_alive(key: String, war_ref: WeakRef) -> bool:
	var war = war_ref.get_ref()
	if war == null: return false
	var id := key.get_slice(":", 1)
	if key.begins_with("corps:"):
		var corps: Dictionary = war.state[StateKeys.CORPS].get(id, {})
		if corps.is_empty() or corps.get("withdrawing", false): return false
		id = str(corps["root_id"])
	elif not (key.begins_with("army:") or key.begins_with("unit:")):
		return true
	var army: Dictionary = war.state[StateKeys.ARMIES].get(id, {})
	return not army.is_empty() and str(army.get("status", "active")) != "ended" and not bool(army.get("returning", false))


## 今日是否需要重新决策。
static func _should_reconsider(war, army: Dictionary, context: Dictionary, adapter, key: String) -> bool:
	var age := int(war.state[StateKeys.TICK]) - int(army["last_decision"])
	if adapter != null and adapter.has_method("is_ollama") and adapter.is_ollama() and age < 3:
		var own: Dictionary = context["army"]
		var role: String = str(context.get("operation", {}).get("role", ""))
		var urgent: bool = float(own["morale"]) < 30 or float(own["organization"]) < 25 or float(own["grain_days"]) < 4 or int(own.get("blocked_days", 0)) >= 2
		urgent = urgent or role != str(army.get("decision_role", role)) or bool(own.get("contact", {}).get("flanked", false)) and not bool(army.get("decision_flanked", false))
		urgent = urgent or float(context.get("battlefield", {}).get("enemy_to_friendly_ratio", 0)) >= 2.0
		var valid_plan := false
		for candidate in context["candidates"]:
			if candidate["action"] == army["action"]: valid_plan = true
		if not urgent and valid_plan: return false
	return key != str(army.get("decision_key", "")) or age >= 3


## 观察快照的粗粒度签名，签名不变时可沿用上次决策。
static func _decision_key(war, context: Dictionary) -> String:
	var own: Dictionary = context["army"]
	var location: Dictionary = own["location"]
	var enemies: Array = []
	for enemy in context["enemies"]:
		var proximity := -1
		if own.has("cell") and int(enemy.get("tactical_cell", -1)) >= 0:
			var separation := Tactical.cell_distance(int(own["cell"]), int(enemy["tactical_cell"]))
			proximity = 0 if separation <= 1 else 1 if separation <= 3 else 2
		enemies.append([enemy["id"], int(enemy["strength_estimate"]) / 500, enemy["location"].get("node", ""), enemy["routing"], proximity])
	var allies: Array = []
	for friend in context.get("allies", []):
		allies.append([friend["id"], int(friend["strength"]) / 500, friend["can_support"], friend["returning"], friend.get("role", ""), friend["last_action"].get("type", "")])
	var operation: Dictionary = context.get("operation", {})
	var task := [operation.get("role", ""), operation.get("commander", ""), operation.get("support_id", ""), operation.get("suggested_target", "")]
	var actions: Array = []
	for candidate in context["candidates"]: actions.append(candidate["id"])
	var pressure := int(float(context.get("battlefield", {}).get("enemy_to_friendly_ratio", 0)) * 4)
	return JSON.stringify([location.get("node", ""), location.get("edge", ""), context["returning"], context["target_known"], int(float(own["grain_days"]) / 4), int(float(own["morale"]) / 15), int(float(own["organization"]) / 15), enemies, allies, pressure, task, own.get("contact", {}).get("adjacent_enemies", 0), int(own.get("blocked_days", 0)) >= 2, actions])
