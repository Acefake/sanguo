class_name BattleScenarios
extends RefCounted
## 战斗测试场景：读取场景定义，建立战场并编组参战军与军团。

const Tactical = preload("res://scripts/war/battle/tactical_battlefield.gd")
const Corps = preload("res://scripts/war/campaign/army_corps.gd")

const LEGACY_ALIASES := {
	"plains_clash": "guandu_clash",
	"mountain_pass": "hulao_pass",
	"siege_assault": "xiapi_siege",
	"forest_ambush": "yiling_forest",
	"hill_contest": "dingjun_hill",
	"river_ford": "chibi_ford",
	"marsh_battle": "wancheng_marsh",
	"city_relief": "xiangyang_relief",
}

static func definitions() -> Array:
	return JSON.parse_string(FileAccess.get_file_as_string("res://data/war/battle_scenarios.json"))

static func definition(id: String) -> Dictionary:
	var actual_id: String = LEGACY_ALIASES.get(id, id)
	for entry in definitions():
		if entry["id"] == actual_id: return entry
	return {}

static func setup(store: Node, id: String, seed: int, preformed: bool = false) -> void:
	var spec := definition(id)
	assert(not spec.is_empty(), "Unknown battle scenario")
	var strengths: Dictionary = spec.get("strengths", {"liu_bei": 20000, "yuan_shao": 20000})
	var options := {"liu_bei_strength": int(strengths["liu_bei"]), "yuan_shao_strength": int(strengths["yuan_shao"])}
	preload("res://scripts/war/battle/xiaopei_battle.gd").setup(store, preformed, options)
	var war = store.war
	var city_battle: bool = spec["kind"] in ["siege", "combined"]
	if city_battle:
		store.city_state("xiaopei").merge({"faction": "liu_bei", "garrison": int(spec.get("garrison", 3000)), "units": {"infantry": int(spec.get("garrison", 3000) * 0.8), "archers": int(spec.get("garrison", 3000) * 0.2), "cavalry": 0}, "grain": 18000, "defense": int(spec.get("defense", 65))}, true)
	if spec["kind"] == "siege":
		for army in war.active_armies("liu_bei"):
			army["location"] = {"node": "xiaopei", "edge": "", "progress": 0.0}
			war._finish(army, "守军归城")
		for corps_id in war.state["corps"].keys():
			if war.state["corps"][corps_id]["faction"] == "liu_bei": war.state["corps"].erase(corps_id)
		war.state["player_faction"] = "yuan_shao"
	for army in war.active_armies():
		army.erase("tactical")
		army["mission_type"] = "capture" if city_battle and army["faction"] == "yuan_shao" else "defend"
		army["target"] = "xiaopei" if army["faction"] == "yuan_shao" else "puyang"
		army["deadline"] = 180
		var condition: Dictionary = spec.get("side_condition", {}).get(army["faction"], {})
		for attribute in ["organization", "morale", "fatigue"]:
			if condition.has(attribute): army[attribute] = float(condition[attribute])
	Tactical.setup(war, int(spec["anchor"]))
	var board: Dictionary = war.state["battlefield"]
	board["scenario_id"] = str(spec["id"])
	board["scenario_name"] = spec["name"]
	board["scenario_category"] = spec.get("category", "")
	board["objective_text"] = spec.get("objective_text", "击溃或迫退敌军")
	board["camera_distance"] = spec.get("camera_distance", 180)
	board["seed"] = seed
	board["objectives"] = {"xiaopei": int(Tactical.Fort.for_city(store, "xiaopei")["center"])} if city_battle else {}
	board["scenario_deployment"] = spec.get("deployment", [])
	board["side_deployment"] = spec.get("side_deployment", {})
	if spec.has("control"):
		board["control_point"] = spec["control"].duplicate(true)
		board["control_point"].merge({"cell": int(spec["anchor"]), "owner": "", "progress": 0, "contested": false, "updated_at": -1}, true)
	# Keep all initial positions in one real connected land component.
	if not city_battle: board["deployment_cells"] = connected_cells(board, int(spec["anchor"]))
	compose(war, spec)
	Corps.deploy(war)
	for army in war.active_armies(): army["intel"]["enemies"].clear()
	war.rng.seed = seed
	war.state["rng_state"] = str(war.rng.state)
	war._observe_all()
	war._update_operations()

static func connected_cells(board: Dictionary, start: int) -> Array:
	var queue: Array = [start]
	var seen := {start: true}
	var cursor := 0
	while cursor < queue.size():
		var cell: int = queue[cursor]
		cursor += 1
		for neighbor in Tactical.neighbors(cell):
			if seen.has(neighbor) or not Tactical.in_battlefield(board, neighbor): continue
			seen[neighbor] = true
			queue.append(neighbor)
	return queue

static func compose(war, spec: Dictionary) -> void:
	for corps in war.state["corps"].values():
		corps["battle_troop_profile"] = spec.duplicate(true)
		if corps["units"].size() > 1:
			corps["deployed"] = true
			compose_corps(war, corps, spec)

static func compose_corps(war, corps: Dictionary, spec: Dictionary) -> void:
	var profile: Array = spec.get("troops", ["infantry", "cavalry", "infantry", "archers", "infantry"])
	var front_index := 0
	var guard_index := 0
	for id in corps["units"]:
		var army: Dictionary = war.state["armies"][id]
		if army["status"] == "ended": continue
		var role: String = corps["appointments"].get(army["officer_id"], "主帅")
		var index := 0
		if role == "前锋": index = 1 + mini(front_index, 1); front_index += 1
		elif role == "护军": index = 3 + mini(guard_index, 1); guard_index += 1
		var count: int = war.Combat.strength(army)
		var kind: String = profile[index % profile.size()]
		army["scenario_slot"] = index
		army["units"] = {"infantry": 0, "archers": 0, "cavalry": 0}
		army["units"][kind] = count
		army["siege_engines"] = int(spec.get("engines", 0)) if index == 2 and army["faction"] == "yuan_shao" else 0
		if index != 0:
			army["corps_task"]["type"] = "reserve" if index == 4 else "support" if kind == "archers" else "flank" if kind == "cavalry" else "main_attack"
			army["corps_task"]["reason"] = "主帅按兵种部署：" + {"infantry": "步兵守线", "archers": "弓兵远射", "cavalry": "骑兵侧击"}[kind]
