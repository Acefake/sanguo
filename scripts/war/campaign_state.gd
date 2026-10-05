extends RefCounted

const Graph = preload("res://scripts/war/map_graph.gd")
const Roster = preload("res://scripts/agents/officer_context.gd")
const Battle = preload("res://scripts/war/officer_battle.gd")
const Combat = preload("res://scripts/war/combat_system.gd")
const Policy = preload("res://scripts/agents/baseline_policy.gd")
const Corps = preload("res://scripts/war/army_corps.gd")
const Tactical = preload("res://scripts/war/tactical_battlefield.gd")
const Formation = preload("res://scripts/war/battle_formation.gd")
const Terrain = preload("res://scripts/war/battle_terrain.gd")
const Duel = preload("res://scripts/war/duel_system.gd")
const Feedback = preload("res://scripts/war/battle_feedback.gd")
const Siege = preload("res://scripts/war/siege_system.gd")
var store: Node
var graph = Graph.new()
var roster = Roster.new()
var rules: Dictionary = {}
var state: Dictionary = {}
var urgent_event := false
var generation := 0
var planner = preload("res://scripts/agents/decision_scheduler.gd").new()
var rng := RandomNumberGenerator.new()


func setup(owner: Node, saved: Dictionary = {}) -> void:
	generation += 1
	planner.clear()
	store = owner
	rules = _json("res://data/war/campaign_rules.json")
	graph.setup(_json("res://data/world_map.json"))
	roster.setup(_json("res://data/officers.json"), rules.get("faction_mapping", {}))
	state = {"version": 2, "tick": 0, "next_id": 1, "player_faction": "liu_bei", "armies": {}, "corps": {}, "sieges": {}, "missions": {}, "reports": [], "decisions": [], "officer_states": {}, "battle_victories": {}, "defense_cooldowns": {}, "rng_state": "0", "duels": {"pairs": {}, "counts": {}, "records": []}, "battle_feedback": {}}
	if not saved.is_empty():
		for key in state:
			if saved.has(key) and typeof(state[key]) == TYPE_INT and typeof(saved[key]) in [TYPE_INT, TYPE_FLOAT]:
				state[key] = int(saved[key])
			elif saved.has(key) and typeof(saved[key]) == typeof(state[key]):
				state[key] = saved[key]
	state["version"] = 2
	if saved.get("battlefield") is Dictionary:
		state["battlefield"] = saved["battlefield"].duplicate(true)
		if not state["battlefield"].has("battle_id"): state["battlefield"]["battle_id"] = "field:" + str(state["battlefield"].get("anchor",0))
	rng.seed = 1910901
	if int(state.get("rng_state", 0)) != 0:
		rng.state = int(state["rng_state"])
	for army in state["armies"].values():
		if not roster.officers.has(str(army.get("officer_id", ""))):
			roster.militia(str(army.get("faction", "")), str(army.get("home", "")))
		var officer: Dictionary = roster.officers.get(str(army.get("officer_id", "")), {})
		army["battle_traits"] = officer.get("battle_traits", []).duplicate()
		if army.has("tactical") and state.has("battlefield") and not army.has("battlefield_id"): army["battlefield_id"] = state["battlefield"]["battle_id"]
	for corps in state["corps"].values():
		corps["formation"] = corps.get("formation", "none")
		corps["formation_changed_at"] = int(corps.get("formation_changed_at", -10))
		corps.erase("last_requested")
		corps.erase("request_signature")
	Formation.sync(self)
	Tactical.migrate_positions(self)
	for city in store.scenario.get("places", {}).values():
		if city.has("garrison"):
			_sync_inventory(city)


func _json(path: String) -> Variant:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return [] if path.ends_with("officers.json") else {}
	var data: Variant = JSON.parse_string(file.get_as_text())
	return data


func export_state() -> Dictionary:
	state["rng_state"] = str(rng.state)
	return state.duplicate(true)


func active_armies(faction: String = "") -> Array:
	var result: Array = []
	for army in state["armies"].values():
		if str(army.get("status", "")) != "ended" and (faction == "" or str(army["faction"]) == faction):
			result.append(army)
	result.sort_custom(func(a, b): return str(a["id"]) < str(b["id"]))
	return result


func orders_for(army: Dictionary) -> Dictionary:
	var orders: Dictionary = {"engage": true, "retreat": true, "pursue": true, "after_battle": "withdraw"}
	orders.merge(army.get("orders", {}), true)
	return orders


func command_army(id: String, changes: Dictionary = {}, withdraw: bool = false) -> Dictionary:
	if store.busy:
		return {"ok": false, "message": "日期正在推进，请稍候。"}
	var army: Dictionary = state["armies"].get(id, {})
	if army.is_empty() or army.get("faction", "") != state["player_faction"]:
		return {"ok": false, "message": "只能向本方军队下令。"}
	if army.get("status", "") == "ended":
		return {"ok": false, "message": "这支军队已结束任务。"}
	if withdraw and bool(army["returning"]):
		return {"ok": false, "message": "军队正在撤退。"}
	var orders: Dictionary = orders_for(army)
	for key in changes:
		if key in ["engage", "retreat", "pursue"] and typeof(changes[key]) == TYPE_BOOL:
			orders[key] = changes[key]
		elif key == "after_battle" and changes[key] in ["withdraw", "hold"]:
			orders[key] = changes[key]
		else:
			return {"ok": false, "message": "未知军令。"}
	var corps: Dictionary = state["corps"].get(army.get("corps_id", ""), {})
	if not corps.is_empty() and corps["root_id"] == id:
		for unit_id in corps["units"].duplicate():
			var unit: Dictionary = state["armies"][unit_id]
			if unit["status"] == "ended": continue
			unit["orders"] = orders.duplicate(true)
			unit["decision_key"] = ""
			if withdraw: _execute(unit, {"type": "withdraw"})
	army["orders"] = orders
	army["decision_key"] = ""
	if withdraw:
		army["last_reason"] = "奉主公命令撤回友城。"
		_execute(army, {"type": "withdraw"})
		_report(army, "撤退军令", army["name"] + "已收到撤退命令，正在撤往可达的友城。", true)
	store._save()
	store.campaign_changed.emit()
	return {"ok": true, "message": "撤退命令已执行。" if withdraw else "军令已更新。"}


func command_formation(id: String, formation: String) -> Dictionary:
	if store.busy: return {"ok":false,"message":"日期正在推进，不能变阵"}
	var army: Dictionary = state["armies"].get(id,{})
	if army.is_empty() or army["faction"] != state["player_faction"] or army["status"] == "ended" or army["returning"]: return {"ok":false,"message":"只能向本方在役军团下令"}
	var corps: Dictionary = state["corps"].get(army.get("corps_id",""),{})
	if corps.is_empty(): return {"ok":false,"message":"该部队没有军团主阵"}
	var result := Corps.issue(self,corps,{"type":"set_formation","formation":formation},"奉主公军令变阵")
	if result.get("ok",false):
		# The current day has already resolved; reserve the NEXT execution day.
		corps["formation_changed_at"] = int(state["tick"]) + 1
		corps["orders"].append({"tick":state["tick"],"commander":corps["commander_id"],"action":{"type":"set_formation","formation":formation},"reason":"奉主公军令，下一个执行日整阵","source":"player","applied":result})
		while corps["orders"].size() > 40: corps["orders"].pop_front()
		Formation.sync(self)
		store._save()
		store.campaign_changed.emit()
	return result

