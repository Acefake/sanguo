extends RefCounted

const Combat = preload("res://scripts/war/combat_system.gd")
const Battle = preload("res://scripts/war/officer_battle.gd")
const Tactical = preload("res://scripts/war/tactical_battlefield.gd")
const Fate = preload("res://scripts/war/officer_fate.gd")
const Fort = preload("res://scripts/war/city_fortifications.gd")

static func at_city(war, army: Dictionary, node: String, radius: int = 2) -> bool:
	if not war.ready(army): return false
	if army.has("tactical"):
		var board := Tactical.board_for(war, army)
		return board.get("objectives", {}).has(node) and Fort.distance_to_wall(board, node, int(army["tactical"]["cell"])) <= maxi(1, radius - 1)
	return army["location"].get("edge", "") == "" and army["location"]["node"] == node

static func resolve(war) -> void:
	var groups := {}
	for army in war.active_armies():
		var node: String = army["target"]
		var city: Dictionary = war.store.city_state(node)
		var bow_support: bool = preload("res://scripts/war/troop_roles.gd").kind(army) == "archers"
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
			var wall := maxf(0, float(city.get("defense", 0)) * 4)
			siege = {"city": node, "attacker": army["faction"], "started": int(war.state["tick"]), "last_tick": -1, "wall_max": wall, "wall": wall, "preparation": float(army.get("siege_progress", 0)), "morale": 100.0, "organization": 100.0, "phase": "准备", "mode": "assault", "losses": 0, "defender_losses": 0}
			war.state["sieges"][node] = siege
		if siege["last_tick"] == int(war.state["tick"]): continue
		siege["last_tick"] = int(war.state["tick"])
		siege["active_tick"] = int(war.state["tick"])
		siege["mode"] = corps.get("siege_mode", "assault") if war.supply_enabled() else "assault"
		siege["participants"] = group.map(func(unit): return unit["id"])
		var relief := false
		for enemy in war.active_armies():
			if war.hostile(str(enemy["faction"]), str(army["faction"])) and not enemy["returning"]:
				for attacker in group:
					if Tactical.distance(attacker, enemy) <= 1 or (not attacker.has("tactical") and war._contact(attacker, enemy, {})): relief = true
		if relief:
			if siege["phase"] != "援军阻断": war.Feedback.event(war, "援军阻断", war.graph.name_of(node) + "援军到达，暂停攻城", army["faction"])
			siege["phase"] = "援军阻断"
			army["last_reason"] = "敌军正在城下接战，暂停攻城、迎击援军"
			continue
		var force := Combat.aggregate(group)
		var strength := Combat.strength(force)
		var breach_strength := 0
		for unit in group: breach_strength += int(unit["units"].get("infantry",0))
		if strength <= 0: continue
		var defenders: int = city["garrison"]
		var guard := Fate.garrison(war, node, city)
		siege["commander_id"] = guard["officer_id"]
		var daily_food := defenders * float(war.rules["grain_per_soldier_day"])
		siege["grain_days"] = int(float(city.get("grain", 0)) / maxf(daily_food, 0.001)) if war.supply_enabled() else 999
		var defender := {"units": city["units"].duplicate(true), "training": city.get("training", 50), "equipment": city.get("equipment", 50), "morale": siege["morale"], "organization": siege["organization"], "fatigue": 0.0, "skills": {"布阵": 50}}
		defender["skills"] = war.roster.officers[guard["officer_id"]]["skills"].duplicate(true)
		defender["officer_id"] = guard["officer_id"]
		var objective_cell: int = Tactical.board_for(war, army).get("objectives",{}).get(node,-1)
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
		var assault: bool = breach_strength > 0 and not assembling and siege["mode"] == "assault" and float(siege["preparation"]) >= 30
		siege["phase"] = "强攻" if assault else "围困" if siege["mode"] == "blockade" else "准备"
		if assembling: siege["phase"] = "等待军团集结"
		var defender_loss := 0
		var attacker_loss := 0
		var attacker_personal := 0.0
		var defender_personal := 0.0
		if assault:
			var breach := clampf(float(breach_strength) / 800.0 * Battle.factor(force, ["智计", "治军"], 0.003), 2, 30)
			breach *= preload("res://scripts/war/troop_roles.gd").breach_multiplier(group)
			siege["engine_bonus"] = preload("res://scripts/war/troop_roles.gd").breach_multiplier(group)
			var old_wall: float = siege["wall"]
			siege["wall"] = maxf(0, float(siege["wall"]) - breach)
			if float(siege["wall"]) <= 0 and not siege.has("breach_cell"):
				Fort.breach(war, node, group)
				war.Feedback.event(war, "破墙", war.graph.name_of(node) + "城墙被攻破", army["faction"])
			var fort := 1.0 + float(siege["wall"]) / maxf(float(siege["wall_max"]), 1) * float(city.get("defense", 0)) / 100
			var assault_hit := Combat.losses_detail(force, defender, war.rules, terrain, 0.55, fort) if defenders > 0 else {"loss":0}
			var melee_defender := defender.duplicate(true)
			melee_defender["units"]["archers"] = 0
			melee_defender["units"]["infantry"] = int(int(melee_defender["units"]["infantry"]) * 0.8)
			var defense_hit := Combat.losses_detail(melee_defender, force, war.rules, terrain, 0.65) if defenders > 0 else {"loss":0}
			defender_loss = int(assault_hit["loss"])
			attacker_loss = int(defense_hit["loss"])
			attacker_personal = float(assault_hit.get("personal_fraction", 0))
			defender_personal = float(defense_hit.get("personal_fraction", 0))
			for unit in group:
				unit["action"] = {"type": "besiege"}
				unit["combat_tick"] = int(war.state["tick"])
				unit["fatigue"] = minf(100, float(unit["fatigue"]) + Battle.fatigue_cost(unit, 3, true))
				if unit.has("tactical"): unit["tactical"]["phase"] = "破墙攻城"
		if war.supply_enabled() and defenders > 0 and float(city.get("grain", 0)) <= 0:
			defender_loss += maxi(1, int(defenders * 0.005))
			defender["morale"] = maxf(0, float(defender["morale"]) - 5)
			defender["organization"] = maxf(0, float(defender["organization"]) - 3)
		var assault_deaths := int(ceil(mini(defender_loss, defenders) * 0.65)) if assault else 0
		var weights := {}
		for unit in group: weights[unit["id"]] = Combat.strength(unit)
		Fate.credit(war, weights, assault_deaths, {}, Fate.personal_weights(group, weights, attacker_personal, war.rules))
		Combat.apply_loss(defender, defender_loss, false, 0.0 if assault else 1.0)
		if assault: Combat.battle_morale(defender, defender_loss, attacker_loss, defenders, strength, defenders, strength)
		var remaining := attacker_loss
		for index in range(group.size()):
			var unit: Dictionary = group[index]
			var loss := remaining if index == group.size() - 1 else mini(remaining, int(ceil(float(attacker_loss) * Combat.strength(unit) / strength)))
			var before_strength := Combat.strength(unit)
			var old_dead := int(unit.get("dead", 0))
			var actual := Combat.apply_loss(unit, loss, false, 0.0 if assault else 1.0)
			Fate.credit_garrison(war, guard, int(unit["dead"]) - old_dead, defender_personal)
			war.Feedback.loss(war, unit, actual)
			remaining -= actual
			if assault: Combat.battle_morale(unit, actual, float(defender_loss) * before_strength / maxf(strength, 1), before_strength, defenders, strength, defenders)
			if attacker_loss > 0: war._check_rout(unit)
		city["units"] = defender["units"]
		city["garrison"] = Combat.strength(defender)
		city["war_dead"] = int(city.get("war_dead", 0)) + int(defender.get("dead", 0))
		city["wounded"] = int(city.get("wounded", 0)) + int(defender.get("wounded", 0))
		for type in Combat.TYPES: city["wounded_units"][type] += int(defender.get("wounded_units", {}).get(type, 0))
		siege["morale"] = defender["morale"]
		siege["organization"] = defender["organization"]
		siege["losses"] += attacker_loss - remaining
		siege["defender_losses"] += defender_loss
		war._report(army, "围城", "%s：%s，城墙%d/%d，准备%d%%，守军%d，攻方损失%d。" % [war.graph.name_of(node), siege["phase"], int(siege["wall"]), int(siege["wall_max"]), int(siege["preparation"]), int(city["garrison"]), attacker_loss - remaining], false)
		var ready: Array = group.filter(func(unit): return unit["status"] != "ended" and not unit["returning"])
		if not ready.is_empty() and (int(city["garrison"]) == 0 or (float(siege["wall"]) <= 0 and float(siege["preparation"]) >= 30 and Combat.strength(Combat.aggregate(ready)) > int(city["garrison"])) or (float(siege["morale"]) < 15 and Combat.strength(Combat.aggregate(ready)) > int(city["garrison"]))):
			siege["capture_reason"] = "空城接管" if int(city["garrison"]) == 0 else "破墙攻取" if float(siege["wall"]) <= 0 else "守军崩溃投降"
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

