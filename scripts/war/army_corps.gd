extends RefCounted

const Combat = preload("res://scripts/war/combat_system.gd")
const Tactical = preload("res://scripts/war/tactical_battlefield.gd")
const Edges = preload("res://scripts/war/officer_edges.gd")
const Forecast = preload("res://scripts/agents/forecast.gd")
const Policy = preload("res://scripts/agents/baseline_policy.gd")
const Structure = preload("res://scripts/war/corps_structure.gd")
const Autonomy = preload("res://scripts/agents/officer_autonomy.gd")
const STAFF_ROLE := "参军"
const TASKS := {"command": "中军统筹", "support": "弓兵支援", "main_attack": "正面进攻", "flank": "侧翼包抄", "reserve": "预备待命", "rear_guard": "掩护撤退", "raid_rear": "绕后奇袭", "cut_supply": "截断粮道", "regroup": "归建"}

static func suitability(officer: Dictionary, position: String) -> float:
	var text: String = officer.get("positions", "")
	var value := 40.0
	for line in text.split("\n"):
		if not line.contains(position): continue
		if line.begins_with("核心位置"): value = 100
		elif line.begins_with("次选位置"): value = 75
		elif line.begins_with("不宜位置"): value = 10
		else: continue
		var regex := RegEx.new()
		regex.compile(position + "\\s*(\\d{1,3})")
		var found := regex.search(line)
		if found != null: value = float(found.get_string(1))
	var skills: Dictionary = officer.get("skills", {})
	return value + float(skills.get("奇袭" if position == "奇兵" else "智计" if position in ["军师", "参军"] else "带兵", 50)) * 0.5 + float(skills.get("料敌" if position == "参军" else "治军" if position == "护军" else "布阵", 50)) * 0.25

static func best_member(war, members: Array, position: String) -> String:
	var sorted: Array = members.duplicate()
	sorted.sort_custom(func(a, b): return suitability(war.roster.officers[a], position) > suitability(war.roster.officers[b], position) if not is_equal_approx(suitability(war.roster.officers[a], position), suitability(war.roster.officers[b], position)) else str(a) < str(b))
	return str(sorted[0]) if not sorted.is_empty() else ""

# Select by role rather than roster order. One person can occupy only one slot.
static func select_members(war, commander: String, candidates: Array, home: String = "") -> Array:
	var free: Array = []
	if not war.roster.officers.has(commander): return []
	for value in candidates:
		var id := str(value)
		if id == commander or free.has(id) or not war.roster.officers.has(id): continue
		if war.roster.officers[id]["faction"] != war.roster.officers[commander]["faction"]: continue
		if war.state["officer_states"].get(id, {}).get("status", "available") != "available": continue
		if home != "" and war.Operations.assembly_days(war, home, [id]) < 0: continue
		free.append(id)
	return free

static func preview_appointments(war, commander: String, members: Array, strength: int, plan: Dictionary = {}) -> Dictionary:
	var free: Array = select_members(war, commander, members)
	if not plan.is_empty():
		var normalized: Dictionary = Structure.normalize_plan(war, commander, [commander] + free, plan, strength)
		var formations: Array = [{"officer": commander, "task": "command", "strength": normalized["strengths"][commander]}]
		for officer in free:
			var count: int = int(normalized["strengths"].get(officer, 0))
			if count > 0: formations.append({"officer": officer, "task": task_for_role(str(normalized["roles"][officer])), "strength": count})
		return {"appointments": normalized["roles"], "formations": formations, "command_tree": normalized["parents"], "node_strength": normalized["strengths"]}
	var positions: Dictionary = {commander: "主帅"}
	var formations: Array = []
	var staff: String = best_member(war, free, "参军")
	if staff != "": positions[staff] = "参军"; free.erase(staff)
	var remaining: int = strength
	var index: int = 0
	for officer in free:
		var role: String = "前锋" if index < 2 else "护军" if index < 4 else "随军"
		positions[officer] = role
		var count: int = int(strength * (0.27 if role == "前锋" else 0.13)) if index < 4 else 0
		if count >= Structure.MIN_TROOP and remaining - count >= Structure.MIN_TROOP:
			formations.append({"officer": officer, "task": "main_attack" if role == "前锋" else "flank" if index == 2 else "reserve", "strength": count})
			remaining -= count
		index += 1
	formations.push_front({"officer": commander, "task": "command", "strength": remaining})
	return {"appointments": positions, "formations": formations}

static func task_for_role(role: String) -> String:
	match Structure.behavior_of(role):
		"command": return "command"
		"staff": return "support"
		"front": return "main_attack"
		"guard": return "reserve"
	return "main_attack"

static func validate_plan(war, commander: String, members: Array, plan: Dictionary, strength: int) -> Dictionary:
	return Structure.validate_plan(commander, [commander] + select_members(war, commander, members), plan, strength)

static func form(war, root: Dictionary, members: Array, autonomous: bool = false) -> Dictionary:
	var id: String = "corps-" + root["id"]
	var joined: Array = [root["officer_id"]] + select_members(war, root["officer_id"], members, str(root["home"]))
	var player_plan: Dictionary = war.state.get("pending_corps_plan", {})
	if str(player_plan.get("commander", "")) != str(root["officer_id"]): player_plan = {}
	var layout := preview_appointments(war, root["officer_id"], joined, Combat.strength(root), player_plan)
	if not player_plan.is_empty():
		autonomous = false
		war.state.erase("pending_corps_plan")
	var old_departure := int(root.get("departure_at", war.state["tick"]))
	root["departure_at"] = maxi(old_departure, int(war.state["tick"]) + war.Operations.assembly_days(war, str(root["home"]), joined))
	root["deadline"] += int(root["departure_at"]) - old_departure
	for officer in joined: war.Operations.detach_post(war, str(officer))
	var corps := {"id": id, "name": war.roster.officers[root["officer_id"]]["name"] + "军", "faction": root["faction"], "root_id": root["id"], "commander_id": root["officer_id"], "members": joined, "appointments": {root["officer_id"]: "主帅"}, "units": [root["id"]], "last_plan": -10, "orders": [], "known_supplies": {}, "supply": {"stock": 0.0, "blocked_until": 0, "cell": -1}}
	war.state["corps"][id] = corps
	corps["leader_lost"] = false
	corps["leader_lost_for"] = ""
	corps["siege_mode"] = "assault" if not war.supply_enabled() else "blockade"
	root["corps_id"] = id
	root["corps_task"] = {"type": "command", "reason": "主帅坐镇中军，统筹全军", "issued_by": root["officer_id"]}
	root["name"] = war.roster.officers[root["officer_id"]]["name"] + "中军"
	for officer in joined: war.state["officer_states"][officer] = {"status": "deployed", "army_id": root["id"], "corps_id": id}
	corps["appointments"] = layout["appointments"]
	corps["composition_version"] = Structure.STRUCTURE_VERSION
	corps["command_tree"] = layout.get("command_tree", {})
	corps["node_strength"] = layout.get("node_strength", {})
	corps["player_composition"] = not player_plan.is_empty()
	Structure.ensure(corps)
	corps["autonomous_deployment"] = autonomous
	corps["formed_at"] = int(war.state["tick"])
	if autonomous: return corps
	for formation in layout["formations"]:
		if formation["officer"] == root["officer_id"]: continue
		split(war, corps, root, formation["officer"], formation["strength"], formation["task"], -1)
	corps["deployed"] = true
	if corps["units"].size() == 1: root["corps_task"]["type"] = "main_attack"
	return corps

static func deploy_by_commander(war, corps: Dictionary, posture: String, reason: String) -> Dictionary:
	if not corps.get("autonomous_deployment", false) or corps.get("deployed", false): return {"ok": false, "message": "军团已经展开"}
	if posture not in ["balanced", "assault", "flanking"]: return {"ok": false}
	var root: Dictionary = war.state["armies"][corps["root_id"]]
	if root["status"] == "ended" or root["returning"]: return {"ok": false}
	if root.has("tactical") and Tactical.contact_state(war, root)["adjacent_enemies"] > 0: return {"ok": false, "message": "接战中不能展开分兵"}
	var active_officers: Array = corps["units"].filter(func(id): return war.state["armies"][id]["status"] != "ended").map(func(id): return war.state["armies"][id]["officer_id"])
	var free: Array = corps["members"].filter(func(id): return not active_officers.has(id) and not Structure.is_staff(str(corps["appointments"].get(id, ""))) and not war.state["officer_states"].get(id, {}).get("lost", false) and not war.state["officer_states"].get(id, {}).get("duel_wounded",false))
	var before := Combat.strength(root)
	var front_share := 0.30 if posture == "assault" else 0.25 if posture == "flanking" else 0.27
	var flank_share := 0.20 if posture == "flanking" else 0.10 if posture == "assault" else 0.13
	var created := []
	for officer in free:
		Autonomy.ensure_evaluated(war, corps, str(officer), {"action": {"type": "deploy_corps"}, "reason": reason})
		if Autonomy.blocks_override(war, corps, str(officer)).get("blocked", false): continue
		var role: String = str(corps["appointments"].get(officer, "随军"))
		var behavior: String = Structure.behavior_of(role)
		var share: float = front_share if behavior == "front" else flank_share if behavior == "guard" else 0.13
		var count: int = mini(int(before * share), Combat.strength(root) - Structure.MIN_TROOP)
		if count < Structure.MIN_TROOP: continue
		var task: String = task_for_role(role)
		if behavior == "guard": task = "flank" if not created.is_empty() and created.size() % 2 == 0 else "reserve"
		var result: Dictionary = split(war, corps, root, str(officer), count, task, -1)
		if result.get("ok", false):
			var child: Dictionary = war.state["armies"][result["army_id"]]
			child["corps_task"]["reason"] = reason
			child["corps_task"]["issued_at"] = int(war.state["tick"])
			created.append(result["army_id"])
	if created.is_empty():
		if free.is_empty() or before < Structure.MIN_TROOP * 2:
			corps["deployed"] = true
			root["corps_task"]["type"] = "main_attack"
			return {"ok": true, "units": [], "message": "缺员或兵力不足，主帅率中军执行任务"}
		return {"ok": false, "message": "没有可展开的将领、兵力或相邻格"}
	root["corps_task"]["type"] = "command"
	root["name"] = war.roster.officers[root["officer_id"]]["name"] + "中军"
	corps["deployed"] = true
	if war.store.battle_test and corps.has("battle_troop_profile"):
		preload("res://scripts/war/battle_scenarios.gd").compose_corps(war,corps,corps["battle_troop_profile"])
	corps["deployment_posture"] = posture
	war._report(root, "主帅分兵", "%s下令展开军团，派出%d支分队，中军保留%d人。" % [root["name"], created.size(), Combat.strength(root)], false)
	return {"ok": true, "units": created}

