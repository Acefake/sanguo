extends RefCounted

const Fate = preload("res://scripts/war/campaign/officer_fate.gd")

static func policy(war, city: String) -> Dictionary:
	return war.state["city_policies"].get(city, {"defense": "adaptive", "rebuild": "balanced", "delegated": false})

static func configure(war, city_id: String, changes: Dictionary) -> Dictionary:
	if war.campaign_finished(): return {"ok": false, "message": "战役已经结束"}
	var city: String = war.store.canonical_city_id(city_id)
	if war.store.busy or not war.player_has_city_access(city): return {"ok": false, "message": "只能在空闲时设置本方城池方针"}
	var current := policy(war, city).duplicate(true)
	for key in changes:
		if key == "defense" and changes[key] in ["adaptive", "hold", "sortie"]: current[key] = changes[key]
		elif key == "rebuild" and changes[key] in ["balanced", "civil", "military"]: current[key] = changes[key]
		elif key == "delegated" and changes[key] is bool: current[key] = changes[key]
		else: return {"ok": false, "message": "未知的城池方针"}
	war.state["city_policies"][city] = current
	war.store.city_changed.emit(city)
	war.store._save()
	return {"ok": true, "message": "城池方针已更新"}

static func scout(_war, _city: String) -> Dictionary:
	return {"ok": false, "message": "全地图信息实时可见，无需侦察"}

static func scout_for_faction(_war, _home: String, _faction: String) -> Dictionary:
	return {"ok": false, "message": "全地图信息实时可见，无需侦察"}

static func cities(war, faction: String) -> Array:
	var result: Array = []
	for id in war.store.scenario["places"]:
		var city: Dictionary = war.store.city_state(id)
		if city.has("population") and city.get("faction", "") == faction: result.append(id)
	result.sort()
	return result

static func travel_days(war, start: String, destination: String) -> int:
	if start == "" or start == destination: return 0
	var faction := str(war.store.city_state(destination).get("faction", ""))
	var route: Dictionary = war.route(faction, start, destination)
	return maxi(1, ceili(float(route["cost"]) * float(war.rules["route_days_per_cost"]))) if route["found"] else -1

static func residence(war) -> void:
	if war.store.battle_test or not war.state.get("campaign_started", false): return
	var ids: Array = war.roster.officers.keys()
	ids.sort()
	var assigned := {}
	for id in ids:
		var officer: Dictionary = war.roster.officers[id]
		var faction := str(officer.get("faction", ""))
		var owned := cities(war, faction)
		if owned.is_empty() or Fate.unavailable(war, id): continue
		var status: Dictionary = war.state["officer_states"].get(id, {"status": "available"})
		if status.get("status", "") == "transferring":
			if int(status["arrives_at"]) > int(war.state["tick"]): continue
			var target := str(status["destination"])
			var arrived: bool = owned.has(target)
			if arrived:
				war.state["officer_states"][id] = {"status": "available", "city": target}
				_appoint(war, id, target, str(status.get("appointment", "")))
			else: war.state["officer_states"][id] = _escape(war, id, target, owned)
			continue
		if status.get("status", "") not in ["available", "recovering"]: continue
		if not status.has("city"):
			var index := int(assigned.get(faction, 0)) % owned.size()
			var home := str(officer.get("home", ""))
			status["city"] = home if owned.has(home) else owned[index]
			for node in owned:
				if war.store.city_state(node).get("governor_id", "") == id: status["city"] = node; break
			assigned[faction] = index + 1
		elif not owned.has(status["city"]):
			status = _escape(war, id, str(status["city"]), owned)
		war.state["officer_states"][id] = status

static func _escape(war, id: String, origin: String, owned: Array) -> Dictionary:
	var destination := ""
	var shortest := 100000
	for node in owned:
		var days := travel_days(war, origin, str(node))
		if days >= 0 and days < shortest:
			shortest = days
			destination = str(node)
	if destination != "": return {"status": "transferring", "city": origin, "destination": destination, "arrives_at": int(war.state["tick"]) + maxi(1, shortest), "appointment": ""}
	detach_post(war, id)
	var officer: Dictionary = war.roster.officers[id]
	var record := {"officer_id": id, "name": officer["name"], "faction": officer["faction"], "status": "captured", "tick": int(war.state["tick"]), "cause": "调任途中退路断绝", "captor_id": war.store.city_state(origin).get("governor_id", ""), "captor_faction": war.store.city_state(origin).get("faction", ""), "city": origin}
	war.state["officer_fates"][id] = record.duplicate(true)
	record["lost"] = true
	war.Feedback.event(war, "武将被俘", str(officer["name"]) + "调任途中退路断绝，被当地势力扣留。", str(officer["faction"]))
	return record

