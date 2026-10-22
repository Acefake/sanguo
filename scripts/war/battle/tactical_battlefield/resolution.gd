@abstract
class_name TacticalResolution
extends "res://scripts/war/battle/tactical_battlefield/movement.gd"
## 战术结算：每回合的伤害结算、侧击与击破跟进、主将光环。


# Exploiting a broken or withdrawing enemy. Read from campaign_rules.json via combat.flank
# so the strike bonuses stay in one place; these are the fallback defaults.
static func _flank_tuning(war) -> Dictionary:
	return Combat.settings(war.rules).get("flank", {})


static func _flank_num(war, key: String, fallback: float) -> float:
	return float(_flank_tuning(war).get(key, fallback))


static func _breakthrough_tuning(war) -> Dictionary:
	return Combat.settings(war.rules).get("breakthrough", {})


# After simultaneous melee resolution, a truly destroyed defender leaves an empty
# tile. One surviving melee striker may step in, spending one real point of the
# same round budget and extending move_path so the map animation walks in.
static func _resolve_breakthrough(war, melee_strikers: Dictionary, dealt: Dictionary) -> void:
	var tuning := _breakthrough_tuning(war)
	if not bool(tuning.get("enabled", true)): return
	var board: Dictionary = war.state["battlefield"]
	var tick := int(war.state["tick"])
	var occupied := {}
	for army in participants(war):
		if army.has("tactical") and not army["tactical"].get("placement_invalid",false): occupied[int(army["tactical"]["cell"])] = army["id"]
	var minimum := float(tuning.get("min_remaining_points", 1.0))
	var max_threat := int(tuning.get("max_threat", 1))
	var victims: Array = melee_strikers.keys()
	victims.sort()
	for defender_id in victims:
		var defender: Dictionary = war.state["armies"].get(str(defender_id), {})
		if defender.is_empty() or str(defender.get("status","")) != "ended": continue
		if int(Combat.strength(defender)) > 0: continue
		var cell := int(defender.get("tactical",{}).get("cell",-1))
		if cell < 0 or occupied.has(cell): continue
		var options: Array = []
		for striker_id in melee_strikers[defender_id]:
			var striker: Dictionary = war.state["armies"].get(str(striker_id), {})
			if striker.is_empty() or str(striker.get("status","")) == "ended": continue
			if bool(striker.get("returning",false)) or int(Combat.strength(striker)) <= 0: continue
			if not striker.has("tactical") or attack_range(striker) != 1: continue
			var tactical: Dictionary = striker["tactical"]
			if tactical.get("placement_invalid",false): continue
			if int(tactical.get("round_marker",-1)) != tick: continue
			if int(tactical.get("breakthrough_marker",-1)) == tick: continue
			if float(tactical.get("round_points", 0.0)) < minimum: continue
			var start := int(tactical["cell"])
			if cell_distance(start, cell) != 1: continue
			var orders: Dictionary = war.orders_for(striker)
			if not bool(orders.get("engage", true)) or not bool(orders.get("pursue", true)): continue
			# A hold order keeps the formation on its duty cell; it never follows in.
			var task: Dictionary = striker.get("corps_task", {})
			if bool(orders.get("must_hold_objective", false)) or bool(task.get("must_hold_objective", false)): continue
			var duty := int(task.get("cell", -1))
			if duty < 0: duty = int(tactical.get("duty_cell", start))
			if cell_distance(cell, duty) > int(task.get("region_radius", 16)): continue
			if not in_battlefield(Fort.movement_board(war, board, str(striker["faction"])), cell): continue
			if _breakthrough_threat(war, striker, cell, str(defender_id)) > max_threat: continue
			options.append({"army":striker,"id":str(striker_id),"contribution":float(dealt.get(str(striker_id),{}).get(str(defender_id),0))})
		if options.is_empty(): continue
		options.sort_custom(func(a,b):
			if not is_equal_approx(float(a["contribution"]),float(b["contribution"])): return float(a["contribution"]) > float(b["contribution"])
			return str(a["id"]) < str(b["id"]))
		var mover: Dictionary = options[0]["army"]
		var move: Dictionary = mover["tactical"]
		var start := int(move["cell"])
		var routes: Array = move.get("move_path", [start])
		if routes.is_empty() or int(routes[-1]) != start: routes = [start]
		routes.append(cell)
		move["move_path"] = routes
		move["cell"] = cell
		move["previous_cell"] = start
		move["moved_tick"] = tick
		move["breakthrough_marker"] = tick
		move["round_points"] = maxf(0.0, float(move.get("round_points", minimum)) - 1.0)
		move["movement_credit"] = minf(float(move["round_points"]),0.99)
		move["phase"] = "击破跟进"
		move["flank_ready"] = false
		if terrain_class(cell) in ["mountains","ford"]: move["terrain_delay"] = terrain_class(cell)
		occupied.erase(start)
		occupied[cell] = str(mover["id"])
		if mover.has("battle_ai") and not mover["battle_ai"]["history"].is_empty():
			var record: Dictionary = mover["battle_ai"]["history"][-1]
			record["executed_cell"] = cell
			record["breakthrough_cell"] = cell