static func split(war, corps: Dictionary, source: Dictionary, officer: String, count: int, task: String, target: int) -> Dictionary:
	if war.active_armies().any(func(army): return army["officer_id"] == officer): return {"ok": false, "message": "该将领已有在役部队"}
	if not war.supply_enabled() and task == "cut_supply": return {"ok": false, "message": "粮草系统已停用"}
	if source.get("corps_id", "") != corps["id"] or source.get("status", "ended") == "ended" or source.get("returning", false) or not TASKS.has(task): return {"ok": false, "message": "不能从此部队拆分"}
	if task in ["raid_rear", "cut_supply"] and (Tactical.board_for(war, source).is_empty() or not Tactical.in_battlefield(Tactical.board_for(war, source), target)): return {"ok": false, "message": "目标格无效"}
	if war.state["officer_states"].get(officer, {}).get("corps_id", "") != corps["id"] or war.state["officer_states"].get(officer, {}).get("lost", false) or war.state["officer_states"].get(officer, {}).get("duel_wounded", false): return {"ok": false, "message": "该将领不在本军团或正在养伤"}
	if not corps["members"].has(officer) or officer == corps["commander_id"] or count < 500 or Combat.strength(source) - count < 500: return {"ok": false, "message": "人员或可拆兵力不足"}
	for unit_id in corps["units"]:
		var unit: Dictionary = war.state["armies"][unit_id]
		if unit["status"] != "ended" and unit["officer_id"] == officer: return {"ok": false, "message": "该将领已有分队"}
	var cell := -1
	if source.has("tactical"):
		if Tactical.contact_state(war, source)["adjacent_enemies"] > 0: return {"ok": false, "message": "接战中不能拆队绕过包围"}
		var board: Dictionary = Tactical.board_for(war, source)
		var occupied := {}
		for army in war.active_armies():
			if army.has("tactical"): occupied[int(army["tactical"]["cell"])] = true
		var start: int = source["tactical"]["cell"]
		var forward := -Tactical.side_for(board, str(source["faction"]))
		var desired := Tactical.cell_at(Tactical.column_of(start) + (-1 if task == "flank" else 1 if task == "reserve" else 0), Tactical.row_of(start) + (-forward if task == "reserve" else forward))
		var options: Array = Array(Tactical.neighbors(start))
		options.sort_custom(func(a, b): return Tactical.cell_distance(a, desired) < Tactical.cell_distance(b, desired))
		for option in options:
			if Tactical.can_enter(war, source, option) and not occupied.has(option): cell = option; break
		if cell < 0: return {"ok": false, "message": "没有可展开的相邻格"}
	var before := Combat.strength(source)
	var child: Dictionary = source.duplicate(true)
	child.erase("battle_ai")
	if source.has("battle_ai"):
		source["battle_ai"]["actor_revision"] += 1
		source["battle_ai"]["plan"] = {}
		war.planner.invalidate("unit:"+str(source["id"]))
	var id := "army-%04d" % int(war.state["next_id"])
	war.state["next_id"] += 1
	child.merge({"id": id, "officer_id": officer, "name": war.roster.officers[officer]["name"] + "分队", "skills": war.roster.officers[officer]["skills"].duplicate(true), "trait_ids": war.roster.officers[officer].get("trait_ids", []).duplicate(), "battle_contacts": [], "victory_chain": false, "opening_used": false, "units": {"infantry": 0, "archers": 0, "cavalry": 0}, "initial_strength": count, "enemy_killed": 0, "personal_soldier_kills": 0, "dead": 0, "wounded": 0, "captured": 0, "deposited": 0, "returning": false, "status": "active", "last_decision": -10, "last_report": {}, "last_reason": "奉主帅命令展开分队", "operation": {}, "decision_history": [], "memory": [], "action": {"type": "hold"}, "corps_task": {"type": task, "cell": target, "reason": TASKS.get(task, task), "issued_by": Structure.tree_parent(corps, officer)}}, true)
	var left := count
	for type in Combat.TYPES:
		var take: int = mini(int(source["units"][type]), int(count * float(source["units"][type]) / before))
		child["units"][type] = take
		left -= take
	for type in Combat.TYPES:
		var take: int = mini(left, int(source["units"][type]) - int(child["units"][type]))
		child["units"][type] += take
		left -= take
	for type in Combat.TYPES: source["units"][type] -= child["units"][type]
	source["initial_strength"] -= count
	child["grain"] = float(source["grain"]) * count / before
	source["grain"] -= child["grain"]
	child.erase("returned_strength")
	child["siege_engines"] = 0
	child["wounded_units"] = {"infantry": 0, "archers": 0, "cavalry": 0}
	child.erase("objective_complete")
	child["outcome"] = ""
	child.erase("combat_tick")
	# A detachment has its own officer and first contact history.
	for field in ["first_melee_tick", "first_contact_effect_tick", "duel_tick", "duel_opponent", "duel_wounded", "daily_loss", "daily_loss_tick", "battle_factors", "aura", "incoming_shock", "morale_shock", "edge_attack", "edge_defense", "edge_active", "edge_advantage_tick"]: child.erase(field)
	child["edge"] = Edges.ensure(child, war.roster.officers.get(officer, {}), true)
	child["decision_key"] = ""
	if cell >= 0: child["tactical"] = {"cell": cell, "role": task, "lane": Tactical.column_of(cell), "phase": "展开", "blocked": false, "blocked_days": 0, "attack_target": "", "withdraw_preparation": 0}
	war.state["armies"][id] = child
	war.state["missions"][id] = {"army_id": id, "status": "active", "officer_id": officer, "home": child["home"], "target": child["target"], "type": "detachment", "result": ""}
	corps["units"].append(id)
	Structure.ensure(corps)
	corps["node_strength"][officer] = count
	corps["node_strength"][source["officer_id"]] = Combat.strength(source)
	war.state["officer_states"][officer] = {"status": "deployed", "army_id": id, "corps_id": corps["id"]}
	return {"ok": true, "army_id": id}

# Which observed enemy this unit should be pointed at. Corps units had a hard-coded
# empty suggested_target, which silently disabled three scoring levers (接战勇气,
# target_value.suggested and the tolerance personality term) for every fielded army,
# since every dispatched corps creates units. Spread assignments around the plan tick
# so a corps does not send every detachment at the same target.
static func _suggest_target(war, unit: Dictionary, plan_tick: int) -> String:
	var observed: Array = []
	for record in unit.get("intel", {}).get("enemies", {}).values():
		if bool(record.get("routing", false)): continue
		observed.append(record)
	if observed.is_empty(): return ""
	if not unit.has("tactical"):
		observed.sort_custom(func(a, b): return str(a["id"]) < str(b["id"]))
		return str(observed[absi(plan_tick) % observed.size()]["id"])
	var cell := int(unit["tactical"]["cell"])
	# An enemy with no recorded cell is unknown, not adjacent: cell_distance against -1
	# returns a meaningless value, so rank those last by id.
	observed.sort_custom(func(a, b):
		var a_cell := int(a.get("tactical_cell", -1))
		var b_cell := int(b.get("tactical_cell", -1))
		if (a_cell < 0) != (b_cell < 0): return a_cell >= 0
		if a_cell < 0: return str(a["id"]) < str(b["id"])
		var left := Tactical.cell_distance(cell, a_cell)
		var right := Tactical.cell_distance(cell, b_cell)
		return left < right if left != right else str(a["id"]) < str(b["id"]))
	return str(observed[0]["id"])


static func summary(war, corps: Dictionary) -> Dictionary:
	var total := 0
	var units: Array = []
	for id in corps["units"]:
		var army: Dictionary = war.state["armies"][id]
		if army["status"] == "ended": continue
		total += Combat.strength(army)
		units.append({"id": id, "officer": army["name"], "strength": Combat.strength(army), "morale": army["morale"], "organization": army["organization"], "fatigue": army["fatigue"], "grain_days": int(war.food_days(army)), "task": army["corps_task"], "cell": army.get("tactical", {}).get("cell", -1), "returning": army["returning"], "units": army["units"].duplicate(true), "siege_engines": army.get("siege_engines",0)})
	return {"id": corps["id"], "name": corps["name"], "strength": total, "units": units, "appointments": corps["appointments"], "composition": {"unlimited": true, "roles": corps["appointments"].values(), "command_tree": corps.get("command_tree", {}).duplicate(true), "node_strength": corps.get("node_strength", {}).duplicate(true)}, "supply": corps["supply"].duplicate(true), "known_supplies": corps["known_supplies"].duplicate(true), "deployment_pending": corps.get("autonomous_deployment", false) and not corps.get("deployed", false)}

