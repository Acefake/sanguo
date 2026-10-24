extends RefCounted

# Read-only consequence estimation for candidate actions. Never mutates the war,
# never consumes random numbers (random factor uses the 1.0 expectation), and only
# ever reads the limited intel an army actually holds.

const Combat = preload("res://scripts/war/battle/combat_system.gd")
const Tactical = preload("res://scripts/war/battle/tactical_battlefield.gd")

const MELEE := ["engage", "flank", "pursue", "besiege"]
const ESTIMATE := {"training": 50, "equipment": 50, "morale": 70.0, "organization": 70.0, "fatigue": 0.0, "skills": {}, "ranged_attack": false}

# Frozen snapshots only; never reads enemy truth or consumes the battle RNG.
static func tactical_exchange(own: Dictionary, sight: Dictionary, rules: Dictionary, terrain: String) -> Dictionary:
	var opponent := _estimate_from(sight)
	if opponent.is_empty(): return {}
	var attacker: Dictionary = own.duplicate()
	attacker["action"] = {"type":"hold"}
	attacker["name"] = "己军估计"
	attacker["melee_attack"] = true
	opponent["melee_attack"] = true
	var enemy_terrain := Tactical.terrain_class(int(sight.get("cell",sight.get("tactical_cell",own["cell"]))))
	var defense := Combat.losses_detail(opponent,attacker,rules,terrain,1.0,1.0,enemy_terrain)
	var offense := Combat.losses_detail(attacker,opponent,rules,enemy_terrain,1.0,1.0,terrain)
	var own_ranged := 0
	var enemy_ranged := 0
	var enemy_range := Tactical.attack_range(opponent)
	if int(own.get("attack_range",1)) > 1:
		var bow: Dictionary = attacker.duplicate()
		bow["units"] = {"infantry":0,"archers":attacker["units"].get("archers",0),"cavalry":0}
		bow["ranged_attack"] = true
		bow["melee_attack"] = false
		own_ranged = Combat.losses_detail(bow,opponent,rules,enemy_terrain,1.0,1.0,terrain)["loss"]
	if enemy_range > 1:
		var bow: Dictionary = opponent.duplicate()
		bow["units"] = {"infantry":0,"archers":opponent["units"].get("archers",0),"cavalry":0}
		bow["ranged_attack"] = true
		bow["melee_attack"] = false
		enemy_ranged = Combat.losses_detail(bow,attacker,rules,terrain,1.0,1.0,enemy_terrain)["loss"]
	return {"own_loss":defense["loss"],"enemy_loss":offense["loss"],"own_loss_ranged":enemy_ranged,"enemy_loss_ranged":own_ranged,"range":enemy_range}


static func annotate(war, army: Dictionary, candidates: Array, options: Dictionary = {}) -> void:
	var terrain: String = str(options.get("terrain", _terrain(war, army)))
	var enemies: Dictionary = options.get("enemies", army.get("intel", {}).get("enemies", {}))
	var prepare: int = int(options.get("required_preparation", 0))
	for candidate in candidates:
		candidate["forecast"] = forecast(war, army, candidate, terrain, enemies, prepare)


static func forecast(war, army: Dictionary, candidate: Dictionary, terrain: String, enemies: Dictionary, prepare: int = 0) -> Dictionary:
	var action: Dictionary = candidate.get("action", {})
	var kind: String = str(action.get("type", ""))
	var result: Dictionary = {"notes": []}
	if kind in MELEE:
		_exchange(war, army, action, terrain, enemies, result)
	if kind == "hold":
		# A unit that is going to be attacked anyway needs the same consequence
		# estimate, otherwise hold's own_loss factor can never fire.
		_held_exchange(war, army, terrain, enemies, result)
	if kind in ["march", "withdraw"]:
		var node: String = str(action.get("target", army.get("location", {}).get("node", ""))) if kind == "march" else _nearest_friendly(war, army)
		var eta := _travel_days(war, army)
		if kind == "march" and node != "": eta = _travel_days(war, army, node)
		result["eta_days"] = eta
		result["grain_after"] = float(army.get("grain", 0.0)) / maxf(_daily_food(war, army), 0.001) - float(eta)
	if kind == "resupply":
		result["grain_after"] = float(war.rules.get("carry_days", 24))
	if kind == "flank":
		var eta := _travel_days(war, army)
		result["eta_days"] = eta
		result["grain_after"] = float(army.get("grain", 0.0)) / maxf(_daily_food(war, army), 0.001) - float(eta)
	if kind in ["march", "withdraw", "flank"]:
		result["flank_risk"] = _flank_risk(war, army, str(action.get("enemy", "")))
	if kind == "withdraw":
		result["escape_ready"] = _escape_ready(war, army, prepare)
	if kind in ["march", "withdraw"]:
		result["notes"] = ["预计行军 %d 日" % int(result.get("eta_days", 0))]
	if not war.supply_enabled(): result.erase("grain_after")
	return result


