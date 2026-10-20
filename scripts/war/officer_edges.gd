extends RefCounted

# Rule-generated officer specialties (将领专长). Every officer gets at most one
# edge, scored from the same skills and 14 personality axes used elsewhere.
# Triggers are deterministic and never consume the battle RNG.

const Process = preload("res://scripts/officers/officer_process.gd")
const Traits = preload("res://scripts/officers/trait_registry.gd")
const GridScript = preload("res://scripts/rtk14_hex_grid.gd")
const PATH := "res://data/war/officer_edges.json"

static var _data: Dictionary = {}


static func data() -> Dictionary:
	if _data.is_empty():
		var file := FileAccess.open(PATH, FileAccess.READ)
		var parsed: Variant = null if file == null else JSON.parse_string(file.get_as_text())
		_data = parsed if parsed is Dictionary else {"threshold": 65, "edges": {}}
	return _data


static func blank() -> Dictionary:
	return {"id": "", "uses": 0, "cooldown_until": 0, "active_until": 0}


static func score_of(officer: Dictionary, edge: Dictionary) -> float:
	var value := 0.0
	var weight := 0.0
	var entry: Dictionary = edge.get("score", {})
	for name in entry.get("skills", {}):
		var w := float(entry["skills"][name])
		value += Process.value(officer, name) * w
		weight += w
	for name in entry.get("personality", {}):
		var w := float(entry["personality"][name])
		value += float(officer.get("personality", {}).get(name, 50)) * w
		weight += w
	return value / maxf(weight, 0.001)


static func generate_id(officer: Dictionary) -> String:
	var best := ""
	var best_score := float(data().get("threshold", 65))
	for id in data().get("edges", {}):
		var value := score_of(officer, data()["edges"][id])
		if value > best_score:
			best_score = value
			best = str(id)
	return best


static func ensure(army: Dictionary, officer: Dictionary, reset: bool = false) -> Dictionary:
	var edge: Dictionary = army.get("edge") if army.get("edge") is Dictionary else blank()
	var generated := generate_id(officer)
	if reset or str(edge.get("id", "")) != generated:
		edge = blank()
		edge["id"] = generated
	for key in ["uses", "cooldown_until", "active_until"]:
		edge[key] = int(edge.get(key, 0))
	return edge


# Runs once per day on the strategic map, not only inside a hex battlefield, so a
# multiplier earned in the hex cannot survive the hex and apply forever on the road.
static func day_start(war) -> void:
	var tick := int(war.state["tick"])
	for army in war.active_armies():
		army.erase("edge_attack")
		army.erase("edge_defense")
		army.erase("edge_active")
		# Opening shocks are earned and spent inside one exchange; a leftover marker
		# would silently buff a later, unrelated battle.
		army.erase("incoming_shock")
		army.erase("morale_shock")
		if not army.has("tactical"): continue
		if bool(army["returning"]) or str(army["status"]) == "ended": continue
		var edge: Dictionary = army.get("edge", {})
		var id := str(edge.get("id", ""))
		if id == "" or int(edge.get("cooldown_until", 0)) > tick: continue
		var config: Dictionary = data().get("edges", {}).get(id, {})
		if config.is_empty(): continue
		var effect := _effect_for(war, army, id, config)
		if effect.is_empty(): continue
		_apply(war, army, id, config, effect)


static func _effect_for(war, army: Dictionary, id: String, config: Dictionary) -> Dictionary:
	var edge: Dictionary = army.get("edge", {})
	var effect: Dictionary = config.get("effect", {})
	match str(config.get("trigger", "")):
		"morale_below_40":
			if bool(config.get("once", false)) and int(edge.get("uses", 0)) > 0: return {}
			if float(army.get("morale", 100)) >= 40.0: return {}
			return {"morale": float(effect.get("morale", 10))}
		"prev_day_advantage":
			if int(army.get("edge_advantage_tick", -1)) != int(war.state["tick"]) - 1: return {}
			return {"attack_mult": float(effect.get("attack_mult", 1.1))}
		"ally_retreating_adjacent":
			var corps: Dictionary = war.state["corps"].get(army.get("corps_id", ""), {})
			for unit_id in corps.get("units", []):
				var friend: Dictionary = war.state["armies"][unit_id]
				if friend["id"] == army["id"] or friend["status"] == "ended" or not friend.has("tactical"): continue
				if bool(friend["returning"]) and _distance(army, friend) <= 1:
					return {"received_mult": float(effect.get("received_mult", 0.8))}
			return {}
		"ally_low_organization":
			var corps2: Dictionary = war.state["corps"].get(army.get("corps_id", ""), {})
			var target := ""
			var lowest := 100.0
			for unit_id in corps2.get("units", []):
				var friend: Dictionary = war.state["armies"][unit_id]
				if friend["id"] == army["id"] or friend["status"] == "ended" or not friend.has("tactical"): continue
				if float(friend.get("organization", 100)) >= 40.0: continue
				if _distance(army, friend) > 3: continue
				if float(friend["organization"]) <= lowest:
					lowest = float(friend["organization"])
					target = str(friend["id"])
			if target == "": return {}
			return {"organization": float(effect.get("organization", 5)), "target": target}
		# These two are resolved inside attack_mult() at strike time, not at day start,
		# because they depend on the specific target rather than on the unit's own state.
		"enemy_unobserved_in_range", "first_frontal_contact":
			return {}
		_:
			return {}