func available_officers(faction: String) -> Array:
	var result: Array = []
	for officer in roster.officers.values():
		if str(officer["faction"]) == faction and not str(officer["id"]).begins_with("militia:") and str(state["officer_states"].get(officer["id"], {}).get("status", "available")) == "available":
			result.append(officer)
	result.sort_custom(func(a, b): return str(a["name"]) < str(b["name"]))
	return result


func set_player_faction(faction: String) -> bool:
	if not active_armies(str(state["player_faction"])).is_empty() or not rules["faction_mapping"].values().has(faction):
		return false
	state["player_faction"] = faction
	return true


func _sync_inventory(city: Dictionary) -> void:
	var total: int = int(city.get("garrison", 0))
	if not city.get("units", null) is Dictionary:
		city["units"] = {"infantry": total, "archers": 0, "cavalry": 0}
	var counted: int = 0
	for type in Combat.TYPES:
		city["units"][type] = maxi(0, int(city["units"].get(type, 0)))
		counted += int(city["units"][type])
	if counted < total:
		city["units"]["infantry"] += total - counted
	elif counted > total:
		var excess: int = counted - total
		for type in Combat.TYPES:
			var loss: int = mini(excess, int(city["units"][type]))
			city["units"][type] -= loss
			excess -= loss


func recruit_units(city: Dictionary, count: int) -> void:
	_sync_inventory(city)
	# The city's garrison has already increased; replace part of the new infantry.
	var archers: int = int(count * 0.2) if int(city.get("training", 0)) >= 50 else 0
	var cavalry: int = int(count * 0.1) if int(city.get("equipment", 0)) >= 70 else 0
	city["units"]["infantry"] -= archers + cavalry
	city["units"]["archers"] += archers
	city["units"]["cavalry"] += cavalry


func preview_dispatch(home: String, target: String, officer_id: String, defending: bool = false, troop_count: int = 0) -> Dictionary:
	var city: Dictionary = store.city_state(home)
	var officer: Dictionary = roster.officers.get(officer_id, {})
	var failure: Dictionary = {"ok": false, "message": "请选择可用的主将与本方出发城。"}
	if city.is_empty() or officer.is_empty() or not city.has("population") or not graph.places.has(target):
		return failure
	if str(city.get("faction", "")) != str(officer.get("faction", "")):
		return failure
	if str(state["officer_states"].get(officer_id, {}).get("status", "available")) != "available":
		return {"ok": false, "message": "这位将领已经在执行任务。"}
	var path: Dictionary = graph.path(home, target)
	if not bool(path["found"]):
		return {"ok": false, "message": "目标没有可用通路。"}
	var garrison: int = int(city.get("garrison", 0))
	var reserve: int = maxi(int(rules["minimum_reserve"]), int(ceil(garrison * float(rules["reserve_ratio"]))))
	var capacity: int = int(Battle.skill(officer, "带兵") * 120.0)
	var count: int = mini(mini(garrison - reserve, int(garrison * float(rules["mobilization_ratio"]))), capacity)
	var food_per_day: float = float(rules["grain_per_soldier_day"])
	var reserve_food: int = int(ceil(reserve * food_per_day * 10))
	var food_available: int = maxi(0, int(city.get("grain", 0)) - reserve_food)
	count = mini(count, int(food_available / (food_per_day * 12.0)))
	if count < int(rules["minimum_army"]):
		return {"ok": false, "message": "兵力或粮草不足，需保留至少 %d 名守军。" % reserve}
	var maximum: int = count
	if troop_count > 0:
		if troop_count < int(rules["minimum_army"]) or troop_count > maximum: return {"ok": false, "message": "所选兵力超出可动员范围。"}
		count = troop_count
	var food: int = mini(food_available, int(ceil(count * food_per_day * float(rules["carry_days"])) ))
	return {"ok": true, "message": "", "home": home, "target": target, "officer_id": officer_id, "strength": count, "maximum": maximum, "grain": food, "grain_days": int(food / maxf(count * food_per_day, 1)), "reserve": garrison - count, "travel_days": int(ceil(float(path["cost"]) * float(rules["route_days_per_cost"]))), "mission_type": "defend" if defending or str(store.city_state(target).get("faction", "")) == str(city["faction"]) else "capture"}


func dispatch(home: String, target: String, officer_id: String, companions: Array = [], as_corps: bool = false, troop_count: int = 0) -> Dictionary:
	if store.busy:
		return {"ok": false, "message": "日期正在推进，请稍候。"}
	if str(store.city_state(home).get("faction", "")) != str(state["player_faction"]):
		return {"ok": false, "message": "只能派遣本方城池的军队。"}
	var preview: Dictionary = preview_dispatch(home, target, officer_id, false, troop_count)
	if not bool(preview["ok"]):
		return preview
	var army: Dictionary = _mobilize(preview)
	if as_corps or not companions.is_empty():
		Corps.form(self, army, companions)
		if store.persist_enabled and store.agent.enabled and store.agent.has_method("supports_background_decisions"): Corps.plan_background(self, store.agent)
	_report(army, "出征", "%s奉命从%s出发，带兵%d，携粮%d，目标%s。" % [army["name"], graph.name_of(home), int(preview["strength"]), int(preview["grain"]), graph.name_of(target)], false)
	store._save()
	store.city_changed.emit(home)
	return {"ok": true, "army_id": army["id"], "message": "军队已出发，行军与作战由主将自主决定。"}


func _mobilize(preview: Dictionary) -> Dictionary:
	var city: Dictionary = store.city_state(str(preview["home"]))
	_sync_inventory(city)
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
	city["grain"] -= int(preview["grain"])
	var id: String = "army-%04d" % int(state["next_id"])
	state["next_id"] += 1
	var officer: Dictionary = roster.officers[str(preview["officer_id"])]
	var army: Dictionary = {"id": id, "officer_id": officer["id"], "name": officer["name"], "faction": city["faction"], "home": preview["home"], "target": preview["target"], "mission_type": preview["mission_type"], "status": "active", "location": {"node": preview["home"], "edge": "", "progress": 0.0}, "units": units, "initial_strength": count, "dead": 0, "wounded": 0, "captured": 0, "deposited": 0, "training": int(city.get("training", 50)), "equipment": int(city.get("equipment", 50)), "skills": officer["skills"].duplicate(true), "battle_traits": officer.get("battle_traits", []).duplicate(), "grain": float(preview["grain"]), "morale": 100.0, "organization": 100.0, "fatigue": 0.0, "started": int(state["tick"]), "deadline": int(state["tick"]) + int(rules["mission_days"]), "intel": {"cities": {}, "enemies": {}}, "action": {"type": "hold"}, "last_decision": -10, "last_report": {}, "last_reason": "正在准备出征。", "returning": false, "scouted_at": -10, "siege_progress": 0.0, "outcome": "", "last_support": -10, "memory": []}
	var last_victory := int(state["battle_victories"].get(str(officer["id"]), -100000))
	army["victory_chain"] = Battle.has_trait(army, "小霸王") and preview["mission_type"] == "capture" and int(state["tick"]) - last_victory <= int(rules.get("victory_chain_days", 30))
	state["armies"][id] = army
	state["missions"][id] = {"army_id": id, "home": preview["home"], "target": preview["target"], "status": "active", "type": preview["mission_type"], "result": ""}
	state["officer_states"][officer["id"]] = {"status": "commanding", "army_id": id}
	return army


