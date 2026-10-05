extends RefCounted

const Officer = preload("res://scripts/war/officer_battle.gd")
const Terrain = preload("res://scripts/war/battle_terrain.gd")
const Formation = preload("res://scripts/war/battle_formation.gd")
const TYPES := ["infantry", "archers", "cavalry"]


static func aggregate(armies: Array) -> Dictionary:
	var combined: Dictionary = {"units": {"infantry": 0, "archers": 0, "cavalry": 0}, "training": 0.0, "equipment": 0.0, "organization": 0.0, "fatigue": 0.0, "morale": 0.0, "skills": {"布阵": 0.0}}
	var total: int = 0
	combined["components"] = armies
	for army in armies:
		var count: int = strength(army)
		total += count
		for type in TYPES: combined["units"][type] += int(army["units"].get(type, 0))
		for field in ["training", "equipment", "organization", "fatigue", "morale"]:
			combined[field] += float(army.get(field, 50)) * count
		for group in preload("res://scripts/agents/officer_context.gd").SKILLS:
			for key in group:
				combined["skills"][key] = float(combined["skills"].get(key, 0)) + float(army.get("skills", {}).get(key, 50)) * count
	for field in ["training", "equipment", "organization", "fatigue", "morale"]:
		combined[field] /= maxf(total, 1)
	for key in combined["skills"]: combined["skills"][key] /= maxf(total, 1)
	return combined


static func strength(army: Dictionary) -> int:
	var count: int = 0
	for value in army.get("units", {}).values():
		count += int(value)
	return count


static func power_breakdown(army: Dictionary, config: Dictionary, terrain: String, defender: Dictionary = {}) -> Dictionary:
	var units: Dictionary = config.get("units", config)
	var base := 0.0
	var skilled := 0.0
	var adjusted := 0.0
	for type in TYPES:
		var amount := float(army.get("units", {}).get(type, 0)) * float(units[type]["damage"])
		base += amount
		skilled += amount * Officer.unit_attack(army, type, terrain)
		adjusted += amount * Officer.unit_attack(army, type, terrain) * Terrain.unit_factor(type, terrain, config)
	var ranged: bool = bool(army.get("ranged_attack", false))
	var result := {"base": base, "morale": clampf(float(army.get("morale",100))/100,0.25,1), "training": 0.6+float(army.get("training",50))/125, "equipment":0.7+float(army.get("equipment",50))/166.7, "organization":clampf(float(army.get("organization",100))/100,0.3,1), "fatigue":1-float(army.get("fatigue",0))/180, "command":clampf(0.8+Officer.skill(army,"布阵")/250,0.8,1.28)*Officer.factor(army,["带兵","治军"],0.002), "unit_skill":skilled/maxf(base,1), "terrain": adjusted/maxf(skilled,1), "terrain_class":terrain, "formation":Formation.attack(army,ranged,config), "delay":Terrain.entry_factor(army,config), "wounded": float(config.get("duel",Terrain.rules().get("duel",{})).get("wounded_attack",0.9)) if army.get("duel_wounded",false) else 1.0}
	result["power"] = base
	# Counters belong to the exchange, rather than the army's raw attack power.
	result["counters"] = counters(army, defender)
	for key in ["morale","training","equipment","organization","fatigue","command","unit_skill","terrain","formation","delay","wounded"]: result["power"] *= float(result[key])
	return result

static func power(army: Dictionary, config: Dictionary, terrain: String) -> float:
	if army.has("components"):
		var output := 0.0
		for member in army["components"]: output += power(member,config,terrain)
		return output
	return float(power_breakdown(army,config,terrain)["power"])

static func counters(attacker: Dictionary, defender: Dictionary) -> float:
	var count := maxf(strength(attacker), 1)
	var total := maxf(strength(defender), 1)
	return 1 + 0.15 * float(attacker.get("units",{}).get("cavalry",0))/count * float(defender.get("units",{}).get("archers",0))/total + 0.12 * float(attacker.get("units",{}).get("archers",0))/count * float(defender.get("units",{}).get("infantry",0))/total

