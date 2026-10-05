extends RefCounted

# Cards already contain permanent trait bonuses. Only situational effects belong here.
static func skill(army: Dictionary, name: String) -> float:
	var value := clampf(float(army.get("skills", {}).get(name, 50)), 0, 120)
	return minf(value, 100) + maxf(0, value - 100) * 0.3

static func factor(army: Dictionary, names: Array, weight: float = 0.004) -> float:
	var value := 0.0
	for name in names: value += skill(army, name)
	return clampf(1 + (value / maxf(names.size(), 1) - 50) * weight, 0.7, 1.3)

static func has_trait(army: Dictionary, name: String) -> bool:
	return name in army.get("battle_traits", [])

static func traits(card: Dictionary) -> Array:
	var result: Array = []
	for entry in card.get("traits", []):
		if not entry["name"] in result: result.append(entry["name"])
	var sections: Dictionary = card.get("sections", {})
	var unique := str(sections.get("独有特性", "")).split("\n")[0].strip_edges()
	if not unique.is_empty() and not unique.begins_with("无") and not unique in result: result.append(unique)
	for key in ["特性", "共享与负面特性"]:
		for line in str(sections.get(key, "")).split("\n"):
			if not "：" in line: continue
			var name := line.split("：")[0].split("·")[-1].strip_edges()
			if name.begins_with("独有"): continue
			if not name in result: result.append(name)
	return result

static func unit_attack(army: Dictionary, type: String, terrain: String) -> float:
	var value := factor(army, ["武艺", "膂力"], 0.002) if type == "infantry" else factor(army, ["箭术", "沉着"], 0.003) if type == "archers" else factor(army, ["骑术", "武艺"], 0.003)
	if type == "cavalry" and has_trait(army, "骑战"): value *= 1.03
	if type == "archers" and has_trait(army, "百步穿杨"): value *= 1.06
	if has_trait(army, "精锐突击") and float(army.get("training", 50)) >= 80 and army.get("action", {}).get("type", "") in ["engage", "flank", "pursue"]: value *= 1.05
	if terrain in ["river", "ford"]: value *= factor(army, ["水练"], 0.005)
	if terrain in ["mountains", "hills"] and has_trait(army, "险地用兵"): value *= 1.06
	return value

static func defense(army: Dictionary, terrain: String) -> float:
	var value := factor(army, ["布阵", "应变", "治军"], 0.003)
	if terrain in ["river", "ford"]: value *= factor(army, ["水练"], 0.003)
	return value

static func tactic(attacker: Dictionary, defender: Dictionary) -> float:
	if attacker.has("components"):
		var weighted := 0.0
		var total := 0.0
		for member in attacker["components"]:
			var count := 0.0
			for value in member.get("units", {}).values(): count += float(value)
			weighted += tactic(member, defender) * count
			total += count
		return weighted / total if total > 0 else 1.0
	var action := str(attacker.get("action", {}).get("type", ""))
	if action not in ["flank", "pursue"]: return 1.0
	var advantage := (skill(attacker, "奇袭") + skill(attacker, "智计") - skill(defender, "料敌") - skill(defender, "应变")) / 2
	var value := clampf(1 + advantage * 0.003, 0.85, 1.15)
	if action == "flank" and has_trait(attacker, "穿插"): value *= 1.03
	if action == "pursue" and has_trait(attacker, "乘隙追击"): value *= 1.03
	if action == "flank" and has_trait(attacker, "运筹帷幄"): value *= 1.06
	return value

static func march_speed(army: Dictionary, terrain: String = "plains") -> float:
	var value := (0.8 + skill(army, "带兵") / 250) * factor(army, ["治军", "骑术"], 0.0015) - float(army.get("fatigue", 0)) / 250
	if terrain in ["river", "ford"]: value *= factor(army, ["水练"], 0.004)
	if terrain in ["mountains", "hills"] and has_trait(army, "险地用兵"): value *= 1.06
	if bool(army.get("victory_chain", false)) and not bool(army.get("opening_used", false)): value *= 1.08
	return clampf(value, 0.5, 1.3)

static func opening(attacker: Dictionary, defender: Dictionary) -> bool:
	if not bool(attacker.get("victory_chain", false)) or bool(attacker.get("opening_used", false)) or attacker.get("action", {}).get("type", "") not in ["engage", "continue"]: return false
	attacker["opening_used"] = true
	defender["incoming_shock"] = 1.08
	return true

static func fatigue_cost(army: Dictionary, base: float, fighting: bool = false) -> float:
	var value := base / factor(army, ["体魄", "治军"], 0.004)
	if has_trait(army, "百战成军"): value *= 0.94
	if fighting and has_trait(army, "耐战"): value *= 0.97
	return value

static func recovery(army: Dictionary) -> Dictionary:
	return {"fatigue": 5 * factor(army, ["体魄"], 0.005), "organization": 3 * factor(army, ["治军", "应变"], 0.005) * (1.06 if has_trait(army, "远征统筹") else 1.0), "morale": factor(army, ["威仪", "沉着", "辩才"], 0.005)}

static func first_contact(attacker: Dictionary, defender: Dictionary, melee: bool = true) -> bool:
	if not melee or attacker.get("action", {}).get("type", "") not in ["engage", "continue"] or not has_trait(attacker, "武圣") or skill(defender, "名望") < 80: return false
	var targets: Array = attacker.get("battle_contacts", [])
	var target := str(defender.get("officer_id", defender.get("id", "")))
	if target.is_empty() or target in targets: return false
	targets.append(target)
	attacker["battle_contacts"] = targets
	defender["morale"] = maxf(0, float(defender.get("morale", 100)) - 8)
	return true