func step(adapter: Node = null) -> void:
	var feedback_before := Feedback.snapshot(self)
	urgent_event = false
	state["tick"] += 1
	Formation.sync(self)
	var epoch: int = generation
	_deliver_reports()
	if not state.has("battlefield"): _spawn_defenders()
	_observe_all()
	if not state["corps"].is_empty():
		await Corps.plan(self, adapter)
		if generation != epoch: return
	Formation.sync(self)
	_update_operations()
	var contexts: Array = []
	for army in active_armies():
		if army.has("corps_id"): continue
		if bool(army["returning"]):
			# A retreat route is authoritative; the agent must not turn back or stop it.
			army["action"] = {"type": "continue"}
			if str(army["location"].get("edge", "")) == "":
				_start_return(army)
			continue
		if bool(army.get("objective_complete", false)) and orders_for(army)["after_battle"] == "hold":
			army["action"] = {"type": "hold"}
			continue
		if Combat.strength(army) > 0:
			var context: Dictionary = context_for(army)
			var key: String = _decision_key(context)
			if _should_reconsider(army, context, adapter, key):
				army["decision_key"] = key
				contexts.append(context)
	var outputs: Dictionary = {}
	if adapter != null and adapter.has_method("supports_background_decisions"):
		var requests: Array = []
		var signatures := {}
		for context in contexts:
			var key: String = "army:" + str(context["army_id"])
			var signature: String = _decision_key(context) + str(adapter.model) + str(adapter.endpoint)
			var proposal: Dictionary = planner.take(key, signature, int(state["tick"]))
			outputs[str(context["request_id"])] = proposal["result"] if not proposal.is_empty() else Policy.choose(context)
			if str(context["officer"]["id"]).begins_with("militia:") or planner.has_pending(key): continue
			requests.append(context)
			signatures[key] = signature
		planner.submit(requests, adapter, signatures)
	elif adapter != null and not contexts.is_empty():
		outputs = await adapter.choose_batch(contexts)
	elif adapter == null:
		for context in contexts:
			outputs[str(context["request_id"])] = Policy.choose(context)
	if generation != epoch:
		return
	# Every decision observes the same day-start state; only now commit actions.
	for context in contexts:
		var army: Dictionary = state["armies"].get(context["army_id"], {})
		var result: Dictionary = outputs.get(str(context["request_id"]), {})
		var validated: Dictionary = validate_decision(context, result)
		if not bool(validated.get("ok", false)):
			result = Policy.choose(context)
			result["fallback_reason"] = str(validated.get("message", "模型未返回结果"))
			validated = validate_decision(context, result)
			if adapter != null:
				adapter.metrics["fallbacks"] += 1
				adapter.last_status = "模型行动未通过校验 · 本地策略接管"
		if bool(validated.get("ok", false)):
			var previous_action: Dictionary = army["action"].duplicate(true)
			_execute(army, validated["action"])
			army["last_reason"] = str(result.get("reason_summary", "")).left(160)
			if previous_action != army["action"]: army["operation"]["change_reason"] = army["last_reason"]
			army["operation"]["plan_until"] = int(state["tick"]) + 3
			army["last_decision"] = int(state["tick"])
			army["decision_role"] = str(army["operation"].get("role", ""))
			army["decision_flanked"] = bool(context["army"].get("contact", {}).get("flanked", false))
			var record: Dictionary = {"request_id": context["request_id"], "tick": state["tick"], "army_id": army["id"], "candidate_id": result.get("candidate_id", ""), "action": validated["action"].duplicate(true), "reason_summary": army["last_reason"], "source": result.get("source", "baseline"), "model": str(adapter.model) if adapter != null else "", "rules_version": rules["version"], "prompt_version": 4, "fallback_reason": result.get("fallback_reason", ""), "observation": context.duplicate(true)}
			state["decisions"].append(record)
			if not army.has("decision_history"): army["decision_history"] = []
			army["decision_history"].append(record)
	while state["decisions"].size() > 160:
		state["decisions"].pop_front()
	var motions: Dictionary = _move_all()
	_resolve_contacts(motions)
	if not state["corps"].is_empty(): Corps.logistics(self)
	_resolve_sieges()
	_upkeep()
	_observe_all()
	_deliver_reports()
	Feedback.record_day(self, feedback_before)
	state["rng_state"] = str(rng.state)


func _should_reconsider(army: Dictionary, context: Dictionary, adapter, key: String) -> bool:
	var age := int(state["tick"]) - int(army["last_decision"])
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

func _decision_key(context: Dictionary) -> String:
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


func _spawn_defenders() -> void:
	var approaching: Array = active_armies()
	for attacker in approaching:
		if bool(attacker.get("returning", false)) or str(attacker["mission_type"]) != "capture":
			continue
		var target: String = str(attacker["target"])
		var city: Dictionary = store.city_state(target)
		var faction: String = str(city.get("faction", ""))
		if faction == "" or faction == str(attacker["faction"]) or not city.has("population"):
			continue
		var visible: Array = graph.visible_nodes(target)
		var location: Dictionary = attacker["location"]
		if not visible.has(location["node"]) and not visible.has(location.get("to", "")):
			continue
		var exists: bool = false
		for defender in active_armies(faction):
			if str(defender["home"]) == target:
				exists = true
		if exists or int(state["defense_cooldowns"].get(target, -100)) + 20 > int(state["tick"]):
			continue
		var officers: Array = available_officers(faction)
		var officer_id: String = str(officers[0]["id"]) if not officers.is_empty() else roster.militia(faction, target)
		var preview: Dictionary = preview_dispatch(target, target, officer_id, true)
		if bool(preview["ok"]):
			_mobilize(preview)
			state["defense_cooldowns"][target] = int(state["tick"])
			store.city_changed.emit(target)


func _observe_all() -> void:
	for army in active_armies():
		var location: Dictionary = army["location"]
		var radius: int = 2 if int(army["scouted_at"]) >= int(state["tick"]) - 1 else 1
		var visible: Array = graph.visible_nodes(str(location["node"]), radius)
		if str(location.get("edge", "")) != "":
			for node in graph.visible_nodes(str(location["to"]), radius):
				if not visible.has(node):
					visible.append(node)
		var accuracy: int = maxi(50, 1000 - int(Battle.skill(army, "料敌")) * 8)
		for node in visible:
			var city: Dictionary = store.city_state(str(node))
			var count: int = int(city.get("garrison", 0))
			army["intel"]["cities"][node] = {"node": node, "strength_estimate": int(round(float(count) / accuracy)) * accuracy, "defense": int(city.get("defense", 0)), "observed_at": state["tick"], "source": "scout" if radius == 2 else "local_observation", "uncertainty": accuracy}
		for enemy in active_armies():
			if str(enemy["faction"]) == str(army["faction"]):
				continue
			if army.has("tactical") and enemy.has("tactical") and Tactical.distance(army, enemy) > 7: continue
			var enemy_location: Dictionary = enemy["location"]
			if visible.has(enemy_location["node"]) or visible.has(enemy_location.get("to", "")):
				var observed_location: Dictionary = enemy_location.duplicate(true)
				observed_location["progress"] = snappedf(float(enemy_location.get("progress", 0)), 0.25)
				army["intel"]["enemies"][enemy["id"]] = {"id": enemy["id"], "location": observed_location, "strength_estimate": int(round(float(Combat.strength(enemy)) / accuracy)) * accuracy, "observed_at": state["tick"], "uncertainty": accuracy, "routing": bool(enemy.get("returning", false)), "fighting": int(enemy.get("combat_tick", -1)) == int(state["tick"])}
				var mix := {}
				for type in Combat.TYPES: mix[type] = int(round(float(enemy["units"][type]) / accuracy)) * accuracy
				army["intel"]["enemies"][enemy["id"]]["unit_mix_estimate"] = mix
				if enemy.has("tactical"):
					army["intel"]["enemies"][enemy["id"]]["tactical_cell"] = int(enemy["tactical"]["cell"])
		for key in ["cities", "enemies"]:
			for id in army["intel"][key].keys():
				if int(army["intel"][key][id]["observed_at"]) < int(state["tick"]) - int(rules["intel_expiry_days"]):
					army["intel"][key].erase(id)