static func losses(attacker: Dictionary, defender: Dictionary, config: Dictionary, terrain: String, random_factor: float, fortification: float = 1.0) -> int:
	var total := strength(defender)
	var output := power(attacker,config,terrain)
	if total <= 0 or output <= 0: return 0
	var rules: Dictionary = config.get("units",config)
	var data := Terrain.settings(terrain,config)
	var capacity := float(maxi(strength(attacker),total)) * float(data.get("capacity",1))
	var frontage := minf(1,capacity/maxf(strength(attacker),1))
	var toughness := 0.0
	for type in TYPES: toughness += float(defender.get("units",{}).get(type,0)) * float(rules[type]["toughness"])
	toughness /= total
	var counter_factor := counters(attacker, defender)
	var ranged: bool = bool(attacker.get("ranged_attack",false)) or int(attacker.get("units",{}).get("archers",0)) == strength(attacker)
	var ranged_factor := float(data.get("ranged_attack",1)) if ranged else 1.0
	var defense := toughness * fortification * Officer.defense(defender,terrain) * float(data.get("defense",1))
	var received := Formation.received(defender,terrain,ranged,bool(attacker.get("flanking_hit",false)),config)
	return clampi(int(output * frontage * counter_factor * 0.035 * random_factor * ranged_factor * received * Officer.tactic(attacker,defender)/maxf(defense,0.2)),1,total)


static func apply_loss(army: Dictionary, amount: int, captured: bool = false, morale_scale: float = 1.0) -> int:
	var remaining: int = mini(maxi(amount, 0), strength(army))
	var actual: int = remaining
	var total: int = strength(army)
	for index in range(TYPES.size()):
		var type: String = TYPES[index]
		var count: int = int(army["units"].get(type, 0))
		var loss: int = mini(count, remaining if index == TYPES.size() - 1 else int(ceil(float(actual) * count / maxf(total, 1))))
		loss = mini(loss, remaining)
		army["units"][type] = count - loss
		remaining -= loss
	if captured:
		army["captured"] = int(army.get("captured", 0)) + actual
	else:
		var dead: int = int(ceil(actual * 0.65))
		army["dead"] = int(army.get("dead", 0)) + dead
		army["wounded"] = int(army.get("wounded", 0)) + actual - dead
	army["morale"] = maxf(0, float(army.get("morale", 100)) - float(actual) / maxf(total, 1) * 85.0 * morale_scale * float(army.get("incoming_shock", 1.0)) / Officer.factor(army, ["沉着", "威仪", "忠义"], 0.003))
	army.erase("incoming_shock")
	army["organization"] = maxf(0, float(army.get("organization", 100)) - float(actual) / maxf(total, 1) * 70.0 / Officer.factor(army, ["治军", "应变"], 0.004))
	return actual


static func battle_morale(army: Dictionary, received: int, inflicted: float, before: int, enemy_before: float, friendly_strength: float, enemy_strength: float, flanked: bool = false) -> float:
	var hurt := float(received) / maxf(before, 1)
	var success := inflicted / maxf(enemy_before, 1)
	var advantage := friendly_strength / maxf(enemy_strength, 1)
	var resilience := Officer.factor(army, ["沉着", "威仪", "忠义"], 0.003)
	var change := (success * 50.0 - hurt * 85.0 * clampf(1.0 / maxf(advantage, 0.1), 0.65, 1.5)) / resilience
	# Winning a light exchange sustains morale; heavy losses still shake a larger army.
	if inflicted >= received and hurt <= 0.03 and advantage >= 0.9:
		change = maxf(change, minf(2.5, 0.6 + success * 25))
		army["organization"] = minf(100, float(army["organization"]) + 1.5 * Officer.factor(army, ["治军", "应变"], 0.004))
	if hurt >= 0.08: change = minf(change, -hurt * 65.0 / resilience)
	if flanked:
		change -= 2.0
		army["organization"] = maxf(0, float(army["organization"]) - 2.0)
	change = clampf(change, -20, 3)
	army["morale"] = clampf(float(army["morale"]) + change, 0, 100)
	army["morale_change"] = change
	army["morale_reason"] = "伤亡过重" if hurt >= 0.08 else "遭到夹击" if flanked else "占优稳住军心" if change >= 0 else "本日交战不利"
	return change
