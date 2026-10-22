class_name OfficerFate
extends RefCounted
## 武将去向：阵亡、被俘、溃散、归还与释放，个人与守城战功记录，城破后的处置。

const Combat = preload("res://scripts/war/battle/combat_system.gd")

static func unavailable(war, id: String) -> bool:
	return war.state.get("officer_fates", {}).get(id, {}).get("status", "") in ["dead", "captured"]

static func credit_personal(war, army: Dictionary, officer: String, count: int, soldiers: bool = true) -> void:
	if count <= 0: return
	war.state["officer_personal_kills"][officer] = int(war.state["officer_personal_kills"].get(officer, 0)) + count
	if soldiers:
		army["personal_soldier_kills"] = int(army.get("personal_soldier_kills", 0)) + count
		war.state["officer_personal_soldiers"][officer] = int(war.state["officer_personal_soldiers"].get(officer, 0)) + count

static func personal_weights(armies: Array, weights: Dictionary, fraction: float, config: Dictionary) -> Dictionary:
	var result := {}
	var sum := 0.0
	var damage := 0.0
	for army in armies: sum += Combat.personal_power(army, config)
	for value in weights.values(): damage += float(value)
	for army in armies: result[army["id"]] = damage * fraction * Combat.personal_power(army, config) / maxf(sum, 0.001)
	return result

static func credit(war, weights: Dictionary, deaths: int, commanders: Dictionary = {}, personal: Dictionary = {}) -> void:
	# Allocate actual deaths once, using largest remainders; injuries are excluded.
	var total := 0.0
	for value in weights.values(): total += maxf(0, float(value))
	if total <= 0 or deaths <= 0: return
	var rows: Array = []
	var assigned := 0
	for id in weights:
		var exact := deaths * maxf(0, float(weights[id])) / total
		var count := int(floor(exact))
		assigned += count
		rows.append({"id": str(id), "count": count, "fraction": exact - count})
	rows.sort_custom(func(a, b): return a["fraction"] > b["fraction"] if not is_equal_approx(a["fraction"], b["fraction"]) else a["id"] < b["id"])
	for i in range(deaths - assigned): rows[i]["count"] += 1
	if not war.state.has("officer_kills"): war.state["officer_kills"] = {}
	for row in rows:
		var army: Dictionary = war.state["armies"].get(row["id"], {})
		if army.is_empty(): continue
		army["enemy_killed"] = int(army.get("enemy_killed", 0)) + row["count"]
		var officer: String = str(commanders.get(row["id"], army["officer_id"]))
		war.state["officer_kills"][officer] = int(war.state["officer_kills"].get(officer, 0)) + row["count"]
		var personal_count := clampi(roundi(row["count"] * float(personal.get(row["id"], 0)) / maxf(float(weights[row["id"]]), 0.001)), 0, row["count"])
		credit_personal(war, army, officer, personal_count)