func _update_operations() -> void:
	if not state["corps"].is_empty(): Corps.update(self)
	var assigned := {}
	for anchor in active_armies():
		if anchor.has("corps_id"): continue
		if assigned.has(anchor["id"]): continue
		var group: Array = []
		for friend in active_armies(str(anchor["faction"])):
			if not friend.has("corps_id") and not assigned.has(friend["id"]) and _near_battle(anchor["location"], friend["location"]): group.append(friend)
		group.sort_custom(func(a, b): return int(a["skills"].get("带兵", 50)) + int(a["skills"].get("治军", 50)) - (10000 if a["returning"] else 0) > int(b["skills"].get("带兵", 50)) + int(b["skills"].get("治军", 50)) - (10000 if b["returning"] else 0))
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
			operation["objective"] = graph.name_of(str(army["target"]))
			var enemies: Array = army["intel"]["enemies"].values()
			if army.has("tactical"):
				enemies.sort_custom(func(a, b): return Tactical.cell_distance(int(army["tactical"]["cell"]), int(a.get("tactical_cell", army["tactical"]["cell"]))) < Tactical.cell_distance(int(army["tactical"]["cell"]), int(b.get("tactical_cell", army["tactical"]["cell"]))))
				var previous_target: String = str(operation.get("suggested_target", ""))
				if not army["intel"]["enemies"].has(previous_target): operation["suggested_target"] = enemies[0]["id"] if not enemies.is_empty() else ""
			else: operation["suggested_target"] = enemies[index % enemies.size()]["id"] if not enemies.is_empty() else ""
			operation["plan_until"] = operation.get("plan_until", 0)
			operation["change_reason"] = operation.get("change_reason", "主帅按部队能力安排作战职责")
			if previous_role != "" and previous_role != operation["role"]:
				operation["change_reason"] = "战线发生变化，职责调整为" + operation["role_label"]
				operation["plan_until"] = 0
			army["operation"] = operation

func _near_battle(a: Dictionary, b: Dictionary) -> bool:
	var edge_a := str(a.get("edge", ""))
	var edge_b := str(b.get("edge", ""))
	if edge_a != "" and edge_a == edge_b:
		return absf(_edge_coordinate(a) - _edge_coordinate(b)) <= 0.3
	if edge_a == "" and edge_b == "": return a["node"] == b["node"]
	if edge_a == "": return _near_battle(b, a)
	if edge_b != "": return false
	return (b["node"] == a.get("from", "") and float(a.get("progress", 0)) <= 0.3) or (b["node"] == a.get("to", "") and float(a.get("progress", 0)) >= 0.7)

func _support_context(army: Dictionary) -> Dictionary:
	var allies: Array = []
	var ready := Combat.strength(army)
	var nearby: Array = graph.visible_nodes(str(army["location"]["node"]), 1)
	for friend in active_armies(str(army["faction"])):
		if friend["id"] == army["id"]: continue
		var local := _near_battle(army["location"], friend["location"])
		if army.has("tactical") and friend.has("tactical"): local = Tactical.distance(army, friend) <= 5
		if not local and not nearby.has(friend["location"]["node"]): continue
		var available := not bool(friend["returning"]) and float(friend["morale"]) >= 30 and float(friend["organization"]) >= 25 and float(friend["grain"]) > 0 and bool(orders_for(friend)["engage"])
		if friend.get("operation", {}).get("role", "") == "reserve" and friend["action"]["type"] == "hold": available = false
		var strength := Combat.strength(friend)
		if local and available: ready += strength
		allies.append({"id": friend["id"], "name": friend["name"], "strength": strength, "location": friend["location"].duplicate(true), "morale": friend["morale"], "organization": friend["organization"], "returning": friend["returning"], "last_action": friend["action"].duplicate(true), "target": graph.name_of(str(friend["target"])), "near_battle": local, "can_support": local and available, "reinforcement_possible": not local and available, "role": friend.get("operation", {}).get("role", ""), "tactical_cell": int(friend.get("tactical", {}).get("cell", -1))})
	var enemy_total := 0
	var uncertainty := 0
	for enemy in army["intel"]["enemies"].values():
		if army.has("tactical") and int(enemy.get("tactical_cell", -1)) >= 0:
			var cell: int = int(army["tactical"]["cell"])
			var enemy_cell: int = int(enemy["tactical_cell"])
			if Tactical.cell_distance(cell, enemy_cell) > 5: continue
		if not bool(enemy.get("routing", false)) and _near_battle(army["location"], enemy["location"]):
			enemy_total += int(enemy["strength_estimate"])
			uncertainty += int(enemy.get("uncertainty", 0))
	return {"allies": allies, "battlefield": {"friendly_ready_strength": ready, "enemy_estimated_strength": enemy_total, "enemy_strength_min": maxi(0, enemy_total - uncertainty), "enemy_strength_max": enemy_total + uncertainty, "enemy_to_friendly_ratio": float(enemy_total) / maxf(ready, 1), "note": "友军计划为上一轮行动；可支援表示邻近且状态允许，不保证本轮行动。远处援军与撤退、低士气、低组织、断粮友军不计入可用兵力。敌军仅使用已有侦察估计。"}}

