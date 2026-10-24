extends RefCounted

# 城防设施与城内驻军的唯一权威模块。
#
# 职责分离：
# - 设施（城墙 / 城门）拥有独立耐久，只吃步兵与攻城器械的伤害；
# - 驻军仅在破口开放、攻方部队真正进入城防范围后承受巷战攻击；
#   非战术地图在破城后以入城阶段结算，缺失几何不能绕过设施耐久。
#   未破城时，任何外部攻击都不能伤到驻军。
#
# 通道规则：城门或城墙至少一处耐久归零后，`breach_open` 置位，
# `breach_cell` 使用既有 site.gate / site.cells 定义（不虚构几何）。
# 骑兵不能破墙门；破口开放后骑兵可以经破口入城。
#
# 旧存档兼容：旧档只有 wall / breach_cell，migrate() 在读取时补齐
# gate/gate_max/breach_open/wall_breached/gate_breached，且不改变既有数值语义。

const Fort = preload("res://scripts/war/battle/city_fortifications.gd")
const Combat = preload("res://scripts/war/battle/combat_system.gd")
const Battle = preload("res://scripts/war/battle/officer_battle.gd")
const Roles = preload("res://scripts/war/battle/troop_roles.gd")

const GATE_SHARE := 0.30
const WALL_INFANTRY_DIVISOR := 800.0
const WALL_DAMAGE_MIN := 2.0
const WALL_DAMAGE_MAX := 30.0
const GATE_ENGINE_DAMAGE := 4.0
const GATE_DAMAGE_MIN := 2.0
const GATE_DAMAGE_MAX := 24.0


static func create(war, node: String, army: Dictionary) -> Dictionary:
	var city: Dictionary = war.store.city_state(node)
	var wall: float = maxf(0.0, float(city.get("defense", 0)) * 4)
	var siege := {
		"city": node, "attacker": army["faction"], "started": int(war.state["tick"]),
		"last_tick": -1, "wall_max": wall, "wall": wall,
		"gate_max": maxf(0.0, float(roundi(wall * GATE_SHARE))), "gate": 0.0,
		"preparation": float(army.get("siege_progress", 0)), "morale": 100.0,
		"organization": 100.0, "phase": "准备", "mode": "assault",
		"losses": 0, "defender_losses": 0,
		"breach_open": false, "breach_cell": -1,
		"wall_breached": false, "gate_breached": false,
	}
	siege["gate"] = siege["gate_max"]
	# 城防损伤属于城市，不随攻方身份或一次围城记录重置。
	var stored: Dictionary = city.get("fortifications", {})
	for field in facility_fields():
		if stored.has(field): siege[field] = stored[field]
	if wall <= 0.0:
		# 无墙城防：城防数值为零时按既有 site.gate 直接视为已破，不另造几何。
		siege["wall_breached"] = true
		siege["breach_open"] = true
		var site := Fort.for_city(war.store, node)
		siege["breach_cell"] = int(site["gate"]) if not site.is_empty() else -1
	return siege

static func facility_fields() -> Array:
	return ["wall", "wall_max", "gate", "gate_max", "breach_open", "breach_cell", "wall_breached", "gate_breached"]

static func persist(war, node: String, siege: Dictionary) -> void:
	var value := {}
	for field in facility_fields():
		if siege.has(field): value[field] = siege[field]
	war.store.city_state(node)["fortifications"] = value

static func repair(war, node: String, amount: float) -> void:
	var city: Dictionary = war.store.city_state(node)
	var siege: Dictionary = war.state.get("sieges", {}).get(node, {})
	if siege.is_empty():
		var stored: Dictionary = city.get("fortifications", {})
		if stored.is_empty(): return
		siege = stored.duplicate(true)
	var capacity := maxf(0.0, float(city.get("defense", 0)) * 4.0)
	siege["wall_max"] = maxf(capacity, float(siege.get("wall_max", capacity)))
	siege["gate_max"] = maxf(float(roundi(capacity * GATE_SHARE)), float(siege.get("gate_max", 0.0)))
	siege["wall"] = minf(float(siege["wall_max"]), float(siege.get("wall", 0.0)) + maxf(0.0, amount))
	siege["gate"] = minf(float(siege["gate_max"]), float(siege.get("gate", 0.0)) + maxf(0.0, amount) * GATE_SHARE)
	siege["wall_breached"] = float(siege["wall"]) <= 0.0
	siege["gate_breached"] = float(siege["gate"]) <= 0.0
	siege["breach_open"] = bool(siege["wall_breached"]) or bool(siege["gate_breached"])
	if not siege["breach_open"]: siege["breach_cell"] = -1
	persist(war, node, siege)