# The empty tile is a viable foothold only if the visible enemy records this
# unit holds say so; hidden squadrons must not veto a breakthrough through the
# engine's private positions.
static func _breakthrough_threat(war, mover: Dictionary, cell: int, defender_id: String) -> int:
	var tick := int(war.state["tick"])
	var threat := 0
	for enemy_id in mover.get("intel",{}).get("enemies",{}):
		if str(enemy_id) == defender_id: continue
		var sight: Dictionary = mover["intel"]["enemies"][enemy_id]
		if int(sight.get("observed_at",-1)) != tick: continue
		if bool(sight.get("routing",false)): continue
		var enemy_cell := int(sight.get("tactical_cell",-1))
		if enemy_cell < 0: continue
		if cell_distance(cell, enemy_cell) <= 1: threat += 1
	return threat


static func _compute_auras(war) -> void:
	var strengths := {}
	for army in participants(war):
		army["aura"] = 0.0
		var corps: Dictionary = war.state["corps"].get(str(army.get("corps_id", "")), {})
		var leader: Dictionary = army
		if not corps.is_empty(): leader = war.state["armies"].get(str(corps["root_id"]), army)
		if leader.is_empty() or str(leader["status"]) == "ended" or bool(leader["returning"]): continue
		var strength := Process.aura_strength(leader, war.rules)
		if strength <= 0.0: continue
		var radius := Process.aura_range(leader, war.rules)
		var members: Array = [army] if corps.is_empty() else corps["units"]
		for id in members:
			var unit: Dictionary = war.state["armies"].get(str(id), {})
			if unit.is_empty() or str(unit["status"]) == "ended" or bool(unit["returning"]): continue
			if unit["id"] != leader["id"] and distance(unit, leader) > radius: continue
			strengths[unit["id"]] = maxf(float(strengths.get(unit["id"], 0.0)), strength)
	for id in strengths: war.state["armies"][id]["aura"] = strengths[id]