func context_for(army: Dictionary) -> Dictionary:
	var target: String = str(army["home"] if bool(army["returning"]) else army["target"])
	var location: Dictionary = army["location"]
	var own: Dictionary = {"strength": Combat.strength(army), "units": army["units"].duplicate(true), "morale": army["morale"], "organization": army["organization"], "fatigue": army["fatigue"], "grain_days": float(army["grain"]) / maxf(daily_food(army), 0.001), "location": location.duplicate(true), "training": army["training"], "equipment": army["equipment"]}
	if army.has("tactical"):
		own["cell"] = int(army["tactical"]["cell"])
		own["blocked"] = army["tactical"]["blocked"]
		own["blocked_days"] = int(army["tactical"].get("blocked_days", 0))
		own["phase"] = army["tactical"]["phase"]
		own["contact"] = Tactical.contact_state(self, army)
		own["withdraw_preparation"] = army["tactical"].get("withdraw_preparation", 0)
	var candidates: Array = []
	var support := _support_context(army)
	var operation: Dictionary = army.get("operation", {})
	if army.has("tactical"):
		_add_candidate(candidates, "hold", {"type": "hold"}, "保持战线或预备位置，等待战局变化。")
		var partner: String = str(operation.get("support_id", ""))
		if partner != "" and operation.get("role", "") in ["support", "rear_guard"]: _add_candidate(candidates, "support:" + partner, {"type": "support", "ally": partner}, "跟随指定友军提供远程支援。")
	if str(location.get("edge", "")) != "":
		_add_candidate(candidates, "continue", {"type": "continue"}, "按既定计划继续行军。")
	else:
		_add_candidate(candidates, "hold", {"type": "hold"}, "驻守当前位置，整顿组织并恢复疲劳。")
		_add_candidate(candidates, "scout", {"type": "scout"}, "先行侦察周边，核实敌情后再行动。")
		var current: String = str(location["node"])
		var current_path: Dictionary = graph.path(current, target)
		for link in graph.neighbors(current):
			var node: String = str(link["node"])
			var alternative: Dictionary = graph.path(node, target)
			_add_candidate(candidates, "march:" + node, {"type": "march", "target": node, "edge": link["edge"]}, "向%s行军，按局势选择通路。" % graph.name_of(node), {"progress_gain": float(current_path.get("cost", 0)) - float(alternative.get("cost", 999))})
		var city: Dictionary = store.city_state(current)
		if str(city.get("faction", "")) == str(army["faction"]) and int(city.get("grain", 0)) > 0:
			_add_candidate(candidates, "resupply", {"type": "resupply"}, "在友城补充携粮。")
		if current == str(army["target"]) and str(army["mission_type"]) == "capture" and str(city.get("faction", "")) != str(army["faction"]):
			var intel: Dictionary = army["intel"]["cities"].get(current, {})
			_add_candidate(candidates, "besiege", {"type": "besiege"}, "继续围城，寻找攻城机会。", {"defender_ratio": float(intel.get("strength_estimate", 0)) / maxf(Combat.strength(army), 1)})
	for enemy in army["intel"]["enemies"].values():
		var observed: Dictionary = enemy["location"]
		if str(observed.get("node", "")) == str(location["node"]) or str(location.get("edge", "")) != "" and str(observed.get("edge", "")) == str(location["edge"]):
			_add_candidate(candidates, "engage:" + str(enemy["id"]), {"type": "engage", "enemy": enemy["id"]}, "与已发现的敌军交战。")
			if army.has("tactical") and operation.get("role", "") == "flank":
				_add_candidate(candidates, "flank:" + str(enemy["id"]), {"type": "flank", "enemy": enemy["id"]}, "绕向敌军侧翼，通路被阻挡时重新判断。")
			if bool(enemy.get("routing", false)):
				_add_candidate(candidates, "pursue:" + str(enemy["id"]), {"type": "pursue", "enemy": enemy["id"]}, "追击已发现的败退敌军。")
	var orders: Dictionary = orders_for(army)
	candidates = candidates.filter(func(candidate):
		var type: String = candidate["action"]["type"]
		if type in ["engage", "flank", "support"] and not bool(orders["engage"]): return false
		if army.has("tactical") and operation.get("role", "") == "flank" and type == "engage":
			var enemy: Dictionary = state["armies"].get(candidate["action"].get("enemy", ""), {})
			if not enemy.is_empty() and Tactical.distance(army, enemy) > 1: return false
		if army.has("tactical") and operation.get("role", "") == "reserve" and type not in ["hold", "scout", "resupply", "request_support"]: return false
		if army.has("tactical") and operation.get("role", "") == "rear_guard" and type not in ["hold", "support", "resupply", "request_support"]: return false
		return type != "pursue" or bool(orders["pursue"])
	)
	if bool(orders["retreat"]):
		_add_candidate(candidates, "withdraw", {"type": "withdraw"}, "保存兵力，撤往安全的本方城池。")
	if int(army["last_support"]) < int(state["tick"]) - 7:
		_add_candidate(candidates, "request_support", {"type": "request_support"}, "等待支援并向后方报告军情。")
	var local_map: Dictionary = state.get("battlefield", {}).duplicate()
	# Decision snapshots need geometry, not the growing authoritative battle ledger.
	local_map.erase("log")
	local_map.erase("pending_events")
	return {"request_id": "%s:%d" % [army["id"], int(state["tick"])], "army_id": army["id"], "observation_revision": state["tick"], "date": store.date_text(), "officer": roster.officers[army["officer_id"]].duplicate(true), "army": own, "mission_type": army["mission_type"], "objective": graph.name_of(target), "at_objective": str(location["node"]) == target and str(location.get("edge", "")) == "", "returning": army["returning"], "target_known": army["intel"]["cities"].has(target), "cities": army["intel"]["cities"].values().duplicate(true), "enemies": army["intel"]["enemies"].values().duplicate(true), "allies": support["allies"], "battlefield": support["battlefield"], "operation": operation.duplicate(true), "local_map": local_map.duplicate(true), "current_action": army["action"].duplicate(true), "memory": army["memory"].duplicate(true), "candidates": candidates}


func _add_candidate(list: Array, id: String, action: Dictionary, description: String, extra: Dictionary = {}) -> void:
	var candidate: Dictionary = {"id": id, "action": action, "description": description}
	candidate.merge(extra)
	list.append(candidate)


func validate_decision(context: Dictionary, result: Dictionary) -> Dictionary:
	var army: Dictionary = state["armies"].get(context.get("army_id", ""), {})
	if army.is_empty() or str(army["status"]) == "ended" or int(context.get("observation_revision", -1)) != int(state["tick"]) or int(army["last_decision"]) == int(state["tick"]):
		return {"ok": false, "message": "行动请求过期或已经执行。"}
	var choice: Variant = result.get("candidate_id", null)
	if not choice is String:
		return {"ok": false, "message": "未返回有效选择。"}
	for candidate in context.get("candidates", []):
		if str(candidate["id"]) == choice:
			return {"ok": true, "action": candidate["action"].duplicate(true)}
	return {"ok": false, "message": "选择了授权范围之外的行动。"}


func _execute(army: Dictionary, action: Dictionary) -> void:
	army["action"] = action.duplicate(true)
	var location: Dictionary = army["location"]
	match str(action["type"]):
		"march":
			location["from"] = location["node"]
			location["to"] = action["target"]
			location["edge"] = action["edge"]
			location["progress"] = 0.0
		"scout": army["scouted_at"] = int(state["tick"])
		"withdraw":
			army["returning"] = true
			if str(army["outcome"]) == "":
				army["outcome"] = "撤退"
			state["missions"][army["id"]]["status"] = "returning"
			_start_return(army)
		"resupply":
			var city: Dictionary = store.city_state(str(location["node"]))
			var need: int = maxi(0, int(ceil(daily_food(army) * float(rules["carry_days"]) - float(army["grain"]))))
			var take: int = mini(need, mini(int(city.get("grain", 0)), int(ceil(daily_food(army) * 10))))
			city["grain"] -= take
			army["grain"] += take
			store.city_changed.emit(str(location["node"]))
		"request_support":
			army["last_support"] = int(state["tick"])
			_report(army, "求援", "%s请求增援，目前兵力%d，余粮约%d日。" % [army["name"], Combat.strength(army), int(float(army["grain"]) / maxf(daily_food(army), 0.001))], true)


func _start_return(army: Dictionary) -> void:
	if army.has("tactical"): return
	var location: Dictionary = army["location"]
	if str(location.get("edge", "")) != "":
		if not bool(location.get("reversed", false)):
			var old_from: String = str(location["from"])
			location["from"] = location["to"]
			location["node"] = location["to"]
			location["to"] = old_from
			location["progress"] = 1.0 - float(location["progress"])
			location["reversed"] = true
		return
	var best: Dictionary = {}
	var best_cost: float = INF
	var destination: String = ""
	for id in store.scenario.get("places", {}):
		var city: Dictionary = store.city_state(str(id))
		if not city.has("population") or str(city.get("faction", "")) != str(army["faction"]):
			continue
		var path: Dictionary = graph.path(str(location["node"]), str(id))
		if bool(path["found"]) and float(path["cost"]) < best_cost:
			best = path
			best_cost = float(path["cost"])
			destination = str(id)
	if destination == "":
		_report(army, "退路受阻", "%s没有可达的友城，暂时驻守并请求支援。" % army["name"], true)
		return
	army["return_destination"] = destination
	if best["nodes"].size() == 1:
		_finish(army, str(army.get("outcome", "撤退")))
	else:
		location["from"] = location["node"]
		location["to"] = best["nodes"][1]
		location["edge"] = best["edges"][0]
		location["progress"] = 0.0
		location["reversed"] = false


