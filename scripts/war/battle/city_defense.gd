class_name CityDefense
extends RefCounted
## 城防设施与驻军分离：城外仅损伤设施，破口入城后才结算驻军伤亡。

const Combat = preload("res://scripts/war/battle/combat_system.gd")
const Fort = preload("res://scripts/war/battle/city_fortifications.gd")
const Roles = preload("res://scripts/war/battle/troop_roles.gd")
const Process = preload("res://scripts/officers/officer_process.gd")
const Keys = preload("res://scripts/war/campaign/war_state_keys.gd")
const FACILITIES := ["wall", "wall_max", "gate", "gate_max"]

static func create(war, node: String, army: Dictionary) -> Dictionary:
	var city: Dictionary = war.store.city_state(node)
	var wall := maxf(0.0, float(city.get("defense", 0)) * 4.0)
	var siege := {"city": node, "attacker": army["faction"], "started": int(war.state[Keys.TICK]), "last_tick": -1, "wall_max": wall, "wall": wall, "gate_max": wall * 0.5, "gate": wall * 0.5, "preparation": float(army.get("siege_progress", 0)), "morale": 100.0, "organization": 100.0, "phase": "准备", "mode": "assault", "losses": 0, "defender_losses": 0}
	for key in FACILITIES:
		if city.has("fort_" + key): siege[key] = city["fort_" + key]
	migrate(war, node, siege)
	return siege

static func migrate(_war, _node: String, siege: Dictionary) -> void:
	# 旧档只有城墙；保留原耐久及既有破口，不重置战役进度。
	if not siege.has("gate_max"): siege["gate_max"] = maxf(0.0, float(siege.get("wall_max", 0)) * 0.5)
	if not siege.has("gate"): siege["gate"] = siege["gate_max"]
	if not siege.has("breach_open"):
		siege["breach_open"] = int(siege.get("breach_cell", -1)) >= 0 or float(siege.get("wall", 1)) <= 0 or float(siege["gate"]) <= 0
	siege["gate_breached"] = float(siege["gate"]) <= 0

static func persist(war, node: String, siege: Dictionary) -> void:
	migrate(war, node, siege)
	var city: Dictionary = war.store.city_state(node)
	for key in FACILITIES: city["fort_" + key] = siege[key]

static func repair(war, node: String, amount: float) -> void:
	if amount <= 0: return
	var city: Dictionary = war.store.city_state(node)
	var siege: Dictionary = war.state.get(Keys.SIEGES, {}).get(node, {})
	if siege.is_empty():
		# 未遭围城的旧档随内政城防值初始化；已有设施损伤则逐步修缮。
		if not city.has("fort_wall"): return
		for key in ["wall", "gate"]:
			var scale := 4.0 if key == "wall" else 2.0
			var capacity := maxf(float(city.get("fort_" + key + "_max", 0)), float(city.get("defense", 0)) * scale)
			city["fort_" + key + "_max"] = capacity
			city["fort_" + key] = minf(capacity, float(city.get("fort_" + key, 0)) + amount * scale)
		return
	migrate(war, node, siege)
	for key in ["wall", "gate"]:
		var scale := 4.0 if key == "wall" else 2.0
		siege[key + "_max"] = maxf(float(siege[key + "_max"]), float(city.get("defense", 0)) * scale)
		siege[key] = minf(float(siege[key + "_max"]), float(siege[key]) + amount * scale)
	if float(siege["wall"]) > 0 and float(siege["gate"]) > 0:
		siege["breach_open"] = false
		siege["gate_breached"] = false
		siege.erase("breach_cell")
	persist(war, node, siege)

static func breach_open(war, node: String) -> bool:
	var siege: Dictionary = war.state.get(Keys.SIEGES, {}).get(node, {})
	if siege.is_empty(): return false
	migrate(war, node, siege)
	return bool(siege["breach_open"])

static func breach_cell(war, node: String) -> int:
	if not breach_open(war, node): return -1
	var siege: Dictionary = war.state[Keys.SIEGES][node]
	if int(siege.get("breach_cell", -1)) < 0: Fort.breach(war, node, [])
	return int(siege.get("breach_cell", -1))

static func inside_attackers(war, node: String, board: Dictionary) -> Array:
	var result: Array = []
	var faction := str(war.store.city_state(node).get("faction", ""))
	for army in war.active_armies():
		if army.get("returning", false) or army.get("status", "") == "ended": continue
		if army.has("tactical") and war.hostile(str(army["faction"]), faction) and Fort.inside_city(board, int(army["tactical"]["cell"])) == node:
			result.append(army)
	return result

static func facility_power(_war, group: Array) -> Dictionary:
	var infantry := 0
	var engines := 0
	var total := 0.0
	for army in group:
		if army.get("returning", false) or army.get("status", "") == "ended" or not Roles.can_breach(army): continue
		var soldiers := maxi(0, int(army.get("units", {}).get("infantry", 0)))
		infantry += soldiers
		engines += Roles.engine_count(army)
		total += soldiers * Process.engineering_rate(army)
	return {"infantry": infantry, "engines": engines, "total": total * (1.0 + minf(0.6, engines * 0.15))}

static func damage_facilities(war, node: String, siege: Dictionary, group: Array) -> Dictionary:
	var was_open := breach_open(war, node)
	var power := facility_power(war, group)
	if float(power["total"]) > 0:
		var damage := clampf(float(power["total"]) / 800.0, 2.0, 30.0)
		siege["wall"] = maxf(0.0, float(siege["wall"]) - damage)
		siege["gate"] = maxf(0.0, float(siege["gate"]) - damage)
	if float(siege["wall"]) <= 0 or float(siege["gate"]) <= 0:
		siege["breach_open"] = true
		siege["gate_breached"] = float(siege["gate"]) <= 0
		if not was_open: Fort.breach(war, node, group)
	persist(war, node, siege)
	return {"new_breach": not was_open and bool(siege.get("breach_open", false))}

static func interior_exchange(war, node: String, _siege: Dictionary, entered: Array, defender: Dictionary, terrain: String) -> Dictionary:
	var empty := {"defender_loss": 0, "attacker_loss": 0, "attacker_personal": 0.0, "defender_personal": 0.0}
	if not breach_open(war, node) or entered.is_empty(): return empty
	var force := Combat.aggregate(entered)
	var attack := Combat.losses_detail(force, defender, war.rules, terrain, 0.55)
	var defense := Combat.losses_detail(defender, force, war.rules, terrain, 0.65)
	return {"defender_loss": int(attack["loss"]), "attacker_loss": int(defense["loss"]), "attacker_personal": float(attack.get("personal_fraction", 0)), "defender_personal": float(defense.get("personal_fraction", 0))}

static func occupation_state(war, node: String, siege: Dictionary, inside: Array, city: Dictionary, _strength: int) -> Dictionary:
	if not breach_open(war, node) or inside.is_empty(): return {"ok": false, "reason": "尚未破城入城"}
	var strength := Combat.strength(Combat.aggregate(inside))
	var defenders := int(city.get("garrison", 0))
	var defeated := defenders <= 0 or ((float(siege["morale"]) <= 15.0 or float(siege["organization"]) <= 10.0) and strength > defenders)
	return {"ok": defeated and strength > 0, "reason": "守军溃败，入城占领" if defeated else "守军仍在抵抗"}