static func _distance(a: Dictionary, b: Dictionary) -> int:
	var cell_a := int(a.get("tactical", {}).get("cell", -1))
	var cell_b := int(b.get("tactical", {}).get("cell", -1))
	if cell_a < 0 or cell_b < 0: return 99
	return GridScript.shared().distance(cell_a, cell_b)


static func _apply(war, army: Dictionary, id: String, config: Dictionary, effect: Dictionary) -> void:
	var edge: Dictionary = army["edge"]
	var tick := int(war.state["tick"])
	if effect.has("morale"):
		army["morale"] = minf(100.0, float(army["morale"]) + float(effect["morale"]))
	if effect.has("attack_mult"):
		army["edge_attack"] = float(effect["attack_mult"])
		army["edge_active"] = id
		edge["cooldown_until"] = tick + int(config.get("cooldown", 0))
	if effect.has("received_mult"):
		army["edge_defense"] = float(effect["received_mult"])
		army["edge_active"] = id
		edge["cooldown_until"] = tick + int(config.get("cooldown", 0))
	if effect.has("organization"):
		var target: Dictionary = war.state["armies"].get(str(effect.get("target", "")), {})
		if not target.is_empty():
			target["organization"] = minf(100.0, float(target["organization"]) + float(effect["organization"]))
			army["edge_active"] = id
			edge["cooldown_until"] = tick + int(config.get("cooldown", 0))
	if bool(config.get("once", false)): edge["uses"] = int(edge.get("uses", 0)) + 1
	var detail := "军心重新振作"
	if effect.has("attack_mult"): detail = "攻击提高一成"
	elif effect.has("received_mult"): detail = "掩护撤退友军，伤亡减轻"
	elif effect.has("organization"): detail = "友军重新整队"
	war._report(army, "专长", "%s发动专长  %s（%s）。" % [army["name"], str(config.get("name", id)), detail], false)


static func attack_mult(war, attacker: Dictionary, defender: Dictionary, melee: bool) -> float:
	var edge: Dictionary = attacker.get("edge", {})
	var id := str(edge.get("id", ""))
	if id == "" or int(edge.get("cooldown_until", 0)) > int(war.state["tick"]): return 1.0
	if id == "ambush" and int(edge.get("uses", 0)) == 0:
		# The target must still be unaware of this unit for the ambush to land.
		if defender.get("intel", {}).get("enemies", {}).has(str(attacker["id"])): return 1.0
		edge["uses"] = int(edge.get("uses", 0)) + 1
		attacker["edge_active"] = id
		war._report(attacker, "专长", "%s发动专长  设伏，首轮攻击提高。" % attacker["name"], false)
		return float(data().get("edges", {}).get(id, {}).get("effect", {}).get("first_attack_mult", 1.2))
	if id == "awe" and melee and int(edge.get("uses", 0)) == 0 and Traits.mechanism(attacker, "first_contact_awe").is_empty():
		edge["uses"] = int(edge.get("uses", 0)) + 1
		attacker["edge_active"] = id
		defender["morale"] = maxf(0.0, float(defender["morale"]) + float(data().get("edges", {}).get(id, {}).get("effect", {}).get("enemy_morale", -6)))
		war._report(attacker, "专长", "%s发动专长  立威，敌%s士气受挫。" % [attacker["name"], defender["name"]], false)
	return 1.0