func _move_all() -> Dictionary:
	if state.has("battlefield"): return Tactical.move(self)
	var motions: Dictionary = {}
	for army in active_armies():
		var location: Dictionary = army["location"]
		var before: Dictionary = location.duplicate(true)
		if army.get("formation_locked",false):
			motions[army["id"]] = {"before":before,"after":before.duplicate(true)}
			continue
		if str(location.get("edge", "")) != "" and str(army["action"]["type"]) in ["march", "continue", "withdraw"]:
			var edge: Dictionary = graph.edges.get(location["edge"], {})
			if graph.blocked.has(location["to"]) or graph.blocked.has(location["from"]):
				army["action"] = {"type": "hold"}
				_report(army, "通路受阻", "%s行军通路受阻，正在重新判断。" % army["name"], true)
			else:
				var leader: Dictionary = army
				if army.has("corps_id"): leader = state["armies"][state["corps"][army["corps_id"]]["root_id"]]
				var speed: float = Battle.march_speed(leader, _terrain(str(location["node"])))
				location["progress"] = minf(1.0, float(location["progress"]) + speed / maxf(float(edge.get("cost", 1)) * float(rules["route_days_per_cost"]), 1))
				army["fatigue"] = minf(100, float(army["fatigue"]) + Battle.fatigue_cost(army, 3.0))
				if float(location["progress"]) >= 1.0:
					location["node"] = location["to"]
					location["edge"] = ""
					location["progress"] = 0.0
		motions[army["id"]] = {"before": before, "after": location.duplicate(true)}
	return motions


func _edge_coordinate(location: Dictionary) -> float:
	var edge: Dictionary = graph.edges.get(location.get("edge", ""), {})
	return float(location.get("progress", 0)) if str(location.get("from", "")) == str(edge.get("from", "")) else 1.0 - float(location.get("progress", 0))


func _contact(a: Dictionary, b: Dictionary, motions: Dictionary) -> bool:
	var la: Dictionary = a["location"]
	var lb: Dictionary = b["location"]
	if str(la.get("edge", "")) == "" and str(lb.get("edge", "")) == "":
		return str(la["node"]) == str(lb["node"])
	var ma: Dictionary = motions.get(a["id"], {"before": la, "after": la})
	var mb: Dictionary = motions.get(b["id"], {"before": lb, "after": lb})
	var ea: String = str(ma["before"].get("edge", ""))
	var eb: String = str(mb["before"].get("edge", ""))
	if ea == "": ea = str(la.get("edge", ""))
	if eb == "": eb = str(lb.get("edge", ""))
	if ea == "" or ea != eb:
		return false
	var aa: Dictionary = ma["before"] if str(ma["before"].get("edge", "")) != "" else la
	var bb: Dictionary = mb["before"] if str(mb["before"].get("edge", "")) != "" else lb
	var old_delta: float = _edge_coordinate(aa) - _edge_coordinate(bb)
	var a_end: float = _edge_coordinate(la) if str(la.get("edge", "")) != "" else (1.0 if str(la["node"]) == str(graph.edges[ea]["to"]) else 0.0)
	var b_end: float = _edge_coordinate(lb) if str(lb.get("edge", "")) != "" else (1.0 if str(lb["node"]) == str(graph.edges[ea]["to"]) else 0.0)
	return absf(a_end - b_end) < 0.13 or old_delta * (a_end - b_end) <= 0


func _resolve_contacts(motions: Dictionary) -> void:
	if state.has("battlefield"):
		Tactical.resolve(self)
		return
	var armies: Array = active_armies()
	var engaged: Dictionary = {}
	for i in range(armies.size()):
		for j in range(i + 1, armies.size()):
			var a: Dictionary = armies[i]
			var b: Dictionary = armies[j]
			if str(a["faction"]) == str(b["faction"]) or engaged.has(a["id"]) or engaged.has(b["id"]) or not _contact(a, b, motions):
				continue
			if not bool(orders_for(a)["engage"]) or not bool(orders_for(b)["engage"]):
				var initiated := false
				for side in [a, b]:
					var type: String = side["action"]["type"]
					initiated = initiated or (type == "engage" and bool(orders_for(side)["engage"])) or (type == "pursue" and bool(orders_for(side)["pursue"]))
				if not initiated: continue
			engaged[a["id"]] = true
			engaged[b["id"]] = true
			if bool(a["returning"]) or bool(b["returning"]):
				var fleeing: Dictionary = a if bool(a["returning"]) else b
				var pursuer: Dictionary = b if bool(a["returning"]) else a
				if bool(orders_for(pursuer)["pursue"]) and str(pursuer["action"]["type"]) in ["pursue", "engage"]:
					pursuer["combat_tick"] = int(state["tick"])
					var chased: int = Combat.apply_loss(fleeing, mini(Combat.strength(fleeing), int(Combat.strength(pursuer) * 0.025 * Battle.factor(pursuer, ["骑术", "奇袭"], 0.004) / Battle.factor(fleeing, ["应变", "治军"], 0.004) * (1.03 if Battle.has_trait(pursuer, "乘隙追击") else 1.0))), true)
					_report(fleeing, "遭遇追击", "%s撤退途中被追击，%d人被俘。" % [fleeing["name"], chased], true)
					pursuer["fatigue"] = minf(100, float(pursuer["fatigue"]) + Battle.fatigue_cost(pursuer, 8, true))
				continue
			# Freeze road movement at the contact point for the next day's battle.
			var edge_id: String = str(a["location"].get("edge", ""))
			if edge_id != "" and str(b["location"].get("edge", "")) == edge_id:
				var coordinate: float = (_edge_coordinate(a["location"]) + _edge_coordinate(b["location"])) * 0.5
				for combatant in [a, b]:
					combatant["location"]["progress"] = coordinate if str(combatant["location"]["from"]) == str(graph.edges[edge_id]["from"]) else 1.0 - coordinate
			var side_a: Array = [a]
			var side_b: Array = [b]
			for support in armies:
				if engaged.has(support["id"]) or bool(support["returning"]): continue
				if str(support["faction"]) == str(a["faction"]) and _contact(support, b, motions):
					side_a.append(support)
					engaged[support["id"]] = true
				elif str(support["faction"]) == str(b["faction"]) and _contact(support, a, motions):
					side_b.append(support)
					engaged[support["id"]] = true
			var terrain: String = _terrain(str(a["location"]["node"]))
			for attacker in side_a:
				for defender in side_b: _battle_contact(attacker, defender)
			for attacker in side_b:
				for defender in side_a: _battle_contact(attacker, defender)
			if not side_a.is_empty() and not side_b.is_empty(): Duel.challenge(self, side_a[0], side_b[0])
			var combined_a: Dictionary = Combat.aggregate(side_a)
			var combined_b: Dictionary = Combat.aggregate(side_b)
			var loss_a: int = Combat.losses(combined_b, combined_a, rules, terrain, rng.randf_range(0.9, 1.1))
			var loss_b: int = Combat.losses(combined_a, combined_b, rules, terrain, rng.randf_range(0.9, 1.1))
			for side in [[side_a, loss_a, loss_b, Combat.strength(combined_b)], [side_b, loss_b, loss_a, Combat.strength(combined_a)]]:
				var members: Array = side[0]
				var total_strength: int = Combat.strength(Combat.aggregate(members))
				var remaining: int = int(side[1])
				for member in members:
					member["battle_factors"] = Feedback.factors((side_b if members == side_a else side_a)[0], member, rules, terrain)
					member["combat_tick"] = int(state["tick"])
					var loss: int = mini(remaining, int(ceil(float(side[1]) * Combat.strength(member) / maxf(total_strength, 1))))
					var before_strength := Combat.strength(member)
					loss = Combat.apply_loss(member, loss, false, 0.0)
					Feedback.loss(self, member, loss)
					Combat.battle_morale(member, loss, float(side[2]) * before_strength / maxf(total_strength, 1), before_strength, float(side[3]), total_strength, float(side[3]))
					remaining -= loss
					_report(member, "交战", "%s与敌军交战，本日损失%d人，士气%d。" % [member["name"], loss, int(member["morale"])], true)
					member["fatigue"] = minf(100, float(member["fatigue"]) + Battle.fatigue_cost(member, 5, true))
					_check_rout(member)
					if member["returning"] or member["status"] == "ended":
						for winner in (side_b if members == side_a else side_a): _battle_victory(winner)