static func deploy(war) -> void:
	var board: Dictionary = war.state["battlefield"]
	var global_occupied := {}
	for corps in war.state["corps"].values():
		var side := Tactical.side_for(board, str(corps["faction"]))
		var rank := 0
		var desired: Array = []
		for id in corps["units"]:
			var unit: Dictionary = war.state["armies"][id]
			var task: String = unit["corps_task"]["type"]
			var dq := 0
			var dr := side * 6
			if corps.get("autonomous_deployment", false): dr = side * 3
			if task == "main_attack": dq = -1 if rank == 0 else 1; dr = side * 2; rank += 1
			elif task == "flank": dq = -4; dr = side * 3
			elif task == "support": dq = 1; dr = side * 4
			elif task == "reserve": dq = 2; dr = side * 5
			var layout: Array = board.get("side_deployment", {}).get(corps["faction"], board.get("scenario_deployment", []))
			var slot: int = unit.get("scenario_slot", 0)
			if not layout.is_empty() and slot < layout.size(): dq = int(layout[slot][0]); dr = side * int(layout[slot][1])
			if slot == 0 and corps.get("autonomous_deployment", false) and not corps.get("deployed", false): dr = side * 3
			desired.append({"unit": unit, "cell": Tactical.offset_cell(board, dq, dr)})
		var occupied := {}
		for entry in desired:
			var options: Array = []
			for q in range(-7, 8):
				for r in range(-8, 9):
					if r * side <= 0: continue
					var cell := Tactical.offset_cell(board, q, r)
					if Tactical.can_enter(war, entry["unit"], cell) and not occupied.has(cell) and not global_occupied.has(cell) and (not board.has("deployment_cells") or board["deployment_cells"].has(cell)): options.append(cell)
			options.sort_custom(func(a, b): return Tactical.cell_distance(a, entry["cell"]) < Tactical.cell_distance(b, entry["cell"]))
			if options.is_empty(): continue
			var cell: int = options[0]
			occupied[cell] = true
			global_occupied[cell] = true
			entry["unit"]["tactical"].merge({"cell": cell, "lane": Tactical.column_of(cell), "role": entry["unit"]["corps_task"]["type"]}, true)
		var supply_options: Array = []
		for q in range(-6, 7):
			for r in range(-8, 9):
				if r * side <= 5: continue
				var cell := Tactical.offset_cell(board, q, r)
				if not board["blocked"].has(cell) and not occupied.has(cell): supply_options.append(cell)
		var supply_anchor := Tactical.offset_cell(board, 0, side * 8)
		supply_options.sort_custom(func(a, b): return Tactical.cell_distance(a, supply_anchor) < Tactical.cell_distance(b, supply_anchor))
		corps["supply"]["cell"] = supply_options[0] if not supply_options.is_empty() else int(war.state["armies"][corps["root_id"]]["tactical"]["cell"])
		for id in corps["units"]:
			var unit: Dictionary = war.state["armies"][id]
			var excess := maxf(0, float(unit["grain"]) - war.daily_food(unit) * 7) if war.supply_enabled() else 0.0
			unit["grain"] -= excess
			corps["supply"]["stock"] += excess

