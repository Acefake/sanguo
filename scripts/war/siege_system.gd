extends RefCounted

const Combat = preload("res://scripts/war/combat_system.gd")
const Battle = preload("res://scripts/war/officer_battle.gd")
const Tactical = preload("res://scripts/war/tactical_battlefield.gd")
const Fate = preload("res://scripts/war/officer_fate.gd")
const Fort = preload("res://scripts/war/city_fortifications.gd")
const Defense = preload("res://scripts/war/city_defense.gd")
const Roles = preload("res://scripts/war/troop_roles.gd")

static func at_city(war, army: Dictionary, node: String, radius: int = 2) -> bool:
	if not war.ready(army): return false
	if army.has("tactical"):
		var board := Tactical.board_for(war, army)
		if Fort.inside_city(board, int(army["tactical"]["cell"])) == node: return true
		return board.get("objectives", {}).has(node) and Fort.distance_to_wall(board, node, int(army["tactical"]["cell"])) <= maxi(1, radius - 1)
	return army["location"].get("edge", "") == "" and army["location"]["node"] == node

static func resolve(war) -> void:
	var groups := {}
	for army in war.active_armies():
		var node: String = army["target"]
		var city: Dictionary = war.store.city_state(node)
		var bow_support: bool = Roles.kind(army) == "archers"
		if war.Terrain.entry_factor(army,war.rules) <= 0 or army["returning"] or army["mission_type"] != "capture" or not war.hostile(str(city.get("faction", "")), str(army["faction"])) or not at_city(war, army, node, 3 if bow_support else 2): continue
		if not war.orders_for(army)["engage"]: continue
		var army_corps: Dictionary = war.state["corps"].get(army.get("corps_id", ""), {})
		if army.has("tactical") and army_corps.get("autonomous_deployment", false) and not army_corps.get("siege_approach", false): continue
		if not army.has("tactical") and army["action"]["type"] != "besiege" and not army.has("corps_id"): continue
		if army.has("tactical") and army.get("corps_task", {}).get("type", "main_attack") not in ["main_attack", "support", "command", "raid_rear", "flank"]: continue
		var key := node + ":" + str(army["faction"])
		if not groups.has(key): groups[key] = []
		groups[key].append(army)
	var processed := {}
	for group in groups.values():
		var army: Dictionary = group[0]
		var node: String = army["target"]
		if processed.has(node): continue
		processed[node] = true
		var city: Dictionary = war.store.city_state(node)
		war._sync_inventory(city)
		var corps: Dictionary = war.state["corps"].get(army.get("corps_id", ""), {})
		if not corps.is_empty(): army = war.state["armies"][corps["root_id"]]
		var siege: Dictionary = war.state["sieges"].get(node, {})
		if siege.is_empty() or siege["attacker"] != army["faction"] or siege.get("phase", "") == "occupied":
			if not siege.is_empty(): Defense.persist(war, node, siege)
			siege = Defense.create(war, node, army)
			war.state["sieges"][node] = siege
		Defense.migrate(war, node, siege)
		if siege["last_tick"] == int(war.state["tick"]): continue
		siege["last_tick"] = int(war.state["tick"])
		siege["active_tick"] = int(war.state["tick"])
		siege["mode"] = corps.get("siege_mode", "assault") if war.supply_enabled() else "assault"
		siege["participants"] = group.map(func(unit): return unit["id"])
		var relief := false
		for enemy in war.active_armies():
			if war.hostile(str(enemy["faction"]), str(army["faction"])) and not enemy["returning"]:
				for attacker in group:
					if enemy.has("tactical") and Fort.inside_city(Tactical.board_for(war, enemy), int(enemy["tactical"]["cell"])) == node: continue
					if Tactical.distance(attacker, enemy) <= 1 and not Tactical.shield_between(war, attacker, enemy) or (not attacker.has("tactical") and war._contact(attacker, enemy, {})): relief = true
		if relief:
			if siege["phase"] != "援军阻断": war.Feedback.event(war, "援军阻断", war.graph.name_of(node) + "援军到达，暂停攻城", army["faction"])
			siege["phase"] = "援军阻断"
			army["last_reason"] = "敌军正在城下接战，暂停攻城、迎击援军"
			continue
		var force := Combat.aggregate(group)
		var strength := Combat.strength(force)
		if strength <= 0: continue
		var defenders: int = city["garrison"]
		var guard := Fate.garrison(war, node, city)
		siege["commander_id"] = guard["officer_id"]
		var daily_food := defenders * float(war.rules["grain_per_soldier_day"])
		siege["grain_days"] = int(float(city.get("grain", 0)) / maxf(daily_food, 0.001)) if war.supply_enabled() else 999
		var defender := {"units": city["units"].duplicate(true), "training": city.get("training", 50), "equipment": city.get("equipment", 50), "morale": siege["morale"], "organization": siege["organization"], "fatigue": 0.0, "skills": {"布阵": 50}}
		defender["skills"] = war.roster.officers[guard["officer_id"]]["skills"].duplicate(true)
		defender["officer_id"] = guard["officer_id"]
		var board: Dictionary = Tactical.board_for(war, army)
		var objective_cell: int = board.get("objectives",{}).get(node,-1)
		var terrain: String = Tactical.terrain_class(objective_cell) if objective_cell >= 0 else war._terrain(node)
		army["battle_factors"] = war.Feedback.factors(group[0], defender, war.rules, terrain)
		siege["preparation"] = minf(100, float(siege["preparation"]) + clampf(float(strength) / maxf(defenders, 100) * 3 * Battle.factor(force, ["智计", "治军"], 0.004), 2, 12))
		army["siege_progress"] = siege["preparation"]
		var assembling := false
		if corps.get("siege_approach", false):
			var expected := 0
			for id in corps["units"]:
				var unit: Dictionary = war.state["armies"][id]
				if unit["status"] != "ended" and not unit["returning"] and unit["corps_task"]["type"] in ["main_attack", "flank"]: expected += Combat.strength(unit)
			assembling = strength < expected * 0.75
		siege["assembling"] = assembling
		# ---- 巷战判定先于设施结算：已入城部队不再承受城外强攻的反击 ----
		var tactical_group: bool = group.any(func(unit): return unit.has("tactical"))
		var group_ids := {}
		for unit in group: group_ids[str(unit["id"])] = true
		var breach_open := Defense.breach_open(war, node)
		var entered: Array = []
		if breach_open:
			for unit in Defense.inside_attackers(war, node, board):
				if group_ids.has(str(unit["id"])) and not unit["returning"] and unit["status"] != "ended": entered.append(unit)
			if not tactical_group:
				# 无战术格的抽象围城没有“入城格”，破城即视为通道开放、部队入城。
				for unit in group:
					if not unit["returning"] and unit["status"] != "ended": entered.append(unit)
		var inside_ids := {}
		for unit in entered: inside_ids[str(unit["id"])] = true
		# ---- 设施阶段：只有步兵/器械伤墙门；骑兵不参与；驻军不受外部攻击 ----
		var power: Dictionary = Defense.facility_power(war, group)
		siege["engine_bonus"] = Roles.breach_multiplier(group)
		var facilities_intact: bool = float(siege["wall"]) > 0.0 or float(siege["gate"]) > 0.0
		var assault: bool = facilities_intact and float(power["total"]) > 0.0 and not assembling and siege["mode"] == "assault" and float(siege["preparation"]) >= 30
		var wall_loss := 0
		var interior_loss := 0
		var defender_loss := 0
		var attacker_applied := 0
		var attacker_personal := 0.0
		var defender_personal := 0.0
		var defender_combat := false
		var fort := 1.0 + float(siege["wall"]) / maxf(float(siege["wall_max"]), 1) * float(city.get("defense", 0)) / 100
		if assault:
			var facility: Dictionary = Defense.damage_facilities(war, node, siege, group)
			if bool(facility["new_breach"]):
				var part := "城门" if bool(siege.get("gate_breached", false)) else "城墙"
				war.Feedback.event(war, "破墙", war.graph.name_of(node) + part + "被攻破", army["faction"])
			# 城墙反击只打仍在城下攻墙的部队，不波及已入城的巷战部队。
			var wall_targets: Array = group.filter(func(unit): return not inside_ids.has(str(unit["id"])))
			var melee_defender := defender.duplicate(true)
			melee_defender["units"]["archers"] = 0
			melee_defender["units"]["infantry"] = int(int(melee_defender["units"]["infantry"]) * 0.8)
			var defense_hit := Combat.losses_detail(melee_defender, force, war.rules, terrain, 0.65, fort) if defenders > 0 and not wall_targets.is_empty() else {"loss":0}
			wall_loss = int(defense_hit["loss"])
			for unit in wall_targets:
				unit["action"] = {"type": "besiege"}
				unit["combat_tick"] = int(war.state["tick"])
				unit["fatigue"] = minf(100, float(unit["fatigue"]) + Battle.fatigue_cost(unit, 3, true))
				if unit.has("tactical"): unit["tactical"]["phase"] = "破墙攻城"
		if not entered.is_empty():
			var exchange: Dictionary = Defense.interior_exchange(war, node, siege, entered, defender, terrain)
			defender_loss += int(exchange["defender_loss"])
			interior_loss += int(exchange["attacker_loss"])
			attacker_personal += float(exchange["attacker_personal"])
			defender_personal += float(exchange["defender_personal"])
			defender_combat = true
			for unit in entered:
				unit["combat_tick"] = int(war.state["tick"])
				unit["action"] = {"type": "besiege"}
				unit["fatigue"] = minf(100, float(unit["fatigue"]) + Battle.fatigue_cost(unit, 3, true))
				if unit.has("tactical"): unit["tactical"]["phase"] = "入城巷战"
		# 断粮是消耗而非外部攻击：只在主动围困（blockade）且城内断粮时生效。
		if war.supply_enabled() and siege["mode"] == "blockade" and defenders > 0 and float(city.get("grain", 0)) <= 0:
			defender_loss += maxi(1, int(defenders * 0.005))
			defender["morale"] = maxf(0, float(defender["morale"]) - 5)
			defender["organization"] = maxf(0, float(defender["organization"]) - 3)
		siege["phase"] = "强攻" if assault else "围困" if siege["mode"] == "blockade" else "准备"
		if assembling: siege["phase"] = "等待军团集结"
		if not entered.is_empty() and not assault: siege["phase"] = "入城巷战"
		elif breach_open and not assault and not assembling: siege["phase"] = "围攻破口" if siege["mode"] != "blockade" else "围困"
		siege["interior_combat"] = not entered.is_empty()
		siege["inside"] = entered.map(func(unit): return unit["id"])
		if defender_loss > 0:
			var weights := {}
			for unit in entered: weights[unit["id"]] = Combat.strength(unit)
			var assault_deaths := int(ceil(mini(defender_loss, defenders) * 0.65))
			if defender_combat: Fate.credit(war, weights, assault_deaths, {}, Fate.personal_weights(entered, weights, attacker_personal, war.rules))
			Combat.apply_loss(defender, defender_loss, false, 0.0 if defender_combat else 1.0)
			if defender_combat: Combat.battle_morale(defender, defender_loss, wall_loss + interior_loss, defenders, strength, defenders, strength)
		var remaining := wall_loss
		var wall_units: Array = group.filter(func(unit): return not inside_ids.has(str(unit["id"])))
		for index in range(wall_units.size()):
			var unit: Dictionary = wall_units[index]
			var loss := remaining if index == wall_units.size() - 1 else mini(remaining, int(ceil(float(wall_loss) * Combat.strength(unit) / strength)))
			var before_strength := Combat.strength(unit)
			var old_dead := int(unit.get("dead", 0))
			var actual := Combat.apply_loss(unit, loss, false, 0.0 if assault else 1.0)
			Fate.credit_garrison(war, guard, int(unit["dead"]) - old_dead, defender_personal)
			war.Feedback.loss(war, unit, actual)
			remaining -= actual
			attacker_applied += actual
			if assault: Combat.battle_morale(unit, actual, float(wall_loss) * before_strength / maxf(strength, 1), before_strength, defenders, strength, defenders)
			if wall_loss > 0: war._check_rout(unit)
		if not entered.is_empty():
			var interior_strength := Combat.strength(Combat.aggregate(entered))
			var interior_remaining := interior_loss
			for index in range(entered.size()):
				var unit: Dictionary = entered[index]
				var loss := interior_remaining if index == entered.size() - 1 else mini(interior_remaining, int(ceil(float(interior_loss) * Combat.strength(unit) / maxf(interior_strength, 1))))
				var before_strength := Combat.strength(unit)
				var old_dead := int(unit.get("dead", 0))
				var actual := Combat.apply_loss(unit, loss, false, 0.0)
				Fate.credit_garrison(war, guard, int(unit["dead"]) - old_dead, defender_personal)
				war.Feedback.loss(war, unit, actual)
				interior_remaining -= actual
				attacker_applied += actual
				Combat.battle_morale(unit, actual, float(defender_loss) * before_strength / maxf(interior_strength, 1), before_strength, defenders, interior_strength, defenders)
				if interior_loss > 0: war._check_rout(unit)
		if not entered.is_empty():
			# 城墙已破、巷战持续的守军额外承受崩溃压力：没有墙可守，只能靠街垒
			# 支撑。这加速“守军崩溃投降”，但占领依然要求破口+部队入城+兵力优势。
			defender["morale"] = maxf(0.0, float(defender["morale"]) - 2.0)
		city["units"] = defender["units"]
		city["garrison"] = Combat.strength(defender)
		city["war_dead"] = int(city.get("war_dead", 0)) + int(defender.get("dead", 0))
		city["wounded"] = int(city.get("wounded", 0)) + int(defender.get("wounded", 0))
		for type in Combat.TYPES: city["wounded_units"][type] += int(defender.get("wounded_units", {}).get(type, 0))
		siege["morale"] = defender["morale"]
		siege["organization"] = defender["organization"]
		siege["losses"] += attacker_applied
		siege["defender_losses"] += defender_loss
		Defense.persist(war, node, siege)
		war._report(army, "围城", "%s：%s，城墙%d/%d，城门%d/%d，准备%d%%，守军%d，攻方损失%d。" % [war.graph.name_of(node), siege["phase"], int(siege["wall"]), int(siege["wall_max"]), int(siege["gate"]), int(siege["gate_max"]), int(siege["preparation"]), int(city["garrison"]), attacker_applied], false)
		var ready: Array = group.filter(func(unit): return unit["status"] != "ended" and not unit["returning"])
		if not ready.is_empty():
			var inside_now: Array = []
			if breach_open:
				for unit in Defense.inside_attackers(war, node, board):
					if group_ids.has(str(unit["id"])) and not unit["returning"] and unit["status"] != "ended": inside_now.append(unit)
				if not tactical_group: inside_now = ready
			var decision: Dictionary = Defense.occupation_state(war, node, siege, inside_now, city, Combat.strength(Combat.aggregate(ready)))
			if bool(decision["ok"]):
				siege["capture_reason"] = str(decision["reason"])
				city["defense"] = int(ceil(float(city.get("defense", 0)) * float(siege["wall"]) / maxf(float(siege["wall_max"]), 1)))
				war._capture_city(army, ready, node, city)
				Fate.city_falls(war, guard, army)
				siege["phase"] = "occupied"
		war.store.city_changed.emit(node)
	for node in war.state["sieges"]:
		var siege: Dictionary = war.state["sieges"][node]
		if siege.get("phase", "") != "occupied" and int(siege.get("active_tick", -10)) != int(war.state["tick"]):
			if siege.get("phase", "") != "解围": war.store.city_state(node)["defense"] = ceili(float(siege["wall"]) / 4.0)
			siege["phase"] = "解围"
			var officer: String = str(siege.get("commander_id", ""))
			if not Fate.unavailable(war, officer) and war.state["officer_states"].get(officer, {}).get("status", "") == "guarding": war.state["officer_states"][officer] = {"status":"available", "city": node}