static func migrate(war, node: String, siege: Dictionary) -> void:
	if siege.is_empty(): return
	var wall_max := maxf(float(siege.get("wall_max", 0.0)), float(siege.get("wall", 0.0)))
	if not siege.has("gate_max"): siege["gate_max"] = maxf(0.0, float(roundi(wall_max * GATE_SHARE)))
	if not siege.has("gate"): siege["gate"] = float(siege["gate_max"])
	siege["wall"] = clampf(float(siege.get("wall", wall_max)), 0.0, wall_max)
	siege["gate"] = clampf(float(siege.get("gate", 0.0)), 0.0, float(siege["gate_max"]))
	if not siege.has("wall_breached"): siege["wall_breached"] = float(siege["wall"]) <= 0.0
	if not siege.has("gate_breached"): siege["gate_breached"] = false
	# 旧档可能用 wall<=0 或 breach_cell 表达破城；两种痕迹都视为通道已开，
	# 缺口位置优先沿用既有记录，缺失时退回既有 site.gate。
	var legacy_open: bool = float(siege["wall"]) <= 0.0 or int(siege.get("breach_cell", -1)) >= 0
	if bool(siege.get("breach_open", false)) or legacy_open:
		siege["breach_open"] = true
		if int(siege.get("breach_cell", -1)) < 0:
			var site := Fort.for_city(war.store, node)
			siege["breach_cell"] = int(site["gate"]) if not site.is_empty() else -1
	elif not siege.has("breach_open"):
		siege["breach_open"] = false
	if not siege.has("breach_cell"): siege["breach_cell"] = -1


static func breach_open(war, node: String) -> bool:
	var siege: Dictionary = war.state.get("sieges", {}).get(node, {})
	if siege.is_empty(): return false
	if bool(siege.get("breach_open", false)): return true
	return int(siege.get("breach_cell", -1)) >= 0 or float(siege.get("wall", 1.0)) <= 0.0


static func breach_cell(war, node: String) -> int:
	if not breach_open(war, node): return -1
	var siege: Dictionary = war.state["sieges"][node]
	return int(siege.get("breach_cell", -1))


static func inside_attackers(war, node: String, board: Dictionary) -> Array:
	var site := Fort.for_city(war.store, node)
	if site.is_empty(): return []
	var cells := {}
	for value in site["cells"]: cells[int(value)] = true
	var city: Dictionary = war.store.city_state(node)
	var result: Array = []
	var board_id := str(board.get("battle_id", ""))
	for army in war.active_armies():
		if army.get("returning") or not army.has("tactical") or army["tactical"].get("placement_invalid", false): continue
		if not board_id.is_empty() and str(army.get("battlefield_id", "")) != board_id: continue
		if not war.hostile(str(army["faction"]), str(city.get("faction", ""))): continue
		if cells.has(int(army["tactical"]["cell"])): result.append(army)
	return result


static func can_attack_facilities(army: Dictionary) -> bool:
	return Roles.can_breach(army)


static func facility_power(war, group: Array) -> Dictionary:
	var infantry := 0
	var engines := 0
	var eligible: Array = []
	for army in group:
		if army.get("returning", false) or army.get("status", "active") == "ended": continue
		# 混编中只计步兵及其操作的器械，骑兵数量不参与设施伤害。
		if not can_attack_facilities(army): continue
		infantry += int(army["units"].get("infantry", 0))
		engines += Roles.engine_count(army)
		eligible.append(army)
	if eligible.is_empty() or (infantry <= 0 and engines <= 0):
		return {"wall": 0.0, "gate": 0.0, "total": 0.0, "infantry": 0, "engines": 0}
	var force := Combat.aggregate(eligible)
	var factor := Battle.factor(force, ["智计", "治军"], 0.003)
	var wall_power := 0.0
	var gate_power := 0.0
	if infantry > 0:
		wall_power = clampf(float(infantry) / WALL_INFANTRY_DIVISOR * factor, WALL_DAMAGE_MIN, WALL_DAMAGE_MAX)
	if engines > 0:
		gate_power = clampf(float(engines) * GATE_ENGINE_DAMAGE * factor, GATE_DAMAGE_MIN, GATE_DAMAGE_MAX)
	return {"wall": wall_power, "gate": gate_power, "total": wall_power + gate_power, "infantry": infantry, "engines": engines}