static func assembly_days(war, home: String, officers: Array) -> int:
	if war.store.battle_test or not war.state.get("campaign_started", false): return 0
	var delay := 0
	for id in officers:
		var origin := str(war.state["officer_states"].get(id, {}).get("city", home))
		var days := travel_days(war, origin, home)
		if days < 0: return -1
		delay = maxi(delay, days)
	return delay

static func detach_post(war, id: String) -> void:
	for city in war.store.scenario["places"].values():
		if city.get("governor_id", "") == id: city["governor_id"] = ""
	for node in war.state["garrison_commanders"].keys():
		if war.state["garrison_commanders"][node].get("officer_id", "") == id: war.state["garrison_commanders"].erase(node)

static func _appoint(war, id: String, city: String, office: String) -> void:
	detach_post(war, id)
	if office == "governor": war.store.city_state(city)["governor_id"] = id
	elif office == "guard":
		war.state["garrison_commanders"][city] = {"officer_id": id, "name": war.roster.officers[id]["name"], "faction": war.roster.officers[id]["faction"], "city": city, "enemy_killed": 0}
	war.store.city_changed.emit(city)
	if war.characters.states.has(id):
		war.characters.record(id, "appointment:%s:%s:%d" % [city, office, int(war.state["tick"])], "appointment", int(war.state["tick"]), {"city":city, "job":office})

static func assign(war, id: String, city_id: String, office: String = "") -> Dictionary:
	if war.campaign_finished(): return {"ok": false, "message": "战役已经结束"}
	var city: String = war.store.canonical_city_id(city_id)
	if war.store.busy or not war.player_has_city_access(city) or office not in ["", "governor", "guard"]: return {"ok": false, "message": "任命目标必须是本方城池"}
	var officer: Dictionary = war.roster.officers.get(id, {})
	if officer.get("faction", "") != war.state["player_faction"] or not war.available_officers(str(war.state["player_faction"])).any(func(candidate): return candidate["id"] == id): return {"ok": false, "message": "武将正在执行任务、负伤或不属本方"}
	if war.store.action_points <= 0: return {"ok": false, "message": "本月行动力已用尽"}
	if war.is_besieged(city): return {"ok": false, "message": "围城期间无法调任人员"}
	var origin := str(war.state["officer_states"].get(id, {}).get("city", city))
	var days := travel_days(war, origin, city)
	if days < 0: return {"ok": false, "message": "没有可用的调任通路"}
	detach_post(war, id)
	war.store.action_points -= 1
	if days > 0: war.state["officer_states"][id] = {"status": "transferring", "city": origin, "destination": city, "arrives_at": int(war.state["tick"]) + days, "appointment": office}
	else:
		war.state["officer_states"][id] = {"status": "available", "city": city}
		_appoint(war, id, city, office)
	war.store._save()
	return {"ok": true, "message": "调任已下达，预计%d日后到任" % days, "days": days}

static func result(war) -> void:
	if war.store.battle_test or not war.state.get("campaign_started", false) or not war.state["campaign_result"].is_empty(): return
	var player := str(war.state["player_faction"])
	var owned := cities(war, player).size()
	var total := 0
	var controlled := 0
	for city in war.store.scenario["places"].values():
		if city.has("garrison"):
			total += 1
			if city.get("faction", "") == player: controlled += 1
	var status := "victory" if controlled == total and total > 0 else "defeat" if owned == 0 and war.active_armies(player).is_empty() else ""
	if status != "":
		war.state["campaign_result"] = {"status": status, "tick": int(war.state["tick"]), "message": "全国城池与关隘已统一，战役胜利。" if status == "victory" else "本方已失去全部城池与在役军队，战役失败。"}
		war.urgent_event = true
