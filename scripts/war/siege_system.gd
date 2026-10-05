extends RefCounted

const Combat = preload("res://scripts/war/combat_system.gd")
const Battle = preload("res://scripts/war/officer_battle.gd")
const Tactical = preload("res://scripts/war/tactical_battlefield.gd")

static func at_city(war, army: Dictionary, node: String, radius: int = 2) -> bool:
	if army.has("tactical"):
		var cell: int = war.state.get("battlefield", {}).get("objectives", {}).get(node, -1)
		return cell >= 0 and Tactical.cell_distance(int(army["tactical"]["cell"]), cell) <= radius
	return army["location"].get("edge", "") == "" and army["location"]["node"] == node

static func resolve(war) -> void:
	var groups := {}
	for army in war.active_armies():
		var node: String = army["target"]
		var city: Dictionary = war.store.city_state(node)
		if army.get("formation_locked",false) or war.Terrain.entry_factor(army,war.rules) <= 0 or army["returning"] or army["mission_type"] != "capture" or city.get("faction", "") == army["faction"] or not at_city(war, army, node): continue
		if not war.orders_for(army)["engage"]: continue
		var army_corps: Dictionary = war.state["corps"].get(army.get("corps_id", ""), {})
		if army.has("tactical") and army_corps.get("autonomous_deployment", false) and not army_corps.get("siege_approach", false): continue
		if not army.has("tactical") and army["action"]["type"] != "besiege" and not army.has("corps_id"): continue
		if army.has("tactical") and army.get("corps_task", {}).get("type", "main_attack") not in ["main_attack", "command", "raid_rear", "flank"]: continue
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
		siege["mode"] = corps.get("siege_mode", "assault")
		siege["participants"] = group.map(func(unit): return unit["id"])
		var relief := false
		for enemy in war.active_armies():
			if enemy["faction"] != army["faction"] and not enemy["returning"] and at_city(war, enemy, node, 4): relief = true
		if relief:
			if siege["phase"] != "援军阻断": war.Feedback.event(war, "援军阻断", war.graph.name_of(node) + "援军到达，暂停攻城", army["faction"])
			siege["phase"] = "援军阻断"
			army["last_reason"] = "敌军正在城下接战，暂停攻城、迎击援军"
			continue
		var force := Combat.aggregate(group)
		var strength := Combat.strength(force)
		if strength <= 0: continue
		var defenders: int = city["garrison"]
		var daily_food := defenders * float(war.rules["grain_per_soldier_day"])
		siege["grain_days"] = int(float(city.get("grain", 0)) / maxf(daily_food, 0.001))
		var defender := {"units": city["units"].duplicate(true), "training": city.get("training", 50), "equipment": city.get("equipment", 50), "morale": siege["morale"], "organization": siege["organization"], "fatigue": 0.0, "skills": {"布阵": 50}}
		var objective_cell: int = war.state.get("battlefield",{}).get("objectives",{}).get(node,-1)
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
		var assault: bool = not assembling and siege["mode"] == "assault" and float(siege["preparation"]) >= 30
		siege["phase"] = "强攻" if assault else "围困" if siege["mode"] == "blockade" else "准备"
		if assembling: siege["phase"] = "等待军团集结"
		var defender_loss := 0
		var attacker_loss := 0
		if assault:
			var breach := clampf(float(strength) / 800.0 * Battle.factor(force, ["智计", "治军"], 0.003), 2, 30)
			var old_wall: float = siege["wall"]
			siege["wall"] = maxf(0, float(siege["wall"]) - breach)
			if old_wall > 0 and float(siege["wall"]) <= 0: war.Feedback.event(war, "破墙", war.graph.name_of(node) + "城墙被攻破", army["faction"])
			var fort := 1.0 + float(siege["wall"]) / maxf(float(siege["wall_max"]), 1) * float(city.get("defense", 0)) / 100
			defender_loss = Combat.losses(force, defender, war.rules, terrain, 0.55, fort) if defenders > 0 else 0
			attacker_loss = Combat.losses(defender, force, war.rules, terrain, 0.65) if defenders > 0 else 0
			for unit in group:
				unit["action"] = {"type": "besiege"}
				unit["combat_tick"] = int(war.state["tick"])
				unit["fatigue"] = minf(100, float(unit["fatigue"]) + Battle.fatigue_cost(unit, 3, true))
				if unit.has("tactical"): unit["tactical"]["phase"] = "破墙攻城"
		if defenders > 0 and float(city.get("grain", 0)) <= 0:
			defender_loss += maxi(1, int(defenders * 0.005))
			defender["morale"] = maxf(0, float(defender["morale"]) - 5)
			defender["organization"] = maxf(0, float(defender["organization"]) - 3)
		Combat.apply_loss(defender, defender_loss, false, 0.0 if assault else 1.0)
		if assault: Combat.battle_morale(defender, defender_loss, attacker_loss, defenders, strength, defenders, strength)
		var remaining := attacker_loss
		for index in range(group.size()):
			var unit: Dictionary = group[index]
			var loss := remaining if index == group.size() - 1 else mini(remaining, int(ceil(float(attacker_loss) * Combat.strength(unit) / strength)))
			var before_strength := Combat.strength(unit)
			var actual := Combat.apply_loss(unit, loss, false, 0.0 if assault else 1.0)
			war.Feedback.loss(war, unit, actual)
			remaining -= actual
			if assault: Combat.battle_morale(unit, actual, float(defender_loss) * before_strength / maxf(strength, 1), before_strength, defenders, strength, defenders)
			if attacker_loss > 0: war._check_rout(unit)
		city["units"] = defender["units"]
		city["garrison"] = Combat.strength(defender)
		city["war_dead"] = int(city.get("war_dead", 0)) + int(defender.get("dead", 0))
		city["wounded"] = int(city.get("wounded", 0)) + int(defender.get("wounded", 0))
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
			siege["phase"] = "occupied"
		war.store.city_changed.emit(node)
	for node in war.state["sieges"]:
		var siege: Dictionary = war.state["sieges"][node]
		if siege.get("phase", "") != "occupied" and int(siege.get("active_tick", -10)) != int(war.state["tick"]): siege["phase"] = "解围"

