extends RefCounted

const Tactical = preload("res://scripts/war/tactical_battlefield.gd")
const Corps = preload("res://scripts/war/army_corps.gd")

static func definitions() -> Array:
	return JSON.parse_string(FileAccess.get_file_as_string("res://data/war/battle_scenarios.json"))

static func definition(id: String) -> Dictionary:
	for entry in definitions():
		if entry["id"] == id: return entry
	return {}

static func setup(store: Node, id: String, seed: int, preformed: bool = false) -> void:
	var spec := definition(id)
	assert(not spec.is_empty(), "Unknown battle scenario")
	var options := {"liu_bei_strength": 6000} if spec.get("kind", "") == "siege" else {}
	# Standalone battles open with visible specialized detachments on both sides.
	preload("res://scripts/war/xiaopei_battle.gd").setup(store, preformed, options)
	var war = store.war
	compose(war, spec)
	if spec.get("kind", "") in ["combined","siege"]:
		store.city_state("xiaopei").merge({"garrison":3000,"units":{"infantry":2400,"archers":600,"cavalry":0},"grain":18000,"defense":65},true)
	if spec.get("kind", "") in ["combined","siege"]:
		for army in war.active_armies("liu_bei"): army["mission_type"] = "defend"
	war.rng.seed = seed
	war.state["rng_state"] = str(war.rng.state)
	if id != "xiaopei":
		if spec.get("kind", "") == "siege":
			for army in war.active_armies("liu_bei"):
				army["location"] = {"node": "xiaopei", "edge": "", "progress": 0.0}
				war._finish(army, "守军归城")
			for corps_id in war.state["corps"].keys():
				if war.state["corps"][corps_id]["faction"] == "liu_bei": war.state["corps"].erase(corps_id)
			war.state["player_faction"] = "yuan_shao"
		for army in war.active_armies(): army.erase("tactical")
		Tactical.setup(war, int(spec["anchor"]))
		Corps.deploy(war)
		var board: Dictionary = war.state["battlefield"]
		if spec.get("kind", "") == "siege":
			var cities: Array = JSON.parse_string(FileAccess.get_file_as_string("res://assets/rtk14/cities_map.json"))
			for city in cities:
				if city["name"] == "小沛": board["objectives"] = {"xiaopei": Tactical.grid().pick(Vector2(city["x"], city["z"]))}
		else:
			for army in war.active_armies():
				army["mission_type"] = "defend"
				army["target"] = "puyang" if army["faction"] == "liu_bei" else "xiaopei"
				army["deadline"] = 180
		for army in war.active_armies(): army["intel"]["enemies"].clear()
		war._observe_all()
		war._update_operations()
	war.state["battlefield"]["scenario_id"] = id
	war.state["battlefield"]["scenario_name"] = spec["name"]
	war.state["battlefield"]["seed"] = seed
	if spec.get("kind", "") in ["combined","siege"]:
		var cities: Array = JSON.parse_string(FileAccess.get_file_as_string("res://assets/rtk14/cities_map.json"))
		for city in cities:
			if city["name"] == "小沛": war.state["battlefield"]["objectives"] = {"xiaopei":Tactical.grid().pick(Vector2(city["x"],city["z"]))}
	Corps.deploy(war)
	for army in war.active_armies(): army["intel"]["enemies"].clear()
	war._observe_all()
	war._update_operations()

static func compose(war, spec: Dictionary) -> void:
	for corps in war.state["corps"].values():
		corps["battle_troop_profile"] = spec.duplicate(true)
		if corps["units"].size() > 1:
			corps["deployed"] = true
			compose_corps(war,corps,spec)

static func compose_corps(war, corps: Dictionary, spec: Dictionary) -> void:
	var profile: Array = spec.get("troops", ["infantry","cavalry","infantry","archers","infantry"])
	for i in range(corps["units"].size()):
		var army: Dictionary = war.state["armies"][corps["units"][i]]
		var count: int = preload("res://scripts/war/combat_system.gd").strength(army)
		var kind: String = profile[i % profile.size()]
		army["units"] = {"infantry":0,"archers":0,"cavalry":0}
		army["units"][kind] = count
		army["siege_engines"] = int(spec.get("engines",0)) if i == 2 else 0
		if i != 0:
			army["corps_task"]["type"] = "reserve" if i == 4 else "support" if kind == "archers" else "flank" if kind == "cavalry" else "main_attack"
			army["corps_task"]["reason"] = "按兵种部署：" + {"infantry":"步兵守线","archers":"弓兵远射","cavalry":"骑兵侧击"}[kind]
