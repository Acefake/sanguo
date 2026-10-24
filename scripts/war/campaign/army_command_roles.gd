extends RefCounted

# Presentation roles reuse existing deployed corps members; no new personnel or AI authority.
static func enabled(war, army: Dictionary) -> bool:
	return bool(war.rules.get("command_roles", {}).get("enabled", true)) and bool(army.get("command_roles", {}).get("enabled", true))

static func _unavailable(war, id: String) -> bool:
	var state: Dictionary = war.state.get("officer_states", {}).get(id, {})
	var fate: Dictionary = war.state.get("officer_fates", {}).get(id, {})
	return state.get("lost", false) or state.get("duel_wounded", false) or state.get("status", "") in ["dead", "captured", "recovering", "wounded"] or fate.get("status", "") in ["dead", "captured", "recovering", "wounded"]

static func _card(war, army: Dictionary, id: String, can_command: bool) -> Dictionary:
	var officer: Dictionary = war.roster.officers.get(id, {})
	if id.is_empty() or officer.is_empty() or _unavailable(war, id): return {}
	if str(officer.get("faction", "")) != str(army.get("faction", "")): return {}
	var skills: Dictionary = officer.get("skills", {}).duplicate(true)
	var stats: Dictionary = {}
	var raw_stats = officer.get("stats", [])
	if raw_stats is Dictionary: stats = raw_stats.duplicate(true)
	elif raw_stats is Array:
		var dimensions := ["军事", "谋略", "勇武", "政治", "魅力"]
		for index in mini(raw_stats.size(), dimensions.size()): stats[dimensions[index]] = raw_stats[index]
	for key in ["军事", "谋略", "勇武", "政治", "魅力"]:
		if not stats.has(key) and skills.has(key): stats[key] = skills[key]
	return {"id": id, "name": str(officer.get("name", id)), "stats": stats, "skills": skills, "can_command": can_command}

static func deputy_reason(war, army: Dictionary, id: String) -> String:
	if id.is_empty(): return ""
	if not enabled(war, army): return "roles_disabled"
	if army.get("status", "") == "ended": return "army_ended"
	if not war.roster.officers.has(id): return "unknown_officer"
	if id == str(army.get("officer_id", "")): return "same_as_commander"
	if _unavailable(war, id): return "officer_unavailable"
	if str(war.roster.officers[id].get("faction", "")) != str(army.get("faction", "")): return "different_faction"
	for other in war.state.get("armies", {}).values():
		if other.get("status", "ended") == "ended": continue
		if str(other.get("officer_id", "")) == id: return "independent_command"
		if str(other.get("id", "")) != str(army.get("id", "")) and str(other.get("command_roles", {}).get("deputy_id", "")) == id: return "already_assigned"
	var corps_id := str(army.get("corps_id", ""))
	var corps: Dictionary = war.state.get("corps", {}).get(corps_id, {})
	var officer_state: Dictionary = war.state.get("officer_states", {}).get(id, {})
	# Only people already accompanying this force are eligible. Available officers
	# need a deployment/return lifecycle before independent armies can appoint them.
	if corps_id.is_empty() or not corps.get("members", []).has(id): return "not_accompanying"
	if officer_state.get("status", "") != "deployed" or str(officer_state.get("corps_id", "")) != corps_id or str(officer_state.get("army_id", "")) != str(army.get("id", "")): return "not_accompanying"
	return ""

static func resolve(war, army: Dictionary) -> Dictionary:
	var result := {"enabled": enabled(war, army), "commander": {}, "deputy": {}}
	if not result["enabled"] or army.get("status", "") == "ended": return result
	result["commander"] = _card(war, army, str(army.get("officer_id", "")), true)
	var deputy_id := str(army.get("command_roles", {}).get("deputy_id", ""))
	if not deputy_id.is_empty() and deputy_reason(war, army, deputy_id).is_empty(): result["deputy"] = _card(war, army, deputy_id, false)
	return result

static func set_deputy(war, army: Dictionary, id: String) -> Dictionary:
	var reason := deputy_reason(war, army, id)
	if not reason.is_empty(): return {"ok": false, "reason": reason}
	if not army.has("command_roles"): army["command_roles"] = {}
	army["command_roles"]["deputy_id"] = id
	return {"ok": true, "reason": ""}

static func role_text(role: Dictionary, title: String) -> String:
	if role.is_empty(): return title + "  未配置或不可用"
	var attributes: Array[String] = []
	for key in ["军事", "谋略", "勇武", "政治", "魅力"]:
		if role["stats"].has(key): attributes.append("%s%d" % [key, int(role["stats"][key])])
	var ranked: Array = role["skills"].keys()
	ranked.sort_custom(func(a, b): return float(role["skills"][a]) > float(role["skills"][b]))
	var skills: Array[String] = []
	for key in ranked.slice(0, 2): skills.append("%s%d" % [key, int(role["skills"][key])])
	return "%s  %s\n%s\n技能 %s" % [title, role["name"], "  ".join(attributes), "  ".join(skills) if not skills.is_empty() else "无"]


