class_name FactionLifecycle
extends RefCounted
## 势力维护：补足各势力武将、登记生成将、校正各城太守任命。

const Fate = preload("res://scripts/war/campaign/officer_fate.gd")
const StateKeys = preload("res://scripts/war/campaign/war_state_keys.gd")

static func maintain(war) -> void:
	war.roster.ensure_factions(war.store.scenario)
	var registered: Dictionary = war.state[StateKeys.GENERATED_OFFICERS]
	for id in war.roster.officers:
		# 登记内容已经相同时不再深拷贝一份（每天两次、八十多名生成将）。
		if war.roster.officers[id].get("generated", false) and registered.get(id) != war.roster.officers[id]: registered[id] = war.roster.officers[id].duplicate(true)
	var claimed := {}
	# 本次维护里各势力的可用武将：逐城任命太守不改变可用性，只有下面释放守将会改，届时全部清空。
	var available := {}
	var nodes: Array = war.store.scenario.get("places", {}).keys()
	nodes.sort()
	for node in nodes:
		var city: Dictionary = war.store.city_state(node)
		if not city.has("population"): continue
		var faction := str(city.get("faction", ""))
		if faction == "": city["governor_id"] = ""; continue
		var id := str(city.get("governor_id", ""))
		var guard_id := str(war.state[StateKeys.GARRISON_COMMANDERS].get(node, {}).get("officer_id", ""))
		var officer_state: Dictionary = war.state[StateKeys.OFFICER_STATES].get(id, {})
		if war.roster.officers.get(id, {}).get("faction", "") != faction or Fate.unavailable(war, id) or claimed.has(id) or id == guard_id or officer_state.get("status", "available") != "available" or (war.state.get(StateKeys.CAMPAIGN_STARTED, false) and officer_state.get("city", node) != node): id = ""
		if id == "":
			if not available.has(faction): available[faction] = war.available_officers(faction)
			for officer in available[faction]:
				if officer["id"] == guard_id or (war.state.get(StateKeys.CAMPAIGN_STARTED, false) and war.state[StateKeys.OFFICER_STATES].get(officer["id"], {}).get("city", node) != node): continue
				if not claimed.has(officer["id"]): id = str(officer["id"]); break
		city["governor_id"] = id
		if id != "": claimed[id] = true
		var guard: Dictionary = war.state[StateKeys.GARRISON_COMMANDERS].get(node, {})
		if not guard.is_empty():
			var officer := str(guard["officer_id"])
			var defending: bool = war.active_armies().any(func(army): return war.hostile(str(army["faction"]), faction) and army.has("tactical") and war.Siege.at_city(war, army, node, 4))
			if not defending and not Fate.unavailable(war, officer) and war.state[StateKeys.OFFICER_STATES].get(officer, {}).get("status", "") == "guarding":
				war.state[StateKeys.OFFICER_STATES][officer] = {"status": "available", "city": node}
				available.clear()
	# 各势力城数与在任武将数一次数完，不再按势力逐个扫全部城池和武将。
	var city_counts := {}
	for city in war.store.scenario["places"].values():
		if city.has("population"): city_counts[city.get("faction", "")] = int(city_counts.get(city.get("faction", ""), 0)) + 1
	var serving := {}
	for officer in war.roster.officers.values():
		if not str(officer["id"]).begins_with("militia:") and not Fate.unavailable(war, str(officer["id"])): serving[officer.get("faction", "")] = true
	for faction in war.store.scenario.get("factions", {}):
		var cities: int = int(city_counts.get(faction, 0))
		# New local leadership is recruited; a dead or imprisoned historical officer
		# is never revived simply to keep an AI faction running.
		if cities > 0 and not serving.has(faction):
			var id := "local:%s:regent:%d" % [faction, int(war.state[StateKeys.TICK])]
			var template: String = war.roster.militia(faction, "regency")
			var officer: Dictionary = war.roster.officers[template].duplicate(true)
			officer.merge({"id": id, "name": str(war.store.scenario["factions"][faction]["name"]) + "·继任主政", "generated": true, "positions": "核心位置：君主"}, true)
			war.roster.officers[id] = officer
			war.state[StateKeys.GENERATED_OFFICERS][id] = officer.duplicate(true)
		var lord: Dictionary = war.lords.lord(war.roster, faction, war.state[StateKeys.OFFICER_STATES])
		war.state[StateKeys.FACTION_STATUS][faction] = {"status": "active" if cities > 0 else "in_exile" if not war.active_armies(faction).is_empty() else "defeated", "cities": cities, "lord_id": str(lord.get("id", ""))}
	if int(war.state[StateKeys.TICK]) % 30 != 0: return
	for id in war.state[StateKeys.OFFICER_FATES]:
		var fate: Dictionary = war.state[StateKeys.OFFICER_FATES][id]
		var captor := str(fate.get("captor_faction", ""))
		if fate.get("status", "") != "captured" or captor == war.state[StateKeys.PLAYER_FACTION]: continue
		var lord: Dictionary = war.Strategic.lord_of(war.roster, captor, war.state[StateKeys.OFFICER_STATES])
		var age := int(war.state[StateKeys.TICK]) - int(fate.get("tick", 0))
		if age < 60 and (age < 30 or float(lord.get("personality", {}).get("同理心", 50)) < 60): continue
		fate["status"] = "released"
		fate["released_at"] = int(war.state[StateKeys.TICK])
		war.state[StateKeys.OFFICER_STATES][id] = {"status": "recovering", "available_after": int(war.state[StateKeys.TICK]) + 10}