func _terrain(node: String) -> String:
	var place: Dictionary = graph.places.get(node, {})
	if str(place.get("type", "")) == "pass":
		return "mountains"
	return str(rules["terrain_regions"].get(str(place.get("region_id", "")), "plains"))


func _resolve_sieges() -> void:
	Siege.resolve(self)


func _capture_city(army: Dictionary, besiegers: Array, node: String, city: Dictionary) -> void:
	city["prisoners"] = int(city.get("prisoners", 0)) + int(city["garrison"]) + int(city.get("wounded", 0))
	city["wounded"] = 0
	city["garrison"] = 0
	city["units"] = {"infantry": 0, "archers": 0, "cavalry": 0}
	city["faction"] = army["faction"]
	var left := 0
	for unit in besiegers:
		var remaining := mini(Combat.strength(unit), maxi(1, int(Combat.strength(unit) * 0.15)))
		var deposited := remaining
		for type in Combat.TYPES:
			var take := mini(remaining, int(unit["units"][type]))
			unit["units"][type] -= take
			city["units"][type] += take
			remaining -= take
		unit["deposited"] += deposited
		left += deposited
	city["garrison"] = left
	var winners := {}
	for victor in besiegers:
		_battle_victory(victor)
		winners[victor["id"]] = victor
		var corps: Dictionary = state["corps"].get(victor.get("corps_id", ""), {})
		for id in corps.get("units", []): winners[id] = state["armies"][id]
	for unit in winners.values():
		if unit["status"] == "ended": continue
		unit["objective_complete"] = true
		unit["outcome"] = "攻取成功"
		if orders_for(unit)["after_battle"] == "withdraw": _execute(unit, {"type": "withdraw"})
		else: unit["action"] = {"type": "hold"}
	_report(army, "占领", "%s攻取%s，留下%d人驻防。" % [army["name"], graph.name_of(node), left], true)
	if state.get("battlefield", {}).get("objectives", {}).has(node):
		state["battlefield"]["winner"] = army["faction"]
		state["battlefield"]["ended_at"] = state["tick"]


func _check_rout(army: Dictionary) -> void:
	if Combat.strength(army) <= 0:
		state["battle_victories"].erase(str(army["officer_id"]))
		army["victory_chain"] = false
		_finish(army, "军队覆没")
		return
	if army["returning"]: return
	var morale := float(army["morale"])
	var organization := float(army["organization"])
	if morale >= 25 and organization >= 20:
		army.erase("rout_crisis_since")
		return
	if not army.has("rout_crisis_since"): army["rout_crisis_since"] = int(state["tick"])
	# A disordered but supplied force can rally behind nearby healthy allies.
	# Hard panic still routs; manpower alone never makes a shattered army invincible.
	var supported := false
	if army.has("tactical"):
		for friend in active_armies(str(army["faction"])):
			if friend["id"] != army["id"] and not friend["returning"] and friend.has("tactical") and float(friend["morale"]) >= 35 and float(friend["organization"]) >= 30 and Tactical.distance(army, friend) <= 3:
				supported = true
				break
	var substantial := Combat.strength(army) >= maxf(500, float(army.get("initial_strength", 0)) * 0.4)
	if supported and substantial and morale > 10 and float(army.get("grain", 0)) >= daily_food(army):
		var corps: Dictionary = state["corps"].get(army.get("corps_id", ""), {})
		var reason := "友军掩护，主帅令本队归建整阵，仍留在战场"
		if not corps.is_empty() and army["id"] != corps["root_id"]:
			Corps.issue(self, corps, {"type": "assign_task", "unit": army["id"], "task": "regroup"}, reason)
		army["last_reason"] = reason
		army["rally_requested"] = int(state["tick"])
		return
	if supported and morale > 10 and organization > 8 and int(state["tick"]) == int(army["rout_crisis_since"]):
		army["last_reason"] = "友军接应稳住阵线，等待主帅接替"
		return
	army["returning"] = true
	army["outcome"] = "溃败撤退"
	army["retreat_reason"] = "军心崩溃（士气%d）" % int(morale) if morale < 25 else "阵形崩溃（组织%d）" % int(organization)
	army["last_reason"] = army["retreat_reason"]
	state["battle_victories"].erase(str(army["officer_id"]))
	army["victory_chain"] = false
	_report(army, "溃败", "%s所部%s，剩余%d人，正在有序脱离。" % [army["name"], army["retreat_reason"], Combat.strength(army)], true)
	_start_return(army)


func daily_food(army: Dictionary) -> float:
	return (Combat.strength(army) + int(army.get("wounded", 0))) * float(rules["grain_per_soldier_day"])


func _upkeep() -> void:
	for army in active_armies():
		if army.has("tactical"):
			var terrain := Tactical.terrain_class(army["tactical"]["cell"])
			army["fatigue"] = minf(100, float(army["fatigue"])+float(Terrain.settings(terrain,rules).get("daily_fatigue",0)))
		var needed: float = daily_food(army)
		var provided: float = minf(float(army["grain"]), needed)
		army["grain"] = maxf(0, float(army["grain"]) - provided)
		if provided + 0.001 < needed:
			army["morale"] = maxf(0, float(army["morale"]) - 8)
			army["organization"] = maxf(0, float(army["organization"]) - 5)
			Combat.apply_loss(army, int(ceil(Combat.strength(army) * 0.005)))
			_report(army, "缺粮", "%s所部携粮耗尽，士气与组织持续下降。" % army["name"], true)
		var resting: bool = int(army.get("combat_tick", -1)) != int(state["tick"]) and (str(army["action"]["type"]) in ["hold", "scout", "resupply", "request_support"] or (army.has("tactical") and int(army["tactical"].get("moved_tick", -1)) != int(state["tick"])))
		if resting:
			var recovery := Battle.recovery(army)
			army["fatigue"] = maxf(0, float(army["fatigue"]) - float(recovery["fatigue"]))
			if provided >= needed:
				army["organization"] = minf(100, float(army["organization"]) + float(recovery["organization"]))
				army["morale"] = minf(100, float(army["morale"]) + float(recovery["morale"]))
		if int(state["tick"]) >= int(army["deadline"]):
			army["returning"] = true
			if str(army["outcome"]) == "": army["outcome"] = "任务期限已到"
		if str(army["mission_type"]) == "capture" and str(store.city_state(str(army["target"])).get("faction", "")) == str(army["faction"]) and not bool(army["returning"]) and orders_for(army)["after_battle"] == "withdraw":
			army["returning"] = true
			army["outcome"] = "目标已由本方控制"
		if str(army["location"].get("edge", "")) == "" and str(army["location"]["node"]) == str(army["target"]) and not army.has("arrived_at"):
			army["arrived_at"] = int(state["tick"])
		if str(army["mission_type"]) == "defend" and army.has("arrived_at") and int(state["tick"]) >= int(army["arrived_at"]) + 15 and army["intel"]["enemies"].is_empty():
			army["returning"] = true
			army["outcome"] = "守援完成"
		if bool(army["returning"]) and str(army["location"].get("edge", "")) == "":
			_start_return(army)
		_check_rout(army)
		if str(army["status"]) != "ended" and int(state["tick"]) % 3 == 0:
			_report(army, "行军报告", "%s位于%s，兵力%d，士气%d，余粮约%d日。" % [army["name"], graph.name_of(str(army["location"]["node"])), Combat.strength(army), int(army["morale"]), int(float(army["grain"]) / maxf(daily_food(army), 0.001))], false)


