extends RefCounted

static func setup(store: Node) -> void:
	store._load_demo()
	store.year = 191
	store.month = 9
	store.day = 1
	store.war.state["player_faction"] = "liu_bei"
	var sides := {"liu_bei": [], "yuan_shao": []}
	for officer in store.war.roster.officers.values():
		if str(officer["id"]).begins_with("militia:"): continue
		var faction := "liu_bei" if officer["faction"] == "liu_bei" else "yuan_shao"
		officer["faction"] = faction
		sides[faction].append(officer)
	for faction in sides:
		var home := "xiaopei" if faction == "liu_bei" else "puyang"
		var target := "puyang" if faction == "liu_bei" else "xiaopei"
		var city: Dictionary = store.city_state(home)
		city["faction"] = faction
		city["garrison"] = 20000
		city["units"] = {"infantry": 14000, "archers": 4000, "cavalry": 2000}
		city["grain"] = 100000
		city["training"] = 70
		city["equipment"] = 70
		var path: Dictionary = store.war.graph.path(home, target)
		var index := 0
		for officer in sides[faction]:
			var count := int(20000 / sides[faction].size())
			var food := int(count * store.war.rules["grain_per_soldier_day"] * 45)
			var army: Dictionary = store.war._mobilize({"home": home, "target": target, "officer_id": officer["id"], "strength": count, "grain": food, "mission_type": "capture"})
			army["location"] = {"node": home, "from": home, "to": target, "edge": path["edges"][0], "progress": 0.04 if faction == "liu_bei" else 0.92}
			army["action"] = {"type": "continue"}
			army["last_reason"] = "小沛对战测试：敌军近在前方，由主将自主判断。"
			store.battle_offsets[army["id"]] = Vector3((index % 4 - 1.5) * 24, 0, (index / 4) * 24 + (-42 if faction == "liu_bei" else 42))
			index += 1
	store.war._observe_all()
