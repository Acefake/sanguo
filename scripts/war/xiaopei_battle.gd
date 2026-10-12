extends RefCounted

static func setup(store: Node, preformed: bool = false, options: Dictionary = {}) -> void:
	store._load_demo()
	store.war.setup(store, {})
	store.year = 191
	store.month = 9
	store.day = 1
	store.war.state["player_faction"] = "liu_bei"
	var sides := {"liu_bei": [], "yuan_shao": []}
	for officer in store.war.roster.officers.values():
		if str(officer["id"]).begins_with("militia:") or officer.get("generated", false): continue
		var faction := "liu_bei" if officer["faction"] == "liu_bei" else "yuan_shao"
		officer["faction"] = faction
		sides[faction].append(officer)
	for faction in sides:
		var strength := int(options.get(faction + "_strength", 20000))
		var home := "xiaopei" if faction == "liu_bei" else "puyang"
		var target := "puyang" if preformed and faction == "liu_bei" else "xiaopei"
		var city: Dictionary = store.city_state(home)
		city["faction"] = faction
		city["garrison"] = strength
		city["units"] = {"infantry": int(strength * 0.7), "archers": int(strength * 0.2), "cavalry": int(strength * 0.1)}
		city["grain"] = 100000
		city["training"] = 70
		city["equipment"] = 70
		var path: Dictionary = store.war.graph.path(home, "puyang" if home == "xiaopei" else "xiaopei")
		var members: Array = sides[faction].map(func(officer): return officer["id"])
		var leader: String = preload("res://scripts/war/army_corps.gd").best_member(store.war, members, "主帅")
		var army: Dictionary = store.war._mobilize({"home": home, "target": target, "officer_id": leader, "strength": strength, "grain": 3600, "mission_type": "defend" if not preformed and faction == "liu_bei" else "capture"})
		army["location"] = {"node": home, "from": home, "to": "puyang" if home == "xiaopei" else "xiaopei", "edge": path["edges"][0], "progress": 0.04 if faction == "liu_bei" else 0.92}
		preload("res://scripts/war/army_corps.gd").form(store.war, army, members, not preformed)

	if not preformed:
		var city: Dictionary = store.city_state("xiaopei")
		city.merge({"garrison": 3000, "units": {"infantry": 2400, "archers": 600, "cavalry": 0}, "grain": 18000, "defense": 65}, true)
	store.war._observe_all()
	preload("res://scripts/war/tactical_battlefield.gd").setup(store.war)
	preload("res://scripts/war/army_corps.gd").deploy(store.war)
	if not preformed:
		var grid = preload("res://scripts/war/tactical_battlefield.gd").grid()
		var cities: Array = JSON.parse_string(FileAccess.get_file_as_string("res://assets/rtk14/cities_map.json"))
		for city in cities:
			if city["name"] == "小沛": store.war.state["battlefield"]["objectives"] = {"xiaopei": grid.pick(Vector2(city["x"], city["z"]))}
	for army in store.war.active_armies(): army["intel"]["enemies"].clear()
	store.war._observe_all()
	store.war._update_operations()