static func settle(war, army: Dictionary, enemy: Dictionary, status: String, cause: String) -> Dictionary:
	var id: String = str(army["officer_id"])
	if unavailable(war, id): return war.state["officer_fates"][id]
	if not war.state.has("officer_fates"): war.state["officer_fates"] = {}
	var name: String = str(war.roster.officers.get(id, {}).get("name", army["name"]))
	var record := {"officer_id": id, "name": name, "faction": army["faction"], "status": status, "tick": int(war.state["tick"]), "cause": cause, "captor_id": enemy.get("officer_id", ""), "captor_faction": enemy.get("faction", ""), "army_id": army["id"]}
	war.state["officer_fates"][id] = record
	if status == "dead" and cause == "单挑落败" and not enemy.is_empty(): credit_personal(war, enemy, str(enemy["officer_id"]), 1, false)
	war.state["officer_states"][id] = record.duplicate(true)
	war.state["officer_states"][id]["lost"] = true
	army["commander_fate"] = record.duplicate(true)
	var message := "%s%s（%s）" % [name, "战死" if status == "dead" else "被俘", cause]
	war._report(army, "武将战死" if status == "dead" else "武将被俘", message, true)
	if war.state["armies"].has(enemy.get("id", "")): war._report(enemy, "斩获", message, true)
	var corps: Dictionary = war.state["corps"].get(army.get("corps_id", ""), {})
	if not corps.is_empty(): corps["members"].erase(id)
	var busy: Array = war.active_armies().map(func(unit): return unit["officer_id"])
	var candidates: Array = corps.get("members", []).filter(func(member): return not busy.has(member) and not unavailable(war, member) and not war.state["officer_states"].get(member, {}).get("duel_wounded", false))
	if not candidates.is_empty():
		var successor: String = str(candidates[0])
		army["officer_id"] = successor
		army["name"] = str(war.roster.officers[successor]["name"]) + "队"
		army["skills"] = war.roster.officers[successor].get("skills", {}).duplicate(true)
		army["trait_ids"] = war.roster.officers[successor].get("trait_ids", []).duplicate()
		army["edge"] = war.Edges.ensure(army, war.roster.officers[successor], true)
		army["duel_wounded"] = false
		# A new commander has met nobody: inheriting the predecessor's contact list
		# suppressed their own first-contact effect against officers already seen.
		army["battle_contacts"] = []
		army.erase("opening_used")
		war.state["officer_states"][successor] = {"status": "deployed", "army_id": army["id"], "corps_id": corps.get("id", "")}
		if corps.get("commander_id", "") == id:
			corps["commander_id"] = successor
			corps["appointments"][successor] = "代理主帅"
		corps["last_plan"] = -10
		war._report(army, "主将接替", "%s接掌余部，继续执行军令。" % war.roster.officers[successor]["name"], true)
	else:
		army["commander_unavailable"] = true
		disperse(war, army)
	army.erase("pending_request")
	army.erase("approved_action")
	war.planner.clear()
	return record

static func disperse(war, army: Dictionary) -> void:
	if army.get("status", "") == "ended": return
	var count := Combat.strength(army) + int(army.get("wounded", 0))
	army["dispersed"] = int(army.get("dispersed", 0)) + count
	army["units"] = {"infantry": 0, "archers": 0, "cavalry": 0}
	army["wounded"] = 0
	army["wounded_units"] = {"infantry": 0, "archers": 0, "cavalry": 0}
	army["siege_engines"] = 0
	army["morale"] = 0.0
	army["organization"] = 0.0
	army["returning"] = true
	army["victory_chain"] = false
	war.state["battle_victories"].erase(str(army["officer_id"]))
	army["action"] = {"type": "hold"}
	army["last_reason"] = "随军武将尽失，无人接掌，士兵溃散"
	war._report(army, "溃败", "%s无人接掌，剩余%d人溃散，退出战斗。" % [army["name"], count], true)
	war._finish(army, "失去指挥溃散")

static func encounter(war, army: Dictionary, enemy: Dictionary, cause: String, severity: float) -> Dictionary:
	if army.get("commander_unavailable", false) or unavailable(war, str(army["officer_id"])) or enemy.is_empty(): return {}
	var rules: Dictionary = war.rules.get("officer_fate", {})
	var death := float(rules.get(cause + "_death", 0.02)) * clampf(severity, 0, 1)
	if cause == "duel" and not war.rules.get("duel", {}).get("allow_death", true): death = 0.0
	var capture := float(rules.get(cause + "_capture", 0.1)) * clampf(severity, 0, 1)
	if cause != "duel" and (Combat.strength(enemy) <= 0 or enemy.get("commander_unavailable", false)): capture = 0.0
	var roll: float = war.rng.randf()
	if roll < death: return settle(war, army, enemy, "dead", "单挑落败" if cause == "duel" else "部队覆没" if cause == "destroyed" else "溃败遭截")
	if roll < death + capture: return settle(war, army, enemy, "captured", "单挑落败" if cause == "duel" else "部队覆没" if cause == "destroyed" else "溃败遭截")
	return {}