func _finish(army: Dictionary, outcome: String) -> void:
	if str(army["status"]) == "ended":
		return
	var node: String = str(army["location"]["node"])
	var city: Dictionary = store.city_state(node)
	var strength: int = Combat.strength(army)
	if city.has("population") and str(city.get("faction", "")) == str(army["faction"]):
		_sync_inventory(city)
		for type in Combat.TYPES:
			city["units"][type] += int(army["units"][type])
		city["garrison"] += strength
		city["wounded"] = int(city.get("wounded", 0)) + int(army["wounded"])
		city["grain"] += int(floor(float(army["grain"])))
		army["returned_strength"] = strength
		army["returned_wounded"] = army["wounded"]
		army["returned_grain"] = int(floor(float(army["grain"])))
		army["deposited"] += strength
		army["units"] = {"infantry": 0, "archers": 0, "cavalry": 0}
		army["grain"] = 0.0
		store.city_changed.emit(node)
	elif outcome == "军队覆没" and int(army["wounded"]) > 0:
		army["captured"] += int(army["wounded"])
		army["wounded"] = 0
	army["status"] = "ended"
	army["outcome"] = outcome
	state["missions"][army["id"]]["status"] = "ended"
	state["missions"][army["id"]]["result"] = outcome
	state["officer_states"][army["officer_id"]] = {"status": "available" if outcome != "军队覆没" and not army.get("duel_wounded", false) else "recovering", "available_after": int(state["tick"]) + (int(rules["duel"]["recover_days"]) if army.get("duel_wounded", false) else 10)}
	if army.get("duel_wounded", false): state["officer_states"][army["officer_id"]]["duel_wounded"] = true
	Corps.on_finish(self, army)
	_report(army, "任务结束", "%s：%s。归队%d，伤兵%d，阵亡%d，被俘%d，留驻%d。" % [army["name"], outcome, int(army.get("returned_strength", 0)), int(army["wounded"]), int(army["dead"]), int(army["captured"]), int(army["deposited"]) - int(army.get("returned_strength", 0))], true)


func _report(army: Dictionary, kind: String, message: String, urgent: bool) -> void:
	if kind in ["单挑", "溃败", "变阵", "粮道截断", "占领", "主帅分兵"]: Feedback.event(self, kind, message, army["faction"])
	if kind in ["交战", "战线交战", "围城"]:
		var factors: Array = army.get("battle_factors", [])
		if not factors.is_empty(): message += " " + "；".join(factors)
	if str(army["faction"]) != str(state["player_faction"]):
		return
	var reports: Array = state["reports"]
	if not reports.is_empty():
		var last: Dictionary = reports[reports.size() - 1]
		if last.get("army_id", "") == army["id"] and last.get("kind", "") == kind and int(last.get("sent_tick", -1)) == int(state["tick"]):
			return
	var id: String = "report-%d-%d" % [int(state["tick"]), int(state["next_id"])]
	state["next_id"] += 1
	reports.append({"id": id, "army_id": army["id"], "kind": kind, "message": message, "sent_tick": int(state["tick"]), "sent_date": store.date_text(), "delivery_tick": int(state["tick"]) + int(rules["report_delay_days"]), "received": false, "urgent": urgent, "snapshot": {"location": army["location"].duplicate(true), "strength": Combat.strength(army), "morale": army["morale"], "grain_days": int(float(army["grain"]) / maxf(daily_food(army), 0.001)), "reason": str(army["last_reason"]), "ended": str(army["status"]) == "ended", "cities": army["intel"]["cities"].duplicate(true)}})
	while reports.size() > 200:
		reports.pop_front()
	army["memory"].append({"tick": state["tick"], "kind": kind, "event": message})
	while army["memory"].size() > 8:
		army["memory"].pop_front()


func _deliver_reports() -> void:
	for report in state["reports"]:
		if not bool(report["received"]) and int(report["delivery_tick"]) <= int(state["tick"]):
			report["received"] = true
			report["received_date"] = store.date_text()
			var army: Dictionary = state["armies"].get(report["army_id"], {})
			if not army.is_empty(): army["last_report"] = report.duplicate(true)
			if bool(report["urgent"]): urgent_event = true
	for id in state["officer_states"]:
		var officer: Dictionary = state["officer_states"][id]
		if str(officer.get("status", "")) == "recovering" and int(officer.get("available_after", 0)) <= int(state["tick"]):
			var corps: Dictionary = state["corps"].get(officer.get("corps_id", ""), {})
			officer["status"] = "deployed" if not corps.is_empty() and not corps.get("ended", false) else "available"
			officer.erase("duel_wounded")


func visible_reports() -> Array:
	var result: Array = []
	for report in state["reports"]:
		if bool(report["received"]): result.push_front(report)
	return result


func has_pending_urgent_report() -> bool:
	for report in state["reports"]:
		if not bool(report["received"]) and bool(report["urgent"]): return true
	return false


func player_markers() -> Array:
	var result: Array = []
	for army in state["armies"].values():
		if str(army["faction"]) != str(state["player_faction"]): continue
		var report: Dictionary = army.get("last_report", {})
		if not report.is_empty() and not bool(report["snapshot"].get("ended", false)):
			result.append({"id": army["id"], "name": army["name"], "location": report["snapshot"]["location"], "date": report["sent_date"], "strength": report["snapshot"]["strength"]})
	return result


func player_city_intel(node: String) -> Dictionary:
	var latest: Dictionary = {}
	for report in visible_reports():
		var observation: Dictionary = report.get("snapshot", {}).get("cities", {}).get(node, {})
		if not observation.is_empty() and (latest.is_empty() or int(observation["observed_at"]) > int(latest["observed_at"])):
			latest = observation
	return latest


func player_has_city_access(node: String) -> bool:
	return state["missions"].is_empty() or str(store.city_state(node).get("faction", "")) == str(state["player_faction"])


func _battle_contact(attacker: Dictionary, defender: Dictionary, melee: bool = true) -> void:
	if melee and not attacker.has("first_melee_tick"): attacker["first_melee_tick"] = state["tick"]
	if melee and not defender.has("first_melee_tick"): defender["first_melee_tick"] = state["tick"]
	if melee and Battle.opening(attacker, defender):
		_report(attacker, "小霸王连胜", "连续主动出战，首次接敌士气冲击提高8%。", false)
	if Battle.first_contact(attacker, defender, melee):
		attacker["first_contact_effect_tick"] = state["tick"]
		defender["first_contact_effect_tick"] = state["tick"]
		_report(defender, "武圣威压", "%s与%s首次正面交锋，士气下降8。" % [defender["name"], attacker["name"]], true)


func _battle_victory(army: Dictionary) -> void:
	if Battle.has_trait(army, "小霸王") and army.get("mission_type", "") == "capture" and not army.get("returning", false) and army.get("status", "") != "ended":
		state["battle_victories"][str(army["officer_id"])] = int(state["tick"])