static func commander_context(war, corps: Dictionary) -> Dictionary:
	Structure.ensure(corps)
	Autonomy.evaluate_corps(war, corps)
	var root: Dictionary = war.state["armies"][corps["root_id"]]
	var context: Dictionary = war.context_for(root)
	context["level"] = "commander"
	context["battle_objective"] = Tactical.board_for(war, root).get("control_point", {}).duplicate(true)
	context["objective_text"] = Tactical.board_for(war, root).get("objective_text", "")
	context["staff_advice"] = staff_advice(war, corps)
	context["officer_advice"] = preload("res://scripts/agents/officer_brain.gd").advice(war,corps)
	context["siege"] = war.state.get("sieges", {}).get(root["target"], {}).duplicate(true)
	context["corps"] = summary(war, corps)
	if not war.supply_enabled() and not context["siege"].is_empty(): context["siege"]["grain_days"] = 999
	context["withdraw_hysteresis"] = bool(corps.get("withdraw_hysteresis", false))
	context["members"] = []
	context["autonomy"] = Autonomy.summary_rows(war, corps)
	var known_enemies := {}
	for unit_id in corps["units"]:
		var unit: Dictionary = war.state["armies"][unit_id]
		if unit["status"] == "ended": continue
		if war.rules.get("battle_ai",{}).get("mode","active") == "active" and unit_id != root["id"] and (not unit.has("tactical") or not root.has("tactical") or Tactical.distance(root,unit) > 3): continue
		for enemy in unit["intel"]["enemies"].values():
			if not known_enemies.has(enemy["id"]) or int(enemy["observed_at"]) > int(known_enemies[enemy["id"]]["observed_at"]): known_enemies[enemy["id"]] = enemy
	var enemy_list: Array = known_enemies.values()
	enemy_list.sort_custom(func(a, b): return str(a["id"]) < str(b["id"]))
	context["enemies"] = enemy_list
	context["army"]["strength"] = context["corps"]["strength"]
	context["allies"] = []
	var enemy_strength := 0
	for enemy in context["enemies"]:
		if not enemy.get("routing", false) and int(war.state["tick"]) - int(enemy["observed_at"]) <= 3: enemy_strength += int(enemy["strength_estimate"])
	var ready := 0
	for unit in context["corps"]["units"]:
		if not unit["returning"] and unit["organization"] >= 20 and unit["morale"] >= 25: ready += int(unit["strength"])
	context["battlefield"] = {"friendly_ready_strength": ready, "enemy_estimated_strength": enemy_strength, "enemy_to_friendly_ratio": float(enemy_strength) / maxf(ready, 1)}
	for id in corps["members"]:
		var member: Dictionary = war.roster.officers[id]
		context["members"].append({"id": id, "name": member["name"], "position": corps["appointments"][id], "aptitude": member.get("positions", ""), "skills": member["skills"], "personality": member["personality"], "parent": Structure.tree_parent(corps, str(id)), "stance": Autonomy.stance_of(corps, str(id)).get("stance", "obey"), "stance_reason": Autonomy.stance_of(corps, str(id)).get("reason", "")})
	context["candidates"] = [{"id": "maintain", "action": {"type": "maintain"}, "description": "保持当前军团部署"}]
	if context["corps"]["deployment_pending"]:
		context["deployment_age"] = int(war.state["tick"]) - int(corps.get("formed_at", 0))
		for posture in ["balanced", "assault", "flanking"]:
			context["candidates"].append({"id": "deploy:" + posture, "action": {"type": "deploy_corps", "posture": posture}, "description": "主帅按现有编制展开军团：" + {"balanced": "双前锋、侧翼护军、预备护军", "assault": "加强双前锋，保留预备队", "flanking": "双前锋牵制、加强侧翼"}[posture]})
	context["terrain"] = Tactical.terrain_class(root["tactical"]["cell"]) if root.has("tactical") else war._terrain(root["location"]["node"])
	context["unit_mix"] = {"infantry":0,"archers":0,"cavalry":0}
	context["enemy_unit_mix_estimate"] = {"infantry":0,"archers":0,"cavalry":0}
	for enemy in context["enemies"]:
		if int(war.state["tick"]) - int(enemy["observed_at"]) > 3: continue
		for type in Combat.TYPES: context["enemy_unit_mix_estimate"][type] += enemy.get("unit_mix_estimate",{}).get(type,0)
	for id in corps["units"]:
		var unit: Dictionary = war.state["armies"][id]
		if unit["status"] != "ended":
			for type in Combat.TYPES: context["unit_mix"][type] += unit["units"][type]
	var initial := 0
	for id in corps["units"]: initial += int(war.state["armies"][id].get("initial_strength", 0))
	var retreat_line: Dictionary = war.orders_for(root).get("retreat_line", {})
	var line_reached: bool = float(retreat_line.get("strength", 0)) > 0 and float(context["corps"]["strength"]) / maxf(initial, 1) <= float(retreat_line["strength"])
	var all_morale := 0.0
	for unit in context["corps"]["units"]: all_morale += float(unit["morale"]) * int(unit["strength"])
	var morale_average := all_morale / maxf(context["corps"]["strength"], 1)
	if float(retreat_line.get("morale", 0)) > 0 and morale_average <= float(retreat_line["morale"]): line_reached = true
	context["corps"]["initial_strength"] = initial
	context["corps"]["morale_average"] = morale_average
	var outnumbered: bool = float(context["battlefield"]["enemy_to_friendly_ratio"]) > 2.5
	var broken: bool = enemy_strength > ready and ready < int(context["corps"]["strength"]) * 0.55
	var supply_crisis: bool = war.supply_enabled() and float(context["army"].get("grain_days", 10)) < 2
	var assault_ready := 0
	for unit in context["corps"]["units"]:
		if not unit["returning"] and unit["task"]["type"] != "command" and float(unit["morale"]) >= 25 and float(unit["organization"]) >= 20:
			assault_ready += int(unit.get("units",{}).get("infantry",0))
	var siege_stalled: bool = corps.get("siege_approach",false) and float(context["siege"].get("wall",0)) > 0 and assault_ready < 500
	# Headquarters can remain healthy after every field formation has been lost.
	# Its own morale and expired enemy sightings cannot justify waiting forever.
	var field_lost: bool = corps.get("deployed", false) and corps["units"].size() > 1 and float(context["corps"]["strength"]) < initial * 0.5 and not context["corps"]["units"].any(func(u): return u["id"] != corps["root_id"] and not u["returning"])
	var retreat_needed: bool = outnumbered or broken or supply_crisis or line_reached or siege_stalled or field_lost
	context["retreat_assessment"] = {"allowed": retreat_needed, "reason": "达到玩家撤退线" if line_reached else "可战兵力明显劣势" if outnumbered else "全军战线崩溃" if broken else "补给危急" if supply_crisis else "攻城步兵不足" if siege_stalled else "前军覆没，失去作战分队" if field_lost else "全军仍可作战，优先轮换与整顿"}
	if war.orders_for(root)["retreat"] and retreat_needed: context["candidates"].append({"id": "withdraw_corps", "action": {"type": "withdraw_corps"}, "description": "全军有序撤退"})
	if not context["siege"].is_empty() and context["siege"].get("attacker", "") == corps["faction"] and context["siege"].get("phase", "") not in ["occupied", "解围"]:
		for mode in (["assault", "blockade"] if war.supply_enabled() else ["assault"]):
			if corps.get("siege_mode", "assault") != mode: context["candidates"].append({"id": "siege:" + mode, "action": {"type": "set_siege_mode", "mode": mode}, "description": "强攻破墙" if mode == "assault" else "围困等待守军断粮"})
	var front_count := 0
	var raids_active: int = context["corps"]["units"].filter(func(u): return not u["returning"] and u["task"].get("independent", false)).size()
	var needs_guard: bool = context["corps"]["units"].any(func(u): return u["returning"])
	var has_guard: bool = context["corps"]["units"].any(func(u): return not u["returning"] and u["task"]["type"] == "rear_guard")
	for id in corps["units"]:
		var unit: Dictionary = war.state["armies"][id]
		if unit["status"] != "ended" and not unit["returning"] and unit["corps_task"]["type"] == "main_attack": front_count += 1
	for id in corps["units"]:
		var unit: Dictionary = war.state["armies"][id]
		if id == corps["root_id"] or unit["status"] == "ended" or unit["returning"]: continue
		for task in ["main_attack", "support", "flank", "reserve", "rear_guard", "regroup"]:
			if task == unit["corps_task"]["type"]: continue
			if task == "rear_guard" and (not needs_guard or has_guard): continue
			if task == "regroup" and float(unit["morale"]) >= 45 and float(unit["organization"]) >= 45 and float(unit["fatigue"]) < 60: continue
			if front_count <= 1 and unit["corps_task"]["type"] == "main_attack" and task in ["support", "flank", "reserve", "rear_guard"]: continue
			if int(war.state["tick"]) - int(unit["corps_task"].get("issued_at", -10)) < 3 and task not in ["rear_guard", "regroup"]: continue
			context["candidates"].append({"id": "order:%s:%s" % [id, task], "action": {"type": "assign_task", "unit": id, "task": task}, "description": "%s执行%s" % [unit["name"], TASKS[task]]})
		if raids_active == 0 and unit["corps_task"]["type"] != "reserve" and unit.has("tactical") and Tactical.contact_state(war, unit)["adjacent_enemies"] == 0 and not (front_count <= 1 and unit["corps_task"]["type"] == "main_attack") and int(war.state["tick"]) - int(unit["corps_task"].get("issued_at", -10)) >= 3:
			for enemy in context["enemies"].slice(0, 1):
				var rear := rear_cell(war, corps, enemy)
				if rear >= 0: context["candidates"].append({"id": "order-raid:" + id, "action": {"type": "assign_task", "unit": id, "task": "raid_rear", "cell": rear}, "description": "现有%s独立绕后" % unit["name"]})
			for enemy_id in (corps["known_supplies"] if war.supply_enabled() else {}):
				context["candidates"].append({"id": "order-supply:%s:%s" % [id, enemy_id], "action": {"type": "assign_task", "unit": id, "task": "cut_supply", "cell": corps["known_supplies"][enemy_id]["cell"], "enemy_corps": enemy_id}, "description": "派现有%s截断已发现粮道" % unit["name"]})
	var rotation: Dictionary = Policy.weights().get("commander", {}).get("rotate", {})
	for front in context["corps"]["units"]:
		if front["returning"] or front["task"]["type"] != "main_attack" or (float(front["morale"]) >= float(rotation.get("morale", 50)) and float(front["organization"]) >= float(rotation.get("organization", 50)) and float(front["fatigue"]) < float(rotation.get("fatigue", 60))): continue
		for reserve in context["corps"]["units"]:
			if reserve["returning"] or reserve["task"]["type"] != "reserve" or float(reserve["morale"]) < 55 or float(reserve["organization"]) < 50: continue
			context["candidates"].append({"id": "rotate:" + front["id"], "action": {"type": "rotate_front", "front": front["id"], "reserve": reserve["id"]}, "description": "%s接替疲惫前锋%s，旧前锋先脱离再归建休整" % [reserve["officer"], front["officer"]]})
	var free: Array = corps["members"].filter(func(officer):
		if officer == corps["commander_id"] or war.state["officer_states"].get(officer, {}).get("lost", false) or war.state["officer_states"].get(officer, {}).get("duel_wounded",false): return false
		for id in corps["units"]:
			if war.state["armies"][id]["status"] != "ended" and war.state["armies"][id]["officer_id"] == officer: return false
		return true
	)
	var raider := best_member(war, free, "奇兵")
	# After the initial deployment the commander can request a specific officer,
	# source and troop count, rather than only re-labeling existing formations.
	if not context["corps"]["deployment_pending"]:
		for task in ["main_attack", "flank", "reserve"]:
			var officer := best_member(war, free, "前锋" if task == "main_attack" else "奇兵" if task == "flank" else "护军")
			if officer == "": continue
			for source_id in corps["units"]:
				var source: Dictionary = war.state["armies"][source_id]
				if source["status"] == "ended" or source["returning"] or (source.has("tactical") and Tactical.contact_state(war, source)["adjacent_enemies"] > 0): continue
				var count := mini(3000, int(Combat.strength(source) * 0.25))
				if count < 500 or Combat.strength(source) - count < 500: continue
				context["candidates"].append({"id": "detach:%s:%s" % [source_id, task], "action": {"type": "detach", "source": source_id, "officer": officer, "strength": count, "task": task, "cell": -1}, "description": "从%s分出%d人，由%s执行%s" % [source["name"], count, war.roster.officers[officer]["name"], TASKS[task]]})
	if raids_active == 0 and raider != "" and root.has("tactical") and not context["corps"].get("deployment_pending", false):
		for source_id in corps["units"]:
			var source: Dictionary = war.state["armies"][source_id]
			if source["status"] == "ended" or source["returning"] or Tactical.contact_state(war, source)["adjacent_enemies"] > 0: continue
			for count in [500, 1000, 2000]:
				if Combat.strength(source) - count < 500: continue
				if source["corps_task"]["type"] == "reserve": continue
				if source_id == corps["root_id"] and Combat.strength(source) - count < maxi(1000, int(context["corps"]["strength"] * 0.08)): continue
				for enemy in context["enemies"].slice(0, 1):
					var rear := rear_cell(war, corps, enemy)
					if rear < 0: continue
					context["candidates"].append({"id": "raid:%s:%d" % [source_id, count], "action": {"type": "detach", "source": source_id, "officer": raider, "strength": count, "task": "raid_rear", "cell": rear}, "description": "拆出%d人，由%s绕后奇袭" % [count, war.roster.officers[raider]["name"]]})
				for enemy_id in (corps["known_supplies"] if war.supply_enabled() else {}):
					context["candidates"].append({"id": "supply:%s:%d:%s" % [source_id, count, enemy_id], "action": {"type": "detach", "source": source_id, "officer": raider, "strength": count, "task": "cut_supply", "cell": corps["known_supplies"][enemy_id]["cell"], "enemy_corps": enemy_id}, "description": "拆出%d人截断已发现的敌军粮道" % count})
	var prepare := int(Tactical.contact_state(war, root).get("required_preparation", 0)) if root.has("tactical") else 0
	var orders: Dictionary = war.orders_for(root)
	context["orders"] = orders
	context["candidates"] = war.filter_commander_candidates(context["candidates"], orders)
	Forecast.annotate(war, root, context["candidates"], {"terrain": context["terrain"], "enemies": known_enemies, "required_preparation": prepare})
	# Short request-local IDs reduce duplicated candidate tokens in the schema.
	for index in range(context["candidates"].size()):
		if context["candidates"][index]["id"] not in ["maintain", "withdraw_corps"]: context["candidates"][index]["id"] = "c%02d" % index
	return context