## 战术结算阶段：结算本回合伤害、侧击、击破跟进与光环。
static func resolve(war) -> void:
	clear_target_cache()
	var damages := {}
	var dealt := {}
	var personal_dealt := {}
	var before := {}
	for unit in participants(war):
		before[unit["id"]] = Combat.strength(unit)
		unit["combat_targets"] = []
	_compute_auras(war)
	var aura_scale := float(war.rules.get("officer", {}).get("aura_org_scale", 0.5))
	var attackers := {}
	# Melee strikers that actually hit each defender this tick. Only these may
	# occupy a broken tile; ranged-only fire never follows into the cell.
	var melee_strikers := {}
	# Apply one-time contact effects before the simultaneous damage snapshot.
	for army in participants(war):
		if not army.has("tactical") or army["returning"] or not war.orders_for(army)["engage"] or not can_attack(war, army): continue
		var contact_targets := targets(war, army)
		var selected_contact: String = str(army["tactical"].get("attack_target", ""))
		for enemy in contact_targets:
			if enemy["id"] == selected_contact:
				# Reorder into a fresh array; targets() is memoised and shared.
				contact_targets = [enemy] + contact_targets.filter(func(e): return e["id"] != enemy["id"])
				break
		if not contact_targets.is_empty() and distance(army, contact_targets[0]) <= 1: war._battle_contact(army, contact_targets[0])
	for army in participants(war):
		if not army.has("tactical") or not can_attack(war, army): continue
		for enemy in targets(war, army):
			if Duel.eligible(war, army, enemy):
				Duel.challenge(war, army, enemy)
				break
	# Damage requires current adjacent contact; no remote hit after withdrawal.
	for army in participants(war):
		if not can_engage(war, army): continue
		var enemies := targets(war, army)
		var selected: String = str(army["tactical"].get("attack_target", ""))
		if war.state["armies"].has(selected):
			var preferred: Dictionary = war.state["armies"][selected]
			# Build a new ordering rather than mutating targets(), whose result is shared.
			if enemies.has(preferred): enemies = [preferred] + enemies.filter(func(e): return e["id"] != preferred["id"])
		# Share one army's attack budget across its adjacent contact sectors.
		var adjacent := enemies.filter(func(e): return distance(army,e) == 1)
		if not adjacent.is_empty():
			enemies = adjacent
		else:
			enemies = enemies.filter(func(e): return distance(army,e) <= attack_range(army) and Fort.line_of_sight(war.state["battlefield"],int(army["tactical"]["cell"]),int(e["tactical"]["cell"]))).slice(0,1)
		for enemy in enemies:
			var separation := distance(army, enemy)
			if separation < 1 or separation > attack_range(army): continue
			if shield_between(war, army, enemy): continue
			if separation > 1 and not Fort.line_of_sight(war.state["battlefield"], int(army["tactical"]["cell"]), int(enemy["tactical"]["cell"])): continue
			# Shallow copy: losses_detail/power_breakdown only read these fields, and a
			# deep copy also cloned intel, experience and decision_history every attack.
			var attacker: Dictionary = army.duplicate()
			attacker["units"] = army["units"].duplicate(true)
			attacker["ranged_attack"] = false
			attacker["melee_attack"] = separation == 1
			if separation > 1:
				attacker["units"] = {"infantry": 0, "archers": army["units"]["archers"], "cavalry": 0}
				attacker["ranged_attack"] = true
			var flank: bool = army["action"]["type"] == "flank" and bool(army["tactical"].get("flank_ready", false)) and row_of(int(army["tactical"]["cell"])) == row_of(int(enemy["tactical"]["cell"]))
			var pressure := contact_state(war, enemy)
			var multiplier := (_flank_num(war,"flank_attack",1.15) if flank else 1.0) * (_flank_num(war,"routing_target",1.25) if bool(enemy["returning"]) and separation <= 1 else 1.0) * (_flank_num(war,"exploiting_flanked",1.15) if bool(pressure["flanked"]) else 1.0) * Edges.attack_mult(war, army, enemy, separation <= 1)
			attacker["flanking_hit"] = flank or bool(pressure["flanked"])
			var terrain := terrain_class(enemy["tactical"]["cell"])
			# Each side fights from its own tile: the attacker's attack modifiers and the
			# defender's cover come from different ground.
			var origin := terrain_class(army["tactical"]["cell"])
			var hit := Combat.losses_detail(attacker, enemy, war.rules, terrain, war.rng.randf_range(0.9, 1.1) * multiplier / maxf(enemies.size(),1), 1.0, origin)
			var loss: int = int(hit["loss"])
			enemy["battle_factors"] = Feedback.factors(attacker, enemy, war.rules, terrain)
			if flank: Feedback.event(war, "侧击", army["name"] + "侧击" + enemy["name"], army["faction"])
			damages[enemy["id"]] = int(damages.get(enemy["id"], 0)) + loss
			if not dealt.has(army["id"]): dealt[army["id"]] = {}
			dealt[army["id"]][enemy["id"]] = float(dealt[army["id"]].get(enemy["id"], 0)) + loss
			if not personal_dealt.has(army["id"]): personal_dealt[army["id"]] = {}
			personal_dealt[army["id"]][enemy["id"]] = float(personal_dealt[army["id"]].get(enemy["id"], 0)) + loss * float(hit.get("personal_fraction", 0))
			if not attackers.has(enemy["id"]): attackers[enemy["id"]] = []
			attackers[enemy["id"]].append(army)
			if separation <= 1:
				if not melee_strikers.has(enemy["id"]): melee_strikers[enemy["id"]] = {}
				melee_strikers[enemy["id"]][army["id"]] = true
			army["combat_tick"] = war.state["tick"]
			army["combat_targets"].append(enemy["id"])
			army["tactical"]["attack_target"] = army["combat_targets"][0]
			army["tactical"]["phase"] = "近战" if separation <= 1 else "远射"
			if flank: army["tactical"]["phase"] = "侧击"
	# A unit being hit in melee counters unless it is withdrawing or ordered to ignore.
	# Contact may have moved into range after its order was chosen this morning.
	for id in damages.keys():
		var defender: Dictionary = war.state["armies"][id]
		if dealt.has(id) or defender["returning"] or not war.orders_for(defender)["engage"] or not can_attack(war, defender): continue
		var melee_attackers: Array = attackers.get(id, []).filter(func(a): return distance(defender,a) == 1)
		for attacker in melee_attackers:
			if distance(defender, attacker) > 1: continue
			# The counter-attack uses the same richness as the opening strike: its own
			# formation flank bonus, hitting a routing enemy, and exploiting a flanked one.
			var counter_pressure := contact_state(war, attacker)
			var counter_flank: bool = defender["action"]["type"] == "flank" and bool(defender["tactical"].get("flank_ready", false)) and row_of(int(defender["tactical"]["cell"])) == row_of(int(attacker["tactical"]["cell"]))
			var counter_multiplier := (_flank_num(war,"flank_attack",1.15) if counter_flank else 1.0) * (_flank_num(war,"routing_target",1.25) if bool(attacker["returning"]) else 1.0) * (_flank_num(war,"exploiting_flanked",1.15) if bool(counter_pressure["flanked"]) else 1.0) * Edges.attack_mult(war, defender, attacker, true)
			var counter: Dictionary = defender.duplicate()
			counter["units"] = defender["units"].duplicate(true)
			counter["melee_attack"] = true
			counter["ranged_attack"] = false
			counter["flanking_hit"] = counter_flank or bool(counter_pressure["flanked"])
			var hit := Combat.losses_detail(counter, attacker, war.rules, terrain_class(attacker["tactical"]["cell"]), war.rng.randf_range(0.9, 1.1) * counter_multiplier / maxf(melee_attackers.size(),1), 1.0, terrain_class(defender["tactical"]["cell"]))
			var loss: int = int(hit["loss"])
			damages[attacker["id"]] = int(damages.get(attacker["id"], 0)) + loss
			attacker["battle_factors"] = Feedback.factors(defender,attacker,war.rules,terrain_class(attacker["tactical"]["cell"]))
			if not dealt.has(id): dealt[id] = {}; personal_dealt[id] = {}
			dealt[id][attacker["id"]] = float(loss)
			personal_dealt[id][attacker["id"]] = loss * float(hit.get("personal_fraction", 0))
			if not attackers.has(attacker["id"]): attackers[attacker["id"]] = []
			attackers[attacker["id"]].append(defender)
			if not melee_strikers.has(attacker["id"]): melee_strikers[attacker["id"]] = {}
			melee_strikers[attacker["id"]][defender["id"]] = true
			defender["combat_tick"] = war.state["tick"]
			defender["combat_targets"].append(attacker["id"])
			defender["tactical"]["attack_target"] = defender["combat_targets"][0]
			defender["tactical"]["phase"] = "近战反击"
	# Commit losses after every attack has been calculated from the same state.
	for id in damages:
		var army: Dictionary = war.state["armies"][id]
		var dead_before := int(army.get("dead", 0))
		var loss := Combat.apply_loss(army, damages[id], false, 0.0, float(army.get("aura", 0.0)), aura_scale)
		var weights := {}
		var personal := {}
		for attacker_id in dealt:
			personal[attacker_id] = personal_dealt.get(attacker_id, {}).get(id, 0)
			if dealt[attacker_id].has(id): weights[attacker_id] = dealt[attacker_id][id]
		var strongest := 0.0
		for attacker_id in weights:
			if float(weights[attacker_id]) > strongest:
				strongest = float(weights[attacker_id])
				army["last_enemy_id"] = attacker_id
				army["last_enemy_tick"] = int(war.state["tick"])
		preload("res://scripts/war/campaign/officer_fate.gd").credit(war, weights, int(army["dead"]) - dead_before, {}, personal)
		Feedback.loss(war, army, loss)
		army["fatigue"] = minf(100, army["fatigue"] + Process.fatigue_cost(army, 4, true))
	# Send combat reports only after all simultaneous kill credits are committed.
	for id in damages:
		var army: Dictionary = war.state["armies"][id]
		var loss: int = int(army.get("daily_loss", 0))
		war._report(army, "战线交战", "%s在%s承受攻击，损失%d人。" % [army["name"], cell_text(int(army["tactical"]["cell"])) + "  " + Terrain.name_of(terrain_class(army["tactical"]["cell"])), loss], false)
	# Resolve morale once per unit from BOTH sides' exchange, before testing for rout.
	var participants := damages.duplicate()
	participants.merge(dealt)
	for id in participants:
		var unit: Dictionary = war.state["armies"][id]
		var inflicted := 0.0
		var opponent_before := 0.0
		for enemy_id in dealt.get(id, {}):
			inflicted += float(dealt[id][enemy_id]) * minf(1, float(before[enemy_id]) / maxf(float(damages.get(enemy_id, 0)), 1))
			opponent_before += before[enemy_id]
		var friendly := float(before[id])
		var hostile := 0.0
		for other in participants(war):
			if other["id"] == id or other["returning"] or not other.has("tactical") or distance(unit, other) > 3: continue
			if other["faction"] == unit["faction"]: friendly += before[other["id"]]
			elif unit["intel"]["enemies"].has(other["id"]): hostile += before[other["id"]]
		unit["combat_tick"] = war.state["tick"]
		Combat.battle_morale(unit, mini(int(damages.get(id, 0)), int(before[id])), inflicted, int(before[id]), opponent_before, friendly, hostile, contact_state(war, unit)["flanked"], float(unit.get("aura", 0.0)), aura_scale)
	for id in participants: war._check_rout(war.state["armies"][id])
	# A melee break opens the defender's tile; one surviving striker may follow in
	# on the map path. This happens after losses and routs are final, so the books
	# and the casualty ledger cannot change here.
	_resolve_breakthrough(war, melee_strikers, dealt)
	for id in dealt:
		var inflicted_day := 0.0
		for enemy_id in dealt[id]: inflicted_day += float(dealt[id][enemy_id])
		if inflicted_day > float(damages.get(id, 0)): war.state["armies"][id]["edge_advantage_tick"] = int(war.state["tick"])
	war._check_leader_lost()
	for id in attackers:
		if war.state["armies"][id]["returning"] or war.state["armies"][id]["status"] == "ended":
			for winner in attackers[id]: war._battle_victory(winner)
	if not war.state["battlefield"].has("winner"):
		var camps := {}
		for faction in war.state["battlefield"].get("sides", {}): camps[faction] = 0
		for army in participants(war):
			if not bool(army["returning"]): camps[army["faction"]] = int(camps.get(army["faction"], 0)) + Combat.strength(army)
		var remaining: Array = camps.keys().filter(func(faction): return int(camps[faction]) > 0)
		if remaining.size() <= 1:
			var winner := "draw" if remaining.is_empty() else str(remaining[0])
			var objectives: Dictionary = war.state["battlefield"].get("objectives", {})
			if remaining.is_empty() and not objectives.is_empty():
				var holders := {}
				for node in objectives:
					var city: Dictionary = war.store.city_state(node)
					if int(city.get("garrison",0)) > 0: holders[str(city.get("faction",""))] = true
				if holders.size() == 1: winner = str(holders.keys()[0])
			var unfinished: bool = objectives.keys().any(func(node): return winner != "draw" and war.store.city_state(node)["faction"] != winner)
			if unfinished:
				# The field is decided but the objectives are not: record it so the report can
				# say the field was won while the siege is still running, then wait for the
				# attacker to take the city.
				war.state["battlefield"]["field_winner"] = winner
				war.state["battlefield"]["field_winner_at"] = int(war.state["tick"])
				return
			war.state["battlefield"]["winner"] = winner
			war.state["battlefield"]["ended_at"] = war.state["tick"]
			for army in war.state["armies"].values():
				if army["faction"] == "liu_bei":
					war._report(army, "战局结果", "双方均已脱离战场。" if winner == "draw" else "%s控制战场，对方部队已撤退或覆没。" % ("我军" if winner == "liu_bei" else "敌军"), true)
					break
