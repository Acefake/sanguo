extends RefCounted

const Traits = preload("res://scripts/officers/trait_registry.gd")

# Cards already contain permanent trait bonuses. Situational effects come from the
# trait registry hooks; no code here branches on a trait name.
static func skill(army: Dictionary, name: String) -> float:
	var value := clampf(float(army.get("skills", {}).get(name, 50)) + Traits.attribute_points(army, name), 0, 120)
	return minf(value, 100) + maxf(0, value - 100) * 0.3

static func factor(army: Dictionary, names: Array, weight: float = 0.004) -> float:
	var value := 0.0
	for name in names: value += skill(army, name)
	return clampf(1 + (value / maxf(names.size(), 1) - 50) * weight, 0.7, 1.3)

static func unit_attack(army: Dictionary, type: String, terrain: String) -> float:
	var value := factor(army, ["武艺", "膂力"], 0.002) if type == "infantry" else factor(army, ["箭术", "沉着"], 0.003) if type == "archers" else factor(army, ["骑术", "武艺"], 0.003)
	if terrain in ["river", "ford"]: value *= factor(army, ["水练"], 0.005)
	return value

static func defense(army: Dictionary, terrain: String, config: Dictionary = {}) -> float:
	var value := factor(army, ["布阵", "应变", "治军"], 0.003)
	if terrain in ["river", "ford"]: value *= factor(army, ["水练"], 0.003)
	# First layer: the officer's defensive composite is deliberately narrow.
	var section: Dictionary = config.get("officer", {})
	return clampf(value, float(section.get("defense_min", 0.9)), float(section.get("defense_max", 1.1)))


static func aura_strength(army: Dictionary, config: Dictionary = {}) -> float:
	var section: Dictionary = config.get("officer", {})
	var average := (skill(army, "带兵") + skill(army, "威仪") + skill(army, "治军")) / 3.0
	var value := maxf(0.0, average - 50.0) * float(section.get("aura_skill_weight", 0.003))
	return clampf(value, 0.0, float(section.get("aura_max", 0.15)))


static func aura_range(army: Dictionary, config: Dictionary = {}) -> int:
	var section: Dictionary = config.get("officer", {})
	var bonus := int(section.get("aura_range_bonus", 1)) if skill(army, "威仪") >= float(section.get("aura_range_skill", 80)) else 0
	return int(section.get("aura_range", 3)) + bonus

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
	return clampf(1 + advantage * 0.003, 0.85, 1.15)

static func march_speed(army: Dictionary, terrain: String = "plains") -> float:
	var value := (0.8 + skill(army, "带兵") / 250) * factor(army, ["治军", "骑术"], 0.0015) - float(army.get("fatigue", 0)) / 250
	if terrain in ["river", "ford"]: value *= factor(army, ["水练"], 0.004)
	value /= 1.0 + Traits.modifier(army, "march行军", {"terrain": terrain})
	if bool(army.get("victory_chain", false)) and not bool(army.get("opening_used", false)): value *= float(Traits.mechanism(army, "victory_chain").get("march", 1.0))
	return clampf(value, 0.5, 1.3)

static func opening(attacker: Dictionary, defender: Dictionary) -> bool:
	if not bool(attacker.get("victory_chain", false)) or bool(attacker.get("opening_used", false)) or attacker.get("action", {}).get("type", "") not in ["engage", "continue"]: return false
	attacker["opening_used"] = true
	defender["incoming_shock"] = float(Traits.mechanism(attacker, "victory_chain").get("shock", 1.0))
	return true

static func fatigue_cost(army: Dictionary, base: float, fighting: bool = false) -> float:
	return base / factor(army, ["体魄", "治军"], 0.004) * (1.0 + Traits.modifier(army, "fatigue疲劳", {"in_contact": fighting}))

static func recovery(army: Dictionary) -> Dictionary:
	return {"fatigue": 5 * factor(army, ["体魄"], 0.005), "organization": 3 * factor(army, ["治军", "应变"], 0.005) * (1.0 + Traits.modifier(army, "rally收拢", {"resting": true})), "morale": factor(army, ["威仪", "沉着", "辩才"], 0.005)}

static func first_contact(attacker: Dictionary, defender: Dictionary, melee: bool = true) -> bool:
	var awe := Traits.mechanism(attacker, "first_contact_awe")
	if awe.is_empty() or not melee or attacker.get("action", {}).get("type", "") not in awe["actions"] or skill(defender, "名望") < float(awe["min_enemy_renown"]): return false
	var targets: Array = attacker.get("battle_contacts", [])
	var target := str(defender.get("officer_id", defender.get("id", "")))
	if target.is_empty() or target in targets: return false
	# Bounded so the persisted list cannot grow without limit over a long campaign.
	if targets.size() >= int(awe["contact_memory"]): targets.pop_front()
	targets.append(target)
	attacker["battle_contacts"] = targets
	defender["morale"] = maxf(0, float(defender.get("morale", 100)) - float(awe["morale"]))
	return true