static func restore(war) -> void:
	# Terminal fates survive return, merge, staff release and old save migration.
	for id in war.state.get("officer_fates", {}):
		var fate: Dictionary = war.state["officer_fates"][id]
		if fate.get("status", "") in ["dead", "captured"]:
			war.state["officer_states"][id] = fate.duplicate(true)
			war.state["officer_states"][id]["lost"] = true

static func release(war, id: String) -> bool:
	if war.campaign_finished() or war.store.busy: return false
	var fate: Dictionary = war.state.get("officer_fates", {}).get(id, {})
	if fate.get("status", "") != "captured" or fate.get("captor_faction", "") != war.state["player_faction"]: return false
	fate["status"] = "released"
	fate["released_at"] = int(war.state["tick"])
	war.state["officer_states"][id] = {"status": "recovering", "available_after": int(war.state["tick"]) + 10}
	return true

static func garrison(war, node: String, city: Dictionary) -> Dictionary:
	var guards: Dictionary = war.state["garrison_commanders"]
	var guard: Dictionary = guards.get(node, {})
	if not guard.is_empty() and guard["faction"] == city["faction"] and not unavailable(war, guard["officer_id"]) and war.state["officer_states"].get(guard["officer_id"], {}).get("status", "available") in ["available", "guarding"]:
		war.state["officer_states"][guard["officer_id"]] = {"status": "guarding", "city": node}
		return guard
	var available: Array = war.available_officers(str(city["faction"]))
	if war.state.get("campaign_started", false): available = available.filter(func(officer): return war.state["officer_states"].get(officer["id"], {}).get("city", node) == node and city.get("governor_id", "") != officer["id"])
	available.sort_custom(func(a, b): return float(a["skills"].get("带兵", 50)) > float(b["skills"].get("带兵", 50)))
	var id: String = str(available[0]["id"]) if not available.is_empty() else war.roster.militia(str(city["faction"]), node)
	if unavailable(war, id): id = war.roster.militia(str(city["faction"]), node + ":" + str(war.state["tick"]))
	guard = {"officer_id": id, "name": war.roster.officers[id]["name"], "faction": city["faction"], "enemy_killed": 0, "city": node}
	guards[node] = guard
	war.state["officer_states"][id] = {"status": "guarding", "city": node}
	return guard

static func credit_garrison(war, guard: Dictionary, deaths: int, personal_fraction: float = 0.0) -> void:
	guard["enemy_killed"] = int(guard.get("enemy_killed", 0)) + deaths
	war.state["officer_kills"][guard["officer_id"]] = int(war.state["officer_kills"].get(guard["officer_id"], 0)) + deaths
	credit_personal(war, guard, str(guard["officer_id"]), clampi(roundi(deaths * personal_fraction), 0, deaths))

static func city_falls(war, guard: Dictionary, winner: Dictionary) -> void:
	var id: String = str(guard["officer_id"])
	if unavailable(war, id): return
	var roll: float = war.rng.randf()
	var rules: Dictionary = war.rules.get("officer_fate", {})
	var death := float(rules.get("city_death", 0.15))
	var capture := float(rules.get("city_capture", 0.55))
	if roll >= death + capture:
		war.state["officer_states"][id] = {"status": "recovering", "available_after": int(war.state["tick"]) + 10}
		return
	var status := "dead" if roll < death else "captured"
	war.state["officer_fates"][id] = {"officer_id": id, "name": guard["name"], "faction": guard["faction"], "status": status, "tick": int(war.state["tick"]), "cause": "城破失守", "captor_id": winner["officer_id"], "captor_faction": winner["faction"], "city": guard["city"]}
	restore(war)
	war._report(winner, "武将战死" if status == "dead" else "武将被俘", "守城主将%s%s。" % [guard["name"], "战死" if status == "dead" else "被俘"], true)