static func _exchange(war, army: Dictionary, action: Dictionary, terrain: String, enemies: Dictionary, result: Dictionary) -> void:
	var opponent := _opponent(war, army, action, terrain, enemies)
	if opponent.is_empty(): return
	var rules: Dictionary = war.rules
	var defense := Combat.losses_detail(opponent, army, rules, terrain, 1.0)
	var offense := Combat.losses_detail(army, opponent, rules, terrain, 1.0)
	var own_loss: int = int(defense["loss"])
	var enemy_loss: int = int(offense["loss"])
	result["own_loss"] = own_loss
	result["enemy_loss"] = enemy_loss
	result["kill_ratio"] = float(enemy_loss) / maxf(float(own_loss), 1.0)
	result["morale_delta"] = clampf((float(enemy_loss) - float(own_loss)) / maxf(float(Combat.strength(army)), 1.0) * 120.0, -8.0, 4.0)
	result["notes"] = _notes(offense, defense, result["kill_ratio"])


static func _held_exchange(war, army: Dictionary, terrain: String, enemies: Dictionary, result: Dictionary) -> void:
	# What holding this position costs if the nearest observed enemy simply attacks it.
	var opponent := _nearest_observed(war, army, enemies)
	if opponent.is_empty(): return
	var rules: Dictionary = war.rules
	var incoming := Combat.losses_detail(opponent, army, rules, terrain, 1.0)
	result["own_loss"] = int(incoming["loss"])
	result["under_attack"] = true
	result["notes"] = _notes(incoming, incoming, 0.0)


static func _nearest_observed(war, army: Dictionary, enemies: Dictionary) -> Dictionary:
	var best: Dictionary = {}
	var best_distance := 1 << 30
	for id in enemies.keys():
		var sight: Dictionary = enemies[id]
		if int(sight.get("observed_at",-1)) != int(war.state["tick"]): continue
		var enemy: Dictionary = _estimate_from(sight)
		if enemy.is_empty(): continue
		var distance := 0
		if army.has("tactical"):
			var target := int(sight.get("tactical_cell",-1))
			if target < 0: continue
			distance = Tactical.cell_distance(int(army["tactical"]["cell"]),target)
			if distance < 1 or distance > Tactical.attack_range(enemy): continue
			if distance > 1 and not preload("res://scripts/war/battle/city_fortifications.gd").line_of_sight(Tactical.board_for(war,army),int(army["tactical"]["cell"]),target): continue
			enemy["ranged_attack"] = distance > 1
		else:
			var location: Dictionary = sight.get("location",{})
			if location.is_empty() or location.get("node","") != army.get("location",{}).get("node","") or location.get("edge","") != army.get("location",{}).get("edge",""): continue
		if distance < best_distance:
			best_distance = distance
			best = enemy
	return best


static func _estimate_from(observed: Dictionary) -> Dictionary:
	if observed.is_empty(): return {}
	var mix: Dictionary = observed.get("unit_mix_estimate", {})
	var units: Dictionary = {}
	var total := 0
	for type in Combat.TYPES:
		units[type] = int(round(float(mix.get(type, 0))))
		total += int(units[type])
	if total <= 0: units = {"infantry": int(observed.get("strength_estimate", 0)), "archers": 0, "cavalry": 0}
	return _estimate(units, int(observed.get("strength_estimate", total)))


static func _opponent(war, army: Dictionary, action: Dictionary, terrain: String, enemies: Dictionary) -> Dictionary:
	if str(action.get("type", "")) == "besiege":
		var intel: Dictionary = army.get("intel", {}).get("cities", {}).get(str(army.get("target", "")), {})
		var garrison := int(intel.get("strength_estimate", 0))
		if garrison <= 0: return {}
		return _estimate({"infantry": garrison}, garrison)
	var id: String = str(action.get("enemy", ""))
	return _estimate_from(enemies.get(id, {}))


static func _estimate(units: Dictionary, strength: int) -> Dictionary:
	var estimate: Dictionary = ESTIMATE.duplicate(true)
	estimate["units"] = units
	estimate["initial_strength"] = strength
	estimate["action"] = {"type": "hold"}
	estimate["name"] = "敌军"
	return estimate


