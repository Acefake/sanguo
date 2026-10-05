extends RefCounted

const Terrain = preload("res://scripts/war/battle_terrain.gd")
const Officer = preload("res://scripts/war/officer_battle.gd")
static func config(rules: Dictionary = {}) -> Dictionary:
	return rules.get("formations", Terrain.rules().get("formations", {}))
static func definitions(rules: Dictionary = {}) -> Dictionary:
	return config(rules).get("definitions", {})
static func name_of(id: String) -> String:
	return definitions().get(id, {}).get("name", "未设主阵")
static func proficiency(army: Dictionary, rules: Dictionary = {}) -> float:
	var settings := config(rules)
	var command: Dictionary = {"skills": {"布阵": army.get("formation_skill", army.get("skills", {}).get("布阵", 50))}}
	return clampf(float(settings.get("proficiency_base", 0.7)) + Officer.skill(command, "布阵") / float(settings.get("proficiency_divisor", 200)), 0.7, float(settings.get("proficiency_max", 1.25)))
static func entry(army: Dictionary, rules: Dictionary = {}) -> Dictionary:
	return definitions(rules).get(army.get("formation", "none"), {})
static func attack(army: Dictionary, ranged: bool = false, rules: Dictionary = {}) -> float:
	if army.get("formation_locked", false): return 0.0
	var data := entry(army, rules)
	var bonus := float(data.get("attack", 0)) + (float(data.get("ranged", 0)) if ranged else 0.0)
	if data.has("opening_attack"):
		bonus += float(data["opening_attack"] if int(army.get("formation_contact_days", 0)) <= int(data.get("opening_days", 2)) else data["sustained_attack"])
	return 1.0 + bonus * proficiency(army, rules)
static func received(army: Dictionary, terrain: String, ranged: bool = false, flanked: bool = false, rules: Dictionary = {}) -> float:
	if army.has("components"):
		var weighted := 0.0
		var total := 0.0
		for member in army["components"]:
			var count := 0.0
			for value in member.get("units",{}).values(): count += float(value)
			weighted += received(member,terrain,ranged,flanked,rules)*count
			total += count
		return weighted/maxf(total,1)
	var data := entry(army, rules)
	var factor := 1.0 + float(data.get("received_loss", 0)) * proficiency(army, rules)
	var defense := float(data.get("defense", 0)) + (0.0 if ranged else float(data.get("melee_defense", 0)))
	factor /= maxf(0.5, 1 + defense * proficiency(army, rules))
	if flanked: factor *= 1 + float(data.get("flanked_loss", 0)) * proficiency(army, rules)
	if terrain in ["forest", "mountains"]: factor *= 1 + float(data.get("rough_received", 0)) * proficiency(army, rules)
	return factor
static func flank(army: Dictionary, rules: Dictionary = {}) -> float:
	return 1.15 + float(entry(army, rules).get("flank_bonus", 0)) * proficiency(army, rules)
static func sync(war) -> void:
	for corps in war.state["corps"].values(): corps["formation_progress"] = "等待下一日整阵" if int(corps.get("formation_changed_at",-10)) > int(war.state["tick"]) else "整阵" if int(corps.get("formation_changed_at",-10)) == int(war.state["tick"]) else "完成"
	for army in war.active_armies():
		var corps: Dictionary = war.state["corps"].get(army.get("corps_id", ""), {})
		army["formation"] = corps.get("formation", "none")
		army["formation_skill"] = war.roster.officers.get(corps.get("commander_id", ""), {}).get("skills", {}).get("布阵", army.get("skills", {}).get("布阵", 50))
		army["formation_locked"] = int(corps.get("formation_changed_at", -10)) >= int(war.state["tick"])
		army["formation_contact_days"] = int(war.state["tick"]) - int(army.get("first_melee_tick", war.state["tick"])) + 1
static func can_change(war, corps: Dictionary, id: String) -> bool:
	var root: Dictionary = war.state["armies"].get(corps.get("root_id", ""), {})
	if root.is_empty() or corps.get("ended", false) or root.get("status", "ended") == "ended" or root.get("returning", false): return false
	if corps.get("autonomous_deployment",false) and not corps.get("deployed",false): return false
	return definitions(war.rules).has(id) and id != corps.get("formation", "none") and int(war.state["tick"]) - int(corps.get("formation_changed_at", -10)) >= int(config(war.rules).get("cooldown_days", 3)) and not corps.get("withdrawing", false)
static func set_initial(war, corps: Dictionary, id: String) -> void:
	corps["formation"] = id if definitions(war.rules).has(id) else "none"
	corps["formation_changed_at"] = -10
	sync(war)
static func change(war, corps: Dictionary, id: String, reason: String) -> Dictionary:
	if not can_change(war, corps, id): return {"ok": false, "message": "阵型无效、已在使用或三日变阵冷却未结束"}
	corps["formation"] = id
	corps["formation_changed_at"] = int(war.state["tick"])
	corps["formation_progress"] = "整阵"
	for unit_id in corps["units"]:
		var unit: Dictionary = war.state["armies"][unit_id]
		if unit["status"] == "ended": continue
		unit["organization"] = maxf(0, float(unit["organization"]) - float(config(war.rules)["change_organization"]))
		var in_contact: bool = unit.has("tactical") and war.Tactical.contact_state(war, unit)["adjacent_enemies"] > 0
		if not unit.has("tactical"):
			for enemy in war.active_armies():
				if enemy["faction"] != unit["faction"] and war._contact(unit,enemy,{}): in_contact = true; break
		if in_contact:
			unit["morale"] = maxf(0, float(unit["morale"]) - float(config(war.rules)["contact_morale_cost"]))
	sync(war)
	war._report(war.state["armies"][corps["root_id"]], "变阵", "全军改用%s，整阵一日，停止攻击与移动。%s" % [name_of(id), reason], false)
	return {"ok": true}