static func plan(war, adapter) -> void:
	if adapter != null and adapter.has_method("supports_background_decisions"):
		if not adapter.has_method("can_request_model") or adapter.can_request_model({"level":"commander"}):
			plan_background(war, adapter)
			return
		# Disabled/unconfigured models use exactly the normal local commander loop.
		adapter = null
	var epoch: int = war.generation
	var contexts: Array = []
	for corps in war.state["corps"].values():
		succeed(war, corps)
		Structure.ensure(corps)
		Autonomy.evaluate_corps(war, corps)
		siege_slots(war, corps)
		var root: Dictionary = war.state["armies"][corps["root_id"]]
		if root["status"] == "ended" or root["returning"] or corps.get("withdrawing", false) or not war.ready(root): continue
		var tick_now := int(war.state["tick"])
		# 决策触发=3日心跳 + 方向性升级：只对“变糟”的质变提前重判（覆没/溃退/连续受阻滞留/粮道被断），
		# 恢复性变化（受阻解除、粮道恢复）不提前触发，交给下一次心跳。
		var worse := {}
		for id in corps["units"]:
			var unit: Dictionary = war.state["armies"][id]
			worse[id] = {"gone": unit["status"] == "ended", "routed": bool(unit["returning"]), "stuck": int(unit.get("tactical", {}).get("blocked_days", 0)) >= 2}
		var previous: Dictionary = corps.get("last_worse", {})
		var escalate := false
		for id in worse:
			if not previous.has(id): continue
			var was: Dictionary = previous[id]
			if (bool(worse[id]["gone"]) and not bool(was.get("gone", false))) or (bool(worse[id]["routed"]) and not bool(was.get("routed", false))) or (bool(worse[id]["stuck"]) and not bool(was.get("stuck", false))): escalate = true
		var supply_now: bool = war.supply_enabled() and int(corps["supply"]["blocked_until"]) > tick_now
		if supply_now and not bool(corps.get("last_supply_blocked", false)): escalate = true
		corps["last_worse"] = worse
		corps["last_supply_blocked"] = supply_now
		if tick_now - int(corps["last_plan"]) < 3 and not escalate: continue
		contexts.append(commander_context(war, corps))
	var outputs := {}
	if adapter != null and not contexts.is_empty(): outputs = await adapter.choose_batch(contexts)
	if war.generation != epoch: return
	for context in contexts:
		var corps: Dictionary = war.state["corps"][context["corps"]["id"]]
		var result: Dictionary = outputs.get(context["request_id"], fallback(context))
		var candidate: Dictionary = {}
		for option in context["candidates"]:
			if option["id"] == result.get("candidate_id", ""): candidate = option; break
		if candidate.is_empty():
			if adapter != null and result.get("source", "") == "model": adapter.metrics["fallbacks"] += 1
			result = fallback(context)
			for option in context["candidates"]:
				if option["id"] == result["candidate_id"]: candidate = option; break
		var applied := issue(war, corps, candidate["action"], str(result.get("reason_summary", "主帅下达任务")))
		corps["withdraw_hysteresis"] = str(candidate["action"].get("type", "")) == "withdraw_corps"
		war.state["armies"][corps["root_id"]]["last_reason"] = str(result.get("reason_summary", "主帅下达任务"))
		corps["last_plan"] = war.state["tick"]
		corps["orders"].append({"tick": war.state["tick"], "commander": corps["commander_id"], "action": candidate["action"], "reason": result.get("reason_summary", ""), "source": result.get("source", ""), "applied": applied, "policy_version": Policy.version(), "score_breakdown": result.get("score_breakdown", {})})
		preload("res://scripts/agents/officer_brain.gd").record_command(war,corps,corps["orders"][-1])
		while corps["orders"].size() > 40: corps["orders"].pop_front()

static func issue(war, corps: Dictionary, action: Dictionary, reason: String) -> Dictionary:
	Structure.ensure(corps)
	var recipients: Array = []
	if action.get("type", "") == "assign_task":
		var assigned_unit: Dictionary = war.state["armies"].get(action.get("unit", ""), {})
		recipients.append(str(assigned_unit.get("officer_id", "")))
	elif action.get("type", "") == "detach": recipients.append(str(action.get("officer", "")))
	for officer in recipients:
		Autonomy.ensure_evaluated(war, corps, str(officer), {"tick": war.state["tick"], "action": action, "reason": reason})
		var refusal: Dictionary = Autonomy.blocks_override(war, corps, str(officer))
		if refusal.get("blocked", false): return {"ok": false, "refused": true, "officer": officer, "message": refusal.get("reason", "拒绝军令")}
	if not war.supply_enabled() and (action.get("task", "") == "cut_supply" or action.get("mode", "") == "blockade"): return {"ok": false, "message": "粮草系统已停用"}
	var kind: String = action.get("type", "maintain")
	if kind not in ["maintain", "deploy_corps", "set_siege_mode", "detach", "assign_task", "rotate_front", "withdraw_corps"]: return {"ok": false, "message": "未知主帅命令"}
	if kind == "deploy_corps":
		return deploy_by_commander(war,corps,str(action.get("posture","balanced")),reason)
	if kind == "rotate_front":
		if not corps["units"].has(action.get("front", "")) or not corps["units"].has(action.get("reserve", "")): return {"ok": false, "message": "轮换部队不属于军团"}
		var front: Dictionary = war.state["armies"][action["front"]]
		var reserve: Dictionary = war.state["armies"][action["reserve"]]
		if front["status"] == "ended" or reserve["status"] == "ended" or front["returning"] or reserve["returning"] or front["corps_task"]["type"] != "main_attack" or reserve["corps_task"]["type"] != "reserve" or float(reserve["morale"]) < 55 or float(reserve["organization"]) < 50: return {"ok": false, "message": "部队不能进行前锋轮换"}
		var promoted: Dictionary = issue(war, corps, {"type": "assign_task", "unit": reserve["id"], "task": "main_attack"}, reason)
		if not promoted.get("ok", false): return promoted
		return issue(war, corps, {"type": "assign_task", "unit": front["id"], "task": "regroup"}, reason)
	if kind == "set_siege_mode":
		if action.get("mode", "") not in ["assault", "blockade"]: return {"ok": false}
		var commander: Dictionary = war.state["armies"][corps["root_id"]]
		if commander["mission_type"] != "capture" or war.store.city_state(commander["target"]).get("faction", "") == corps["faction"]: return {"ok": false, "message": "没有可围攻的敌城"}
		corps["siege_mode"] = action["mode"]
		return {"ok": true}
	if kind == "detach":
		var source: Dictionary = war.state["armies"].get(action.get("source", ""), {})
		if source.is_empty() or source.get("corps_id", "") != corps["id"]: return {"ok": false}
		if action.get("task", "") not in ["main_attack", "flank", "reserve", "rear_guard", "raid_rear", "cut_supply"]: return {"ok": false, "message": "拆队任务无效"}
		if action["task"] == "cut_supply":
			var known: Dictionary = corps["known_supplies"].get(action.get("enemy_corps", ""), {})
			if known.is_empty() or int(known.get("cell", -1)) != int(action.get("cell", -1)): return {"ok": false, "message": "尚未发现这条粮道"}
		var result := split(war, corps, source, action.get("officer", ""), int(action["strength"]), action["task"], action["cell"])
		if result.get("ok", false):
			var child: Dictionary = war.state["armies"][result["army_id"]]
			child["corps_task"]["enemy_corps"] = action.get("enemy_corps", "")
			child["corps_task"]["reason"] = reason
			child["corps_task"]["independent"] = action["task"] in ["raid_rear", "cut_supply"]
		return result
	if kind == "assign_task":
		if not corps["units"].has(action.get("unit", "")) or action.get("unit", "") == corps["root_id"] or action.get("task", "") not in ["main_attack", "support", "flank", "reserve", "rear_guard", "regroup", "raid_rear", "cut_supply"]: return {"ok": false}
		if war.state["armies"][action["unit"]]["status"] == "ended" or war.state["armies"][action["unit"]]["returning"]: return {"ok": false}
		var assigned: Dictionary = war.state["armies"][action["unit"]]
		var old_task: Dictionary = assigned["corps_task"]
		if old_task["type"] == action["task"] and int(old_task.get("cell", -1)) == int(action.get("cell", -1)): return {"ok": true, "unchanged": true}
		if int(war.state["tick"]) - int(old_task.get("issued_at", -10)) < 3 and action["task"] not in ["rear_guard", "regroup"]: return {"ok": false, "message": "部队正在执行刚下达的军令，需保持至少三日"}
		if old_task["type"] == "main_attack" and action["task"] in ["support", "flank", "reserve", "raid_rear", "cut_supply"]:
			var other_front := false
			for id in corps["units"]:
				var unit: Dictionary = war.state["armies"][id]
				if id != assigned["id"] and unit["status"] != "ended" and not unit["returning"] and unit["corps_task"]["type"] == "main_attack": other_front = true
			if not other_front: return {"ok": false, "message": "需保留正面战线，不能把最后一支主攻改为旁路任务"}
		if action["task"] in ["raid_rear", "cut_supply"]:
			if assigned.has("tactical") and Tactical.contact_state(war, assigned)["adjacent_enemies"] > 0: return {"ok": false, "message": "接战部队需先脱离，不能直接改为独立奔袭"}
			var cell := int(action.get("cell", -1))
			var board: Dictionary = Tactical.board_for(war, assigned)
			if board.is_empty() or not Tactical.in_battlefield(board, cell): return {"ok": false, "message": "任务目标格无效"}
			if action["task"] == "cut_supply":
				var known: Dictionary = corps["known_supplies"].get(action.get("enemy_corps", ""), {})
				if known.is_empty() or int(known.get("cell", -1)) != cell: return {"ok": false, "message": "尚未发现这条粮道"}
		assigned["corps_task"] = {"type": action["task"], "reason": reason, "issued_by": Structure.tree_parent(corps, str(assigned["officer_id"])), "issued_at": int(war.state["tick"]), "cell": int(action.get("cell", -1)), "enemy_corps": action.get("enemy_corps", ""), "independent": action["task"] in ["raid_rear", "cut_supply"]}
		if assigned.has("tactical"):
			assigned["tactical"]["lane"] = Tactical.column_of(int(assigned["tactical"]["cell"]))
			for field in ["flank_goal", "flank_target", "flank_ready", "pursuit_origin", "target_until", "previous_cell", "previous_goal"]: assigned["tactical"].erase(field)
	if kind == "withdraw_corps":
		if not war.orders_for(war.state["armies"][corps["root_id"]])["retreat"]: return {"ok": false, "message": "军令禁止自主撤退"}
		var guards: Array = corps["units"].filter(func(id):
			var unit: Dictionary = war.state["armies"][id]
			return id != corps["root_id"] and unit["status"] != "ended" and not unit["returning"] and unit.has("tactical") and unit["organization"] >= 35 and unit["morale"] >= 35
		)
		guards.sort_custom(func(a, b):
			var first: Dictionary = war.state["armies"][a]
			var second: Dictionary = war.state["armies"][b]
			return war.Combat.strength(first) + (10000 if first["corps_task"]["type"] == "reserve" else 0) > war.Combat.strength(second) + (10000 if second["corps_task"]["type"] == "reserve" else 0)
		)
		var guard: String = guards[0] if not guards.is_empty() else ""
		corps["withdrawing"] = true
		corps["withdraw_started"] = war.state["tick"]
		for id in corps["units"]:
			var unit: Dictionary = war.state["armies"][id]
			if unit["status"] == "ended": continue
			Autonomy.ensure_evaluated(war, corps, str(unit["officer_id"]), {"action": action})
			if Autonomy.blocks_override(war, corps, str(unit["officer_id"])).get("blocked", false): continue
			if id == guard: unit["corps_task"] = {"type": "rear_guard", "reason": "主帅命令掩护全军撤离，安全后归营", "issued_by": corps["commander_id"], "cover_withdrawal": true}
			else:
				unit["retreat_reason"] = "主帅军令：" + reason
				war._execute(unit, {"type": "withdraw"})
	return {"ok": true}

