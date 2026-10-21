extends RefCounted

static func traits(config: Dictionary = {}) -> Dictionary:
	return config.get("troop_traits",preload("res://scripts/war/battle/battle_terrain.gd").rules().get("troop_traits",{}))

static func mobility(army: Dictionary, terrain: String, config: Dictionary = {}) -> float:
	var role := kind(army)
	var values: Dictionary = traits(config).get(role,{})
	var rate := float(values.get("movement",{}).get(terrain,1.0))
	if engine_count(army) > 0: rate = minf(rate,float(traits(config).get("engines",{}).get("movement",0.7)))
	return rate

static func exchange_factor(army: Dictionary, melee: bool, terrain: String, config: Dictionary = {}) -> float:
	if not melee: return 1.0
	var total := maxf(float(army.get("units",{}).get("infantry",0))+float(army.get("units",{}).get("cavalry",0))+float(army.get("units",{}).get("archers",0)),1)
	var share := float(army.get("units",{}).get("archers",0))/total
	var factor := lerpf(1.0,float(traits(config).get("archers",{}).get("melee_attack",0.45)),share)
	if kind(army) == "cavalry" and terrain == "plains" and int(army.get("tactical",{}).get("move_path",[]).size()) >= 2:
		factor *= float(traits(config).get("cavalry",{}).get("charge_attack",1.2))
	return factor

static func kind(army: Dictionary) -> String:
	var units: Dictionary = army.get("units", {})
	var best := "infantry"
	for type in ["archers", "cavalry"]:
		if int(units.get(type,0)) > int(units.get(best,0)): best = type
	return best

# Intelligence reports carry an estimated mix instead of real unit counts.
static func kind_from_mix(mix: Dictionary) -> String:
	var best := "infantry"
	for type in ["archers", "cavalry"]:
		if float(mix.get(type,0)) > float(mix.get(best,0)): best = type
	return best

static func role_fit(army: Dictionary, task: String) -> float:
	var type := kind(army)
	var units: Dictionary = army.get("units", {})
	var total := int(units.get("infantry",0)) + int(units.get("archers",0)) + int(units.get("cavalry",0))
	if total <= 0: return 0
	# Specialize units with a clear dominant arm; balanced mixes keep flexible roles.
	if float(units.get(type,0)) / total < 0.65: return 0
	if task in ["rear_guard","regroup","withdraw","reserve"]: return 0
	if int(army.get("siege_engines",0)) > 0:
		return 28 if task == "main_attack" else -32 if task in ["flank","raid_rear","cut_supply"] else 0
	if type == "archers": return 32 if task == "support" else -24 if task in ["main_attack","flank","raid_rear","cut_supply"] else 0
	if type == "cavalry": return 26 if task in ["flank","raid_rear","cut_supply"] else -16 if task == "support" else 0
	return 20 if task == "main_attack" else -16 if task == "support" else 0

static func engine_count(army: Dictionary) -> int:
	if army.get("returning",false) or army.get("status","active") == "ended": return 0
	var units: Dictionary = army.get("units",{})
	return mini(maxi(0,int(army.get("siege_engines",0))), int(units.get("infantry",0))/500)

static func can_breach(army: Dictionary) -> bool:
	# 骑兵不能破墙门；只有步兵（随军器械）才具备破坏城防设施的能力。
	return int(army.get("units", {}).get("infantry", 0)) > 0 or engine_count(army) > 0

static func breach_multiplier(group: Array) -> float:
	var engines := 0
	for army in group:
		engines += engine_count(army)
	return 1.0 + minf(0.6,engines*0.15)