static func damage_facilities(war, node: String, siege: Dictionary, group: Array) -> Dictionary:
	var result := {"wall_damage": 0.0, "gate_damage": 0.0, "new_breach": false}
	var power := facility_power(war, group)
	if float(power["total"]) <= 0.0: return result
	var was_open := bool(siege.get("breach_open", false))
	var wall := float(siege.get("wall", 0.0))
	var gate := float(siege.get("gate", 0.0))
	var wall_power := float(power["wall"])
	var gate_power := float(power["gate"])
	# 步兵冲墙、器械撞门；一处先破后，余力转向另一处，避免伤害浪费。
	if wall > 0.0:
		var take := minf(wall_power, wall)
		wall -= take
		result["wall_damage"] = take
		wall_power -= take
	else:
		gate_power += wall_power
	if gate > 0.0:
		var take := minf(gate_power, gate)
		gate -= take
		result["gate_damage"] = take
	elif wall > 0.0:
		var take := minf(gate_power, wall)
		wall -= take
		result["wall_damage"] = float(result["wall_damage"]) + take
	siege["wall"] = maxf(0.0, wall)
	siege["gate"] = maxf(0.0, gate)
	siege["wall_breached"] = bool(siege.get("wall_breached", false)) or float(siege["wall"]) <= 0.0
	siege["gate_breached"] = bool(siege.get("gate_breached", false)) or float(siege["gate"]) <= 0.0
	if not was_open and (bool(siege["wall_breached"]) or bool(siege["gate_breached"])):
		open_passage(war, node, siege, group)
		result["new_breach"] = bool(siege.get("breach_open", false))
	persist(war, node, siege)
	return result


static func open_passage(war, node: String, siege: Dictionary, group: Array) -> int:
	# 通道位置完全沿用既有定义：城门用 site.gate，城墙用离攻方最近且属于
	# site.cells 的墙格（Fort.breach 的既有规则）。
	var site := Fort.for_city(war.store, node)
	if site.is_empty():
		siege["breach_open"] = true
		return -1
	# 城门破：通道即既有 site.gate；城墙破：通道为离攻方最近的既有墙格。
	if bool(siege.get("gate_breached", false)):
		Fort.breach(war, node, [])
	else:
		Fort.breach(war, node, group)
	var cell := int(war.state["sieges"][node].get("breach_cell", -1))
	war.state["sieges"][node]["breach_open"] = true
	siege["breach_cell"] = cell
	siege["breach_open"] = true
	return cell


static func interior_exchange(war, node: String, siege: Dictionary, entered: Array, defender: Dictionary, terrain: String) -> Dictionary:
	# 巷战：只有已进入城的部队与驻军交换伤害；城墙不再提供防护。
	var force := Combat.aggregate(entered)
	var strength := Combat.strength(force)
	if strength <= 0 or Combat.strength(defender) <= 0:
		return {"defender_loss": 0, "attacker_loss": 0, "attacker_personal": 0.0, "defender_personal": 0.0}
	var attacker_hit := Combat.losses_detail(force, defender, war.rules, terrain, war.rng.randf_range(0.9, 1.1) * 0.55, 1.0)
	var melee_defender := defender.duplicate(true)
	melee_defender["units"]["archers"] = 0
	melee_defender["units"]["infantry"] = int(int(melee_defender["units"]["infantry"]) * 0.8)
	var defense_hit := Combat.losses_detail(melee_defender, force, war.rules, terrain, 0.65)
	return {
		"defender_loss": int(attacker_hit["loss"]),
		"attacker_loss": int(defense_hit["loss"]),
		"attacker_personal": float(attacker_hit.get("personal_fraction", 0.0)),
		"defender_personal": float(defense_hit.get("personal_fraction", 0.0)),
	}


static func occupation_state(war, node: String, siege: Dictionary, inside_attackers: Array, city: Dictionary, attacker_strength: int) -> Dictionary:
	var defenders := int(city.get("garrison", 0))
	# wall<=0 不能直接占领，也不能瞬间击杀驻军；必须破口已开且有部队真正入城。
	if not breach_open(war, node): return {"ok": false, "reason": "尚未破城"}
	if inside_attackers.is_empty(): return {"ok": false, "reason": "破口已开，尚无部队入城"}
	if defenders <= 0: return {"ok": true, "reason": "破城攻取"}
	if float(siege.get("morale", 100.0)) < 15.0 and attacker_strength > defenders:
		return {"ok": true, "reason": "守军崩溃投降"}
	return {"ok": false, "reason": "城内部队仍在巷战"}