static func siege_slots(war, corps: Dictionary) -> void:
	var root: Dictionary = war.state["armies"][corps["root_id"]]
	var board: Dictionary = Tactical.board_for(war, root)
	corps["siege_approach"] = false
	if root["returning"] or root["mission_type"] != "capture" or not corps.get("deployed", false) or not board.get("objectives", {}).has(root["target"]) or war.store.city_state(root["target"])["faction"] == root["faction"]: return
	# Shared sightings determine whether the field screen has been cleared.
	for id in corps["units"]:
		for enemy in Tactical.targets(war, war.state["armies"][id]):
			if not enemy["returning"]: return
	corps["siege_approach"] = true
	var city: int = board["objectives"][root["target"]]
	var claimed := {}
	for id in corps["units"]:
		var unit: Dictionary = war.state["armies"][id]
		if unit["status"] == "ended" or unit["returning"] or not unit.has("tactical") or unit["corps_task"].get("independent", false): continue
		# With the field screen cleared, the headquarters' own infantry can join
		# the authorized city assault. Keeping it on the outer ring leaves a corps
		# with cavalry/archers at the wall unable to use its remaining breach force.
		var assault: bool = unit["corps_task"]["type"] in ["main_attack", "flank", "raid_rear"] or (war.uses_unit_brain(unit) and id == corps["root_id"] and int(unit["units"].get("infantry",0)) >= 500)
		var ring := 1 if assault else 2
		var saved: int = unit["tactical"].get("siege_slot", -1)
		if saved >= 0 and Tactical.can_enter(war, unit, saved) and Tactical.Fort.distance_to_wall(board, str(root["target"]), saved) == ring and not claimed.has(saved): claimed[saved] = true; continue
		var options: Array = Tactical.Fort.approach(war, board, str(corps["faction"]), str(root["target"]), int(unit["tactical"]["cell"]), ring).filter(func(cell): return not claimed.has(cell))
		if not options.is_empty(): unit["tactical"]["siege_slot"] = options[0]; claimed[options[0]] = true

static func update(war) -> void:
	for corps in war.state["corps"].values():
		succeed(war, corps)
		Structure.ensure(corps)
		Autonomy.evaluate_corps(war, corps)
		siege_slots(war, corps)
		if corps.get("ended", false) or not war.ready(war.state["armies"][corps["root_id"]]): continue
		corps["known_supplies"] = {}
		for other in war.state["corps"].values():
			if not war.supply_enabled() or other.get("ended", false): continue
			if other["faction"] == corps["faction"] or int(other["supply"]["cell"]) < 0: continue
			for id in corps["units"]:
				var army: Dictionary = war.state["armies"][id]
				if army["status"] != "ended" and army.has("tactical"): corps["known_supplies"][other["id"]] = {"cell": int(other["supply"]["cell"]), "observed_at": war.state["tick"]}
		for id in corps["units"]:
			var unit: Dictionary = war.state["armies"][id]
			if unit["status"] == "ended": continue
			var independent: Dictionary = Autonomy.stance_of(corps, str(unit["officer_id"]))
			unit["autonomy"] = independent.duplicate(true)
			unit["autonomy"]["until"] = Autonomy.refusal_until(corps, str(unit["officer_id"]))
			if independent.get("stance", "obey") != "obey" and Autonomy.refused(war, corps, str(unit["officer_id"])) and not unit["returning"]:
				unit["action"] = Autonomy.local_action(war, corps, unit) if independent.get("stance") == "act" else {"type": "hold"}
				unit["last_reason"] = ("自行行动：" if independent.get("stance") == "act" else "异议：") + str(independent.get("reason", ""))
				if unit.has("battle_ai"): unit["battle_ai"]["plan"] = {}
				continue
			var task: Dictionary = unit["corps_task"]
			var role: String = task["type"]
			if unit["id"] != corps["root_id"] and not war.uses_unit_brain(unit): unit["last_reason"] = "奉主帅军令：" + str(task.get("reason", TASKS.get(role, role)))
			var suggested := _suggest_target(war, unit, int(corps["last_plan"])) if role in ["main_attack", "flank", "support", "raid_rear"] and not war.uses_unit_brain(unit) else ""
			var supervisor: String = Structure.tree_parent(corps, str(unit["officer_id"]))
			var superior_unit: Dictionary = Autonomy.unit_for(war, corps, supervisor)
			var superior_id: String = str(superior_unit.get("id", corps["root_id"]))
			unit["operation"] = {"role": role, "role_label": TASKS.get(role, role), "commander": superior_id, "support_id": superior_id, "suggested_target": suggested, "plan_until": int(corps["last_plan"]) + 3, "change_reason": task.get("reason", "主帅任务")}
			if unit.has("tactical"): unit["tactical"]["role"] = role
			if war.supply_enabled() and int(corps["supply"]["blocked_until"]) <= int(war.state["tick"]) and unit.has("tactical"):
				var need := maxf(0, war.daily_food(unit) * 7 - float(unit["grain"]))
				var amount := minf(need, float(corps["supply"]["stock"]))
				unit["grain"] += amount
				corps["supply"]["stock"] -= amount
			if not unit["returning"]:
				if war.uses_unit_brain(unit):
					if role == "rear_guard":
						var escaping: Array = corps["units"].filter(func(friend_id): return war.state["armies"][friend_id]["returning"] and war.state["armies"][friend_id]["status"] != "ended")
						if not escaping.is_empty(): unit["operation"]["support_id"] = escaping[0]
						elif task.get("cover_withdrawal",false) and int(war.state["tick"])-int(corps.get("withdraw_started",0)) >= 3: war._execute(unit,{"type":"withdraw"})
					if float(unit["morale"]) < 25 or float(unit["organization"]) < 20: war._check_rout(unit)
					continue
				unit["action"] = {"type": "hold"} if role in ["command", "reserve"] else {"type": "continue"}
				if corps.get("autonomous_deployment", false) and not corps.get("deployed", false): unit["action"] = {"type": "hold"}
				var enemy_list := Tactical.targets(war, unit) if unit.has("tactical") else []
				var ordered: Dictionary = Tactical.ordered_target(war, unit) if not enemy_list.is_empty() else {}
				if role == "flank" and not ordered.is_empty(): unit["action"] = {"type": "flank", "enemy": ordered["id"]}
				elif (role in ["main_attack","support"] or (role == "raid_rear" and task.get("stage", "") == "attack")) and not ordered.is_empty(): unit["action"] = {"type": "engage", "enemy": ordered["id"]}
				elif role == "rear_guard":
					var covered: String = corps["root_id"]
					var nearest := 999
					for friend_id in corps["units"]:
						var friend: Dictionary = war.state["armies"][friend_id]
						if friend["status"] != "ended" and friend["returning"] and unit.has("tactical"):
							var distance := Tactical.distance(unit, friend)
							var priority: int = distance - (20 if Tactical.contact_state(war, friend)["adjacent_enemies"] > 0 else 0)
							if priority < nearest: covered = friend_id; nearest = priority
					unit["operation"]["support_id"] = covered
					unit["action"] = {"type": "support", "ally": covered}
				if corps.get("autonomous_deployment", false) and not corps.get("deployed", false): unit["action"] = {"type": "hold"}
				if unit.get("objective_complete", false): unit["action"] = {"type": "hold"}
				if not unit.has("tactical"):
					var root: Dictionary = war.state["armies"][corps["root_id"]]
					if unit["id"] == root["id"]:
						var context: Dictionary = war.context_for(root)
						context["army"]["strength"] = summary(war, corps)["strength"]
						for candidate in context["candidates"]:
							if candidate["action"]["type"] == "besiege": candidate["defender_ratio"] = float(root["intel"]["cities"].get(root["target"], {}).get("strength_estimate", 0)) / maxf(context["army"]["strength"], 1)
						var legal: Dictionary = war.validate_decision(context, war.Policy.choose(context))
						if legal.get("ok", false): war._execute(root, legal["action"])
					elif unit["location"]["edge"] != "": unit["action"] = {"type": "continue"}
					elif root["location"]["edge"] != "" and unit["location"]["node"] == root["location"]["from"]:
						war._execute(unit, {"type": "march", "target": root["location"]["to"], "edge": root["location"]["edge"]})
					else: unit["action"] = {"type": "hold"}
				if not war.orders_for(unit)["engage"] and unit["action"]["type"] in ["engage", "flank"]: unit["action"] = {"type": "hold"}
				if task.get("cover_withdrawal", false) and int(war.state["tick"]) - int(corps.get("withdraw_started", 0)) >= 3:
					var needed := false
					for friend_id in corps["units"]:
						var friend: Dictionary = war.state["armies"][friend_id]
						if friend_id == id or friend["status"] == "ended" or not friend["returning"]: continue
						if Tactical.distance(unit, friend) <= 3 or Tactical.contact_state(war, friend)["adjacent_enemies"] > 0: needed = true
					if not needed: war._execute(unit, {"type": "withdraw"})
				if float(unit["morale"]) < 25 or float(unit["organization"]) < 20: war._check_rout(unit)

