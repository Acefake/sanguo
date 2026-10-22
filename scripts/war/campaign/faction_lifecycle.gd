class_name FactionLifecycle
extends RefCounted
## 势力维护：补足各势力武将、登记生成将、校正各城太守任命。

const Fate = preload("res://scripts/war/campaign/officer_fate.gd")

static func maintain(war) -> void:
	war.roster.ensure_factions(war.store.scenario)
	for id in war.roster.officers:
		if war.roster.officers[id].get("generated", false): war.state["generated_officers"][id] = war.roster.officers[id].duplicate(true)
	var claimed := {}
	var nodes: Array = war.store.scenario.get("places", {}).keys()
	nodes.sort()
	for node in nodes:
		var city: Dictionary = war.store.city_state(node)
		if not city.has("population"): continue
		var faction := str(city.get("faction", ""))
		if faction == "": city["governor_id"] = ""; continue
		var id := str(city.get("governor_id", ""))
		var guard_id := str(war.state["garrison_commanders"].get(node, {}).get("officer_id", ""))
		var officer_state: Dictionary = war.state["officer_states"].get(id, {})
		if war.roster.officers.get(id, {}).get("faction", "") != faction or Fate.unavailable(war, id) or claimed.has(id) or id == guard_id or officer_state.get("status", "available") != "available" or (war.state.get("campaign_started", false) and officer_state.get("city", node) != node): id = ""
		if id == "":
			for officer in war.available_officers(faction):
				if officer["id"] == guard_id or (war.state.get("campaign_started", false) and war.state["officer_states"].get(officer["id"], {}).get("city", node) != node): continue
				if not claimed.has(officer["id"]): id = str(officer["id"]); break
		city["governor_id"] = id
		if id != "": claimed[id] = true
		var guard: Dictionary = war.state["garrison_commanders"].get(node, {})
		if not guard.is_empty():
			var officer := str(guard["officer_id"])
			var defending: bool = war.active_armies().any(func(army): return war.hostile(str(army["faction"]), faction) and army.has("tactical") and war.Siege.at_city(war, army, node, 4))
			if not defending and not Fate.unavailable(war, officer) and war.state["officer_states"].get(officer, {}).get("status", "") == "guarding": war.state["officer_states"][officer] = {"status": "available", "city": node}
	for faction in war.store.scenario.get("factions", {}):
		var cities := 0
		for city in war.store.scenario["places"].values():
			if city.has("population") and city.get("faction", "") == faction: cities += 1
		var remaining: Array = war.roster.officers.values().filter(func(officer): return officer.get("faction", "") == faction and not str(officer["id"]).begins_with("militia:") and not Fate.unavailable(war, str(officer["id"])))
		# New local leadership is recruited; a dead or imprisoned historical officer
		# is never revived simply to keep an AI faction running.
		if cities > 0 and remaining.is_empty():
			var id := "local:%s:regent:%d" % [faction, int(war.state["tick"])]
			var template: String = war.roster.militia(faction, "regency")
			var officer: Dictionary = war.roster.officers[template].duplicate(true)
			officer.merge({"id": id, "name": str(war.store.scenario["factions"][faction]["name"]) + "·继任主政", "generated": true, "positions": "核心位置：君主"}, true)
			war.roster.officers[id] = officer
			war.state["generated_officers"][id] = officer.duplicate(true)
		var lord: Dictionary = war.Strategic.lord_of(war.roster, faction, war.state["officer_states"])
		war.state["faction_status"][faction] = {"status": "active" if cities > 0 else "in_exile" if not war.active_armies(faction).is_empty() else "defeated", "cities": cities, "lord_id": str(lord.get("id", ""))}
	if int(war.state["tick"]) % 30 != 0: return
	for id in war.state["officer_fates"]:
		var fate: Dictionary = war.state["officer_fates"][id]
		var captor := str(fate.get("captor_faction", ""))
		if fate.get("status", "") != "captured" or captor == war.state["player_faction"]: continue
		var lord: Dictionary = war.Strategic.lord_of(war.roster, captor, war.state["officer_states"])
		var age := int(war.state["tick"]) - int(fate.get("tick", 0))
		if age < 60 and (age < 30 or float(lord.get("personality", {}).get("同理心", 50)) < 60): continue
		fate["status"] = "released"
		fate["released_at"] = int(war.state["tick"])
		war.state["officer_states"][id] = {"status": "recovering", "available_after": int(war.state["tick"]) + 10}