static func _notes(offense: Dictionary, defense: Dictionary, kill_ratio: float) -> Array:
	var entries: Array = [[absf(kill_ratio - 1.0) + 0.4, "预计杀伤比 %.2f" % kill_ratio]]
	for key in offense.get("factors", {}):
		var value := float(offense["factors"][key])
		if absf(value - 1.0) > 0.05: entries.append([absf(value - 1.0), "%s×%.2f" % [key, value]])
	for key in defense.get("factors", {}):
		var value := float(defense["factors"][key])
		if absf(value - 1.0) > 0.05: entries.append([absf(value - 1.0), "%s×%.2f" % [key, value]])
	entries.sort_custom(func(a, b): return a[0] > b[0])
	var notes: Array = []
	for entry in entries.slice(0, 3): notes.append(entry[1])
	return notes


static func _flank_risk(war, army: Dictionary, target_id: String) -> float:
	if not army.has("tactical"): return 0.0
	var cell := int(army["tactical"]["cell"])
	var enemies := 0
	var allies := 0
	# Only enemies this army has actually observed count. Reading every army on the
	# board gave the officer knowledge no scout could have.
	var observed: Dictionary = army.get("intel", {}).get("enemies", {})
	for other in war.active_armies():
		if not other.has("tactical") or other.get("status", "") == "ended" or other["returning"]: continue
		if str(other.get("faction", "")) == str(army.get("faction", "")):
			allies += 1
			continue
		if str(other.get("id", "")) == str(target_id): continue
		var record: Dictionary = observed.get(str(other["id"]), {})
		if record.is_empty(): continue
		if int(record.get("observed_at", -1)) < int(war.state["tick"]) - int(war.rules.get("intel_expiry_days", 4)): continue
		enemies += 1
	return clampf(float(enemies) / maxf(float(allies + enemies + 1), 1.0), 0.0, 1.0)


static func _escape_ready(war, army: Dictionary, prepare: int) -> bool:
	if not army.has("tactical"): return true
	var needed: int = maxi(prepare, 1)
	return int(army["tactical"].get("withdraw_preparation", 0)) >= needed


static func _travel_days(war, army: Dictionary, node: String = "") -> int:
	if army.has("tactical"):
		var goal := _nearest_friendly(war, army) if node == "" else node
		if goal != "": return maxi(1, Tactical.cell_distance(int(army["tactical"]["cell"]), _cell_of(war, goal)) / 2)
		return 1
	var location: Dictionary = army.get("location", {})
	var here: String = str(location.get("node", ""))
	var destination: String = node
	if destination == "": destination = _nearest_friendly(war, army)
	if destination == "" or here == "": return 1
	var path: Dictionary = war.graph.path(here, destination)
	if not bool(path.get("found", false)): return 1
	return int(ceil(float(path.get("cost", 1)) * float(war.rules.get("route_days_per_cost", 3.0))))


static func _cell_of(war, node: String) -> int:
	var board: Dictionary = war.state.get("battlefield", {})
	var objective := int(board.get("objectives", {}).get(node, -1))
	return objective


static func _nearest_friendly(war, army: Dictionary) -> String:
	if army.has("tactical"):
		var cell := int(army["tactical"]["cell"])
		var board: Dictionary = war.state.get("battlefield", {})
		var best := ""
		var best_distance := 1 << 30
		for node in board.get("objectives", {}):
			if str(war.store.city_state(str(node)).get("faction", "")) != str(army.get("faction", "")): continue
			var distance := Tactical.cell_distance(cell, int(board["objectives"][node]))
			if distance < best_distance: best_distance = distance; best = str(node)
		return best
	var here: String = str(army.get("location", {}).get("node", ""))
	var best := ""
	var best_cost := INF
	for node in war.store.scenario.get("places", {}):
		var city: Dictionary = war.store.city_state(str(node))
		if not city.has("population") or str(city.get("faction", "")) != str(army.get("faction", "")): continue
		var path: Dictionary = war.graph.path(here, str(node))
		if bool(path.get("found", false)) and float(path.get("cost", INF)) < best_cost:
			best_cost = float(path["cost"]); best = str(node)
	return best


static func _terrain(war, army: Dictionary) -> String:
	if army.has("tactical"): return Tactical.terrain_class(int(army["tactical"]["cell"]))
	return war._terrain(str(army.get("location", {}).get("node", "")))


static func _daily_food(war, army: Dictionary) -> float:
	return (float(Combat.strength(army)) + int(army.get("wounded", 0))) * float(war.rules.get("grain_per_soldier_day", 0.004))