static func logistics(war) -> void:
	for corps in war.state["corps"].values():
		for id in corps["units"].duplicate():
			var unit: Dictionary = war.state["armies"][id]
			if unit["status"] == "ended" or unit["returning"] or not unit.has("tactical"): continue
			var task: Dictionary = unit["corps_task"]
			if task["type"] == "raid_rear" and task.get("stage", "") != "attack" and Tactical.cell_distance(int(unit["tactical"]["cell"]), int(task.get("cell", unit["tactical"]["cell"]))) == 0:
				task["stage"] = "attack"
				task["reason"] = "奇袭小队已完成绕后，攻击敌军后方"
				war._report(unit, "奇袭就位", unit["name"] + "已抵达绕后位置，开始袭击敌后。", true)
			if task["type"] == "regroup":
				var root: Dictionary = war.state["armies"][corps["root_id"]]
				if root["status"] != "ended" and Tactical.distance(unit, root) <= 1 and Tactical.contact_state(war, unit)["adjacent_enemies"] == 0: merge(war, corps, unit, root)
				continue
			if not war.supply_enabled() or task["type"] != "cut_supply" or int(task.get("last_raid", -10)) + 3 > int(war.state["tick"]): continue
			var enemy: Dictionary = war.state["corps"].get(task.get("enemy_corps", ""), {})
			if enemy.is_empty() or enemy.get("ended", false) or enemy["faction"] == corps["faction"] or int(enemy["supply"]["cell"]) < 0 or Tactical.cell_distance(int(unit["tactical"]["cell"]), int(enemy["supply"]["cell"])) > 1 or Tactical.contact_state(war, unit)["adjacent_enemies"] > 0: continue
			enemy["supply"]["blocked_until"] = int(war.state["tick"]) + 4
			var loot := minf(float(enemy["supply"]["stock"]), war.daily_food(unit) * 5)
			enemy["supply"]["stock"] -= loot
			unit["grain"] += loot
			corps["looted_grain"] = float(corps.get("looted_grain",0)) + loot
			task["last_raid"] = war.state["tick"]
			war._report(unit, "粮道截断", "%s截断%s粮道四日，夺粮%d。" % [unit["name"], enemy["name"], int(loot)], true)

static func fallback(context: Dictionary) -> Dictionary:
	var result: Dictionary = Policy.commander_choose(context)
	if not result.is_empty(): return result
	return {"candidate_id": "maintain", "reason_summary": "保持军团部署", "source": "commander-policy"}

static func merge(war, corps: Dictionary, child: Dictionary, root: Dictionary) -> void:
	if not root.get("wounded_units") is Dictionary: root["wounded_units"] = {"infantry": int(root["wounded"]), "archers": 0, "cavalry": 0}
	var injuries: Dictionary = child.get("wounded_units", {"infantry": int(child["wounded"]), "archers": 0, "cavalry": 0})
	for type in Combat.TYPES: root["wounded_units"][type] = int(root["wounded_units"].get(type, 0)) + int(injuries.get(type, 0))
	child["wounded_units"] = {"infantry": 0, "archers": 0, "cavalry": 0}
	if child["id"] == root["id"]: return
	war.planner.invalidate("unit:"+str(child["id"]))
	if child.has("battle_ai"): child["battle_ai"]["plan"] = {}
	if root.has("battle_ai"):
		root["battle_ai"]["actor_revision"] += 1
		root["battle_ai"]["plan"] = {}
		war.planner.invalidate("unit:"+str(root["id"]))
	for type in Combat.TYPES:
		root["units"][type] += child["units"][type]
		child["units"][type] = 0
	root["siege_engines"] = int(root.get("siege_engines",0)) + int(child.get("siege_engines",0))
	child["siege_engines"] = 0
	for ledger in ["initial_strength", "dead", "wounded", "captured", "deposited", "dispersed"]:
		root[ledger] = int(root.get(ledger, 0)) + int(child.get(ledger, 0))
		child[ledger] = 0
	root["enemy_killed"] = int(root.get("enemy_killed", 0)) + int(child.get("enemy_killed", 0))
	child["enemy_killed"] = 0
	root["personal_soldier_kills"] = int(root.get("personal_soldier_kills", 0)) + int(child.get("personal_soldier_kills", 0))
	child["personal_soldier_kills"] = 0
	root["grain"] += child["grain"]
	child["grain"] = 0.0
	child["status"] = "ended"
	child["outcome"] = "归建中军"
	war.state["missions"][child["id"]]["status"] = "ended"
	war.state["missions"][child["id"]]["result"] = "归建"
	war.state["officer_states"][child["officer_id"]] = {"status": "deployed", "army_id": root["id"], "corps_id": corps["id"], "duel_wounded": child.get("duel_wounded", false)}
	corps["units"].erase(child["id"])
	preload("res://scripts/war/officer_fate.gd").restore(war)


static func succeed(war, corps: Dictionary) -> void:
	var root: Dictionary = war.state["armies"][corps["root_id"]]
	if root["status"] != "ended" and (not root["returning"] or corps.get("withdrawing", false)): return
	var survivors: Array = corps["units"].filter(func(id): return war.state["armies"][id]["status"] != "ended")
	if survivors.is_empty(): return
	var ready: Array = survivors.filter(func(id): return not war.state["armies"][id]["returning"])
	if root["status"] != "ended" and ready.is_empty(): return
	if not ready.is_empty(): survivors = ready
	survivors.sort_custom(func(a, b): return suitability(war.roster.officers[war.state["armies"][a]["officer_id"]], "主帅") > suitability(war.roster.officers[war.state["armies"][b]["officer_id"]], "主帅"))
	corps["root_id"] = survivors[0]
	var successor: Dictionary = war.state["armies"][survivors[0]]
	corps["withdraw_hysteresis"] = false
	corps["appointments"][corps["commander_id"]] = "原主帅"
	corps["commander_id"] = successor["officer_id"]
	corps["appointments"][successor["officer_id"]] = "代理主帅"
	if not corps.get("withdrawing", false): successor["corps_task"] = {"type": "command", "reason": "原主帅撤离或中军结束任务，接掌军团指挥", "issued_by": successor["officer_id"]}
	Structure.ensure(corps)
	corps["last_plan"] = -10

static func on_finish(war, army: Dictionary) -> void:
	preload("res://scripts/war/officer_fate.gd").restore(war)
	var corps: Dictionary = war.state["corps"].get(army.get("corps_id", ""), {})
	if corps.is_empty(): return
	var active: Array = corps["units"].filter(func(id): return war.state["armies"][id]["status"] != "ended")
	if not active.is_empty():
		if army["outcome"] == "军队覆没":
			for officer in corps["members"]:
				if war.state["officer_states"].get(officer, {}).get("army_id", "") == army["id"]: war.state["officer_states"][officer]["lost"] = true
		# Staff remain part of the deployed corps until all its formations return.
		war.state["officer_states"][army["officer_id"]] = {"status": "recovering" if army.get("duel_wounded",false) else "deployed", "available_after": int(war.state["tick"]) + int(war.rules["duel"]["recover_days"]), "corps_id": corps["id"], "army_id": active[0], "lost": army["outcome"] == "军队覆没", "duel_wounded": army.get("duel_wounded",false)}
		preload("res://scripts/war/officer_fate.gd").restore(war)
		succeed(war, corps)
		return
	for officer in corps["members"]:
		var lost: bool = war.state["officer_states"].get(officer, {}).get("lost", false) or (officer == army["officer_id"] and army["outcome"] == "军队覆没")
		var wounded: bool = war.state["officer_states"].get(officer,{}).get("duel_wounded",false)
		war.state["officer_states"][officer] = {"status": "recovering" if lost or wounded else "available", "city": army["location"]["node"], "available_after": int(war.state["tick"]) + (int(war.rules["duel"]["recover_days"]) if wounded else 10), "duel_wounded": wounded}
	var city: Dictionary = war.store.city_state(army["location"]["node"])
	if city.has("population") and city.get("faction", "") == corps["faction"]:
		city["grain"] += int(corps["supply"]["stock"])
	corps["supply"]["stock"] = 0.0
	corps["ended"] = true
	preload("res://scripts/war/officer_fate.gd").restore(war)


