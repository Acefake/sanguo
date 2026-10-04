extends RefCounted

const TYPES := ["infantry", "archers", "cavalry"]


static func aggregate(armies: Array) -> Dictionary:
	var combined: Dictionary = {"units": {"infantry": 0, "archers": 0, "cavalry": 0}, "training": 0.0, "equipment": 0.0, "organization": 0.0, "fatigue": 0.0, "skills": {"布阵": 0.0}}
	var total: int = 0
	for army in armies:
		var count: int = strength(army)
		total += count
		for type in TYPES: combined["units"][type] += int(army["units"].get(type, 0))
		for field in ["training", "equipment", "organization", "fatigue"]:
			combined[field] += float(army.get(field, 50)) * count
		combined["skills"]["布阵"] += float(army.get("skills", {}).get("布阵", 50)) * count
	for field in ["training", "equipment", "organization", "fatigue"]:
		combined[field] /= maxf(total, 1)
	combined["skills"]["布阵"] /= maxf(total, 1)
	return combined


static func strength(army: Dictionary) -> int:
	var count: int = 0
	for value in army.get("units", {}).values():
		count += int(value)
	return count


static func power(army: Dictionary, unit_rules: Dictionary, terrain: String) -> float:
	var output: float = 0.0
	for type in TYPES:
		var terrain_factor: float = 0.8 if type == "cavalry" and terrain in ["mountains", "river"] else 1.0
		output += float(army.get("units", {}).get(type, 0)) * float(unit_rules[type]["damage"]) * terrain_factor
	var skills: Dictionary = army.get("skills", {})
	var command: float = clampf(0.8 + float(skills.get("布阵", 50)) / 250.0, 0.8, 1.28)
	return output * (0.6 + float(army.get("training", 50)) / 125.0) * (0.7 + float(army.get("equipment", 50)) / 166.7) * clampf(float(army.get("organization", 100)) / 100.0, 0.3, 1.0) * (1.0 - float(army.get("fatigue", 0)) / 180.0) * command


static func losses(attacker: Dictionary, defender: Dictionary, rules: Dictionary, terrain: String, random_factor: float, fortification: float = 1.0) -> int:
	var total: int = strength(defender)
	if total <= 0:
		return 0
	var capacity: float = float(maxi(strength(attacker), total)) * (0.6 if terrain == "mountains" else 1.0)
	var frontage: float = minf(1.0, capacity / maxf(strength(attacker), 1))
	var toughness: float = 0.0
	for type in TYPES:
		toughness += float(defender.get("units", {}).get(type, 0)) * float(rules[type]["toughness"])
	toughness /= float(total)
	var attacker_count: float = maxf(strength(attacker), 1)
	var counters: float = 1.0 + 0.15 * float(attacker.get("units", {}).get("cavalry", 0)) / attacker_count * float(defender.get("units", {}).get("archers", 0)) / total + 0.12 * float(attacker.get("units", {}).get("archers", 0)) / attacker_count * float(defender.get("units", {}).get("infantry", 0)) / total
	return clampi(int(power(attacker, rules, terrain) * frontage * counters * 0.035 * random_factor / maxf(toughness * fortification, 0.2)), 1, total)


static func apply_loss(army: Dictionary, amount: int, captured: bool = false) -> int:
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
	army["morale"] = maxf(0, float(army.get("morale", 100)) - float(actual) / maxf(total, 1) * 240.0 - (1.5 if actual > 0 else 0.0))
	army["organization"] = maxf(0, float(army.get("organization", 100)) - float(actual) / maxf(total, 1) * 130.0)
	return actual