static func rear_cell(war, corps: Dictionary, enemy: Dictionary) -> int:
	var point := int(enemy.get("tactical_cell", -1))
	if point < 0: return -1
	var root: Dictionary = war.state["armies"][corps["root_id"]]
	var board: Dictionary = Tactical.board_for(war, root)
	if board.is_empty(): return -1
	var desired := Tactical.cell_at(Tactical.column_of(point), clampi(Tactical.row_of(point) + (-3 * Tactical.side_for(board, str(corps["faction"]))), int(board["min_row"]) + 1, int(board["max_row"]) - 1))
	var options: Array = []
	for q in range(-7, 8):
		for r in range(-8, 9):
			var cell := Tactical.offset_cell(board, q, r)
			if not board["blocked"].has(cell) and Tactical.cell_distance(cell, desired) <= 2 and Tactical.cell_distance(cell, point) >= 2: options.append(cell)
	options.sort_custom(func(a, b): return Tactical.cell_distance(a, desired) < Tactical.cell_distance(b, desired))
	return options[0] if not options.is_empty() else -1


static func decision_signature(war, corps: Dictionary, adapter) -> String:
	var units: Array = []
	for id in corps["units"]:
		var unit: Dictionary = war.state["armies"][id]
		var contact: Dictionary = war._observed_contact(unit) if unit.has("tactical") and unit["status"] != "ended" else {}
		units.append([id, unit["status"], unit["returning"], unit["corps_task"]["type"], unit["corps_task"].get("stage", ""), float(unit["morale"]) < 30, float(unit["organization"]) < 25, war.supply_enabled() and float(unit["grain"]) < war.daily_food(unit) * 3, int(unit.get("tactical", {}).get("blocked_days", 0)) >= 2, contact.get("flanked", false), int(contact.get("adjacent_enemies", 0)) >= 3, preload("res://scripts/war/troop_roles.gd").kind(unit), preload("res://scripts/war/troop_roles.gd").engine_count(unit)])
	var seen := {}
	for id in corps["units"]:
		for enemy in war.state["armies"][id]["intel"]["enemies"]: seen[enemy] = true
	var enemies: Array = seen.keys()
	enemies.sort()
	var supplies: Array = corps["known_supplies"].keys()
	supplies.sort()
	var service := [adapter.get("endpoint"), adapter.get("model"), adapter.get("enabled"), corps.get("autonomous_deployment", false) and not corps.get("deployed", false), corps.get("siege_mode", "assault")]
	var siege: Dictionary = war.state.get("sieges", {}).get(war.state["armies"][corps["root_id"]]["target"], {})
	return JSON.stringify([corps["root_id"], units, enemies, supplies, int(corps["supply"]["blocked_until"]) > int(war.state["tick"]), war.orders_for(war.state["armies"][corps["root_id"]]), service, siege.get("phase", "")])

static func plan_background(war, adapter: Node) -> void:
	var requests: Array = []
	var signatures := {}
	for corps in war.state["corps"].values():
		succeed(war, corps)
		var root: Dictionary = war.state["armies"][corps["root_id"]]
		if root["status"] == "ended" or root["returning"] or corps.get("withdrawing", false): continue
		if not war.ready(root): continue
		var tick: int = war.state["tick"]
		var key: String = "corps:" + corps["id"]
		var signature := decision_signature(war, corps, adapter)
		var proposal: Dictionary = war.planner.take(key, decision_authority_signature(signature), tick)
		if not proposal.is_empty():
			var result: Dictionary = proposal["result"]
			var selected: Dictionary = {}
			for candidate in proposal["context"]["candidates"]:
				if candidate["id"] == result.get("candidate_id", ""): selected = candidate; break
			if not selected.is_empty():
				record_background_order(war, corps, selected["action"], result, int(proposal["tick"]))
				corps["request_signature"] = decision_signature(war, corps, adapter)
				corps["last_requested"] = tick
			else:
				adapter.metrics["fallbacks"] += 1
		var context: Dictionary = commander_context(war, corps)
		context["background"] = true
		var local: Dictionary = fallback(context)
		# Critical routing and missing frontline are handled immediately by rules.
		# They never wait for a model response; ordinary march/combat keeps its order.
		var frontline_missing: bool = not context["corps"]["units"].any(func(u): return not u["returning"] and u["task"]["type"] == "main_attack")
		var urgent: bool = local["candidate_id"] == "withdraw_corps" or frontline_missing
		if int(corps["last_plan"]) < 0 or (local["candidate_id"] != "maintain" and (tick - int(corps["last_plan"]) >= 3 or urgent)):
			for candidate in context["candidates"]:
				if candidate["id"] == local["candidate_id"]:
					record_background_order(war, corps, candidate["action"], local, tick)
					break
		if corps.get("withdrawing", false): continue
		context = commander_context(war, corps)
		context["background"] = true
		signature = decision_signature(war, corps, adapter)
		var age: int = tick - int(corps.get("last_requested", -10))
		var changed: bool = signature != corps.get("request_signature", "")
		if war.planner.has_pending(key) or (age < 5 and (not changed or age < 2)): continue
		context["decision_trigger"] = "部署完成" if not corps.has("last_requested") else "敌情、任务或补给发生关键变化" if changed else "五日态势复核"
		requests.append(context)
		signatures[key] = decision_authority_signature(signature)
	if war.planner.submit(requests, adapter, signatures):
		for context in requests:
			var corps: Dictionary = war.state["corps"][context["corps"]["id"]]
			corps["last_requested"] = war.state["tick"]
			corps["request_signature"] = decision_signature(war, corps, adapter)

static func record_background_order(war, corps: Dictionary, action: Dictionary, result: Dictionary, observed_tick: int) -> void:
	# Request-local IDs and battlefield conditions may change while the model runs.
	# Recheck the concrete action against today's authorized candidates.
	var current := commander_context(war, corps)
	var legal: bool = current["candidates"].any(func(c): return c["action"] == action)
	var applied := issue(war, corps, action, str(result.get("reason_summary", "主帅军令"))) if legal else {"ok": false, "message": "战局已变化，旧提案不再适用"}
	corps["withdraw_hysteresis"] = str(action.get("type", "")) == "withdraw_corps"
	if applied.get("ok", false): war.state["armies"][corps["root_id"]]["last_reason"] = str(result.get("reason_summary", "主帅军令"))
	if applied.get("ok", false): corps["last_plan"] = war.state["tick"]
	corps["orders"].append({"tick": war.state["tick"], "based_on_tick": observed_tick, "commander": corps["commander_id"], "action": action.duplicate(true), "reason": result.get("reason_summary", ""), "source": result.get("source", "commander-policy"), "applied": applied, "policy_version": Policy.version(), "score_breakdown": result.get("score_breakdown", {})})
	preload("res://scripts/agents/officer_brain.gd").record_command(war,corps,corps["orders"][-1])
	while corps["orders"].size() > 40: corps["orders"].pop_front()


static func decision_authority_signature(signature: String) -> String:
	var state: Array = JSON.parse_string(signature)
	# Newly scouted enemies prompt the next review, but do not invalidate an
	# otherwise legal issued order. Routing, command authority and crises do.
	return JSON.stringify([state[0], state[1], state[4], state[5], state[6], state[8] if state.size() > 8 else []])

# The adviser only interprets reports already known to the corps, never hidden enemies.
static func staff_advice(war, corps: Dictionary) -> Dictionary:
	for id in corps["members"]:
		if not Structure.is_staff(str(corps["appointments"].get(id, ""))): continue
		var status: Dictionary = war.state["officer_states"].get(id, {})
		if status.get("lost", false) or status.get("duel_wounded", false) or status.get("status", "") in ["dead", "captured"]: continue
		var skills: Dictionary = war.roster.officers[id].get("skills", {})
		return {"officer_id": id, "name": war.roster.officers[id]["name"], "analysis": skills.get("料敌", 50), "planning": skills.get("智计", 50), "duty": "依据个人立场提供建议", "stance": Autonomy.stance_of(corps, str(id)).get("stance", "obey"), "reason": Autonomy.stance_of(corps, str(id)).get("reason", "")}
	return {}

# Upgrade without merging units, removing officers or changing troop ledgers.
static func migrate(war, corps: Dictionary) -> void:
	for unit_id in corps.get("units", []):
		var unit: Dictionary = war.state["armies"].get(unit_id, {})
		var officer: String = str(unit.get("officer_id", ""))
		if not officer.is_empty() and not corps["members"].has(officer): corps["members"].append(officer)
	Structure.ensure(corps)
	for unit_id in corps.get("units", []):
		var unit: Dictionary = war.state["armies"].get(unit_id, {})
		if unit.get("status", "ended") != "ended": corps["node_strength"][str(unit["officer_id"])] = Combat.strength(unit)
	corps["composition_version"] = Structure.STRUCTURE_VERSION
