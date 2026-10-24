extends RefCounted

const Tactical = preload("res://scripts/war/tactical_battlefield.gd")
const Plan = preload("res://scripts/agents/tactical_plan.gd")
const Roles = preload("res://scripts/war/troop_roles.gd")

# One bounded flood per actor. All occupancy is from the frozen knowledge view.
# Actual unseen obstructions are checked by the executor, not scored here.
static var _graphs: Dictionary = {}

static func geometry(board: Dictionary) -> AStar2D:
	var signature := JSON.stringify([board["min_column"],board["max_column"],board["min_row"],board["max_row"],board["blocked"]])
	if _graphs.has(signature): return _graphs[signature]
	var graph := AStar2D.new()
	var blocked := {}
	for cell in board["blocked"]: blocked[int(cell)] = true
	for q in range(int(board["min_column"]),int(board["max_column"])+1):
		for r in range(int(board["min_row"]),int(board["max_row"])+1):
			var cell := Tactical.cell_at(q,r)
			if not blocked.has(cell) and Tactical.grid().walkable(cell): graph.add_point(cell,Tactical.world_cell(cell))
	for cell in graph.get_point_ids():
		for next in Tactical.neighbors(cell):
			if next > cell and graph.has_point(next): graph.connect_points(cell,next)
	if _graphs.size() >= 8: _graphs.erase(_graphs.keys()[0])
	_graphs[signature] = graph
	return graph

static func reach(context: Dictionary) -> Dictionary:
	var start := int(context["self"]["cell"])
	var graph := geometry(context["knowledge"]["terrain"])
	var occupied := {}
	for other in context["knowledge"]["allies"] + context["knowledge"]["enemies"]:
		var cell := int(other.get("cell",-1))
		if cell >= 0 and cell != start and graph.has_point(cell): occupied[cell] = true
	# Cached geometry is restored after each actor; no world AStar is changed.
	for cell in occupied: graph.set_point_disabled(cell,true)
	var first := {start:start}
	var steps := {start:0}
	var local: Array = [start]
	var cursor := 0
	while cursor < local.size():
		var cell := int(local[cursor])
		cursor += 1
		if int(steps[cell]) >= 3: continue
		for next in graph.get_point_connections(cell):
			if first.has(next) or occupied.has(next): continue
			first[next] = next if cell == start else first[cell]
			steps[next] = int(steps[cell]) + 1
			local.append(next)
	return {"first":first,"steps":steps,"occupied":occupied,"graph":graph,"routes":{},"destinations":{}}

static func step_to(context: Dictionary, paths: Dictionary, goal: int, stop: int) -> int:
	var start := int(context["self"]["cell"])
	if Tactical.cell_distance(start,goal) <= stop: return start
	var key := str(goal)+":"+str(stop)
	if paths["routes"].has(key): return int(paths["routes"][key])
	var graph: AStar2D = paths["graph"]
	var close: Array = [goal]
	for radius in range(stop):
		for cell in close.duplicate():
			for neighbor in Tactical.neighbors(int(cell)):
				if not close.has(neighbor): close.append(neighbor)
	close.sort_custom(func(a,b): return Tactical.cell_distance(start,a) < Tactical.cell_distance(start,b) if Tactical.cell_distance(start,a) != Tactical.cell_distance(start,b) else a < b)
	var best := start
	var destination := start
	var shortest := 100000
	for cell in close:
		if not graph.has_point(cell) or graph.is_point_disabled(cell): continue
		if Tactical.cell_distance(start,cell) >= shortest: continue
		var path := graph.get_id_path(start,cell)
		if path.size() > 1 and path.size()-1 < shortest:
			best = int(path[1])
			destination = int(path[-1])
			shortest = path.size()-1
	paths["routes"][key] = best
	paths["destinations"][key] = destination
	return best

static func allowed(context: Dictionary, template: String, goal: int, target: Dictionary = {}) -> bool:
	var auth: Dictionary = context["authority"]
	var own: Dictionary = context["self"]
	var start := int(own["cell"])
	var role := str(context["task"]["role"])
	if not target.is_empty() and not auth["engage"]: return false
	if template in ["advance", "flank_then_engage", "fire_with_cover", "reserve_reinforce"] and not auth["engage"]: return false
	if template == "flank_then_engage" and auth["risk_allowance"] == "保守": return false
	if template == "rally" and (not auth["local_disengage"] or auth["must_hold_objective"]): return false
	if auth["must_hold_objective"] and Tactical.cell_distance(goal, int(auth["duty_cell"])) > 1: return false
	if Tactical.cell_distance(goal, int(auth["duty_cell"])) > int(auth["region_radius"]): return false
	if not target.is_empty() and target.get("routing", false):
		if not auth["pursue"] or Tactical.cell_distance(goal, int(context.get("current_plan", {}).get("pursuit_origin", start))) > int(auth["pursuit_limit_cells"]): return false
	if role in ["reserve", "command"] and template in ["advance", "flank_then_engage"]:
		if not (role == "command" and context.get("last_line",false)) and (target.is_empty() or Tactical.cell_distance(start, int(target["cell"])) > 1): return false
	if role == "reserve" and template == "reserve_reinforce" and not context["reserve_trigger"]: return false
	if role == "regroup" and template not in ["cover_ally", "hold_line", "rally"]: return false
	return true

static func add(list: Array, context: Dictionary, paths: Dictionary, template: String, goal: int, target: Dictionary = {}, ally: Dictionary = {}, stop: int = 0) -> void:
	if not Plan.templates().has(template) or not allowed(context, template, goal, target): return
	# Escorting is complete when the known ally is safe. A stale escort must not
	# monopolize a healthy frontline or follow the ally's previous cell forever.
	if template == "cover_ally" and not ally.is_empty() and target.is_empty() and not support_needed(context,ally): return
	if context["task"]["role"] == "regroup" and not target.is_empty(): return
	var board: Dictionary = context["knowledge"]["terrain"]
	if not Tactical.in_battlefield(board, goal): return
	var start := int(context["self"]["cell"])
	var next := step_to(context, paths, goal, stop)
	if goal != start and next == start and Tactical.cell_distance(start, goal) > stop: return
	var canonical := {"template": template, "target_id": str(target.get("id", "")), "goal_cell": goal, "ally_id": str(ally.get("id", "")), "stop_distance": stop}
	if list.any(func(c): return Plan.same(c["canonical_plan"], canonical)): return
	var kind := "hold" if next == start else "reposition"
	var stage := "execute" if next == start else "approach"
	var execution_goal := goal
	var execution_stop := stop
	if template == "flank_then_engage" and start == goal and not target.is_empty():
		var front: bool = context["knowledge"]["allies"].any(func(a): return a.get("can_support",false) and a.get("role","") == "main_attack" and int(a.get("cell",-1)) >= 0 and Tactical.cell_distance(int(a["cell"]),int(target["cell"])) <= 3)
		if front:
			execution_goal = int(target["cell"])
			execution_stop = int(context["self"]["attack_range"])
			next = step_to(context,paths,execution_goal,execution_stop)
			stage = "execute"
			kind = "flank"
		else: stage = "wait_support"
	if template == "scout": kind = "scout"
	elif template == "rally":
		kind = "local_disengage" if int(context["self"]["contact"]["adjacent_enemies"]) > 0 else kind
		stage = "disengage" if kind == "local_disengage" else "recover" if next == start else "reposition"
	elif not target.is_empty() and next == start and template != "flank_then_engage": kind = "engage"
	elif template == "cover_ally" and next == start: kind = "support"
	# Slow terrain can require another round of credit before the first step.
	# Preserve its feasible direction for scoring without claiming a real move.
	var auth: Dictionary = context["authority"]
	var radius := 1 if auth["must_hold_objective"] else int(auth["region_radius"])
	if not Tactical.duty_step_allowed(start,next,int(auth["duty_cell"]),radius): return
	var progress_cell := next
	var path: Array = [start]
	if next != start: path.append(next)
	var credit := minf(2.0, float(context["self"].get("movement_credit", 0)) + float(context["self"]["mobility"]))
	if credit < 1: path = [start]
	if credit >= 2 and next != start and Tactical.terrain_class(start) == "plains" and Tactical.terrain_class(next) == "plains" and int(context["self"]["contact"]["adjacent_enemies"]) == 0:
		var options: Array = Array(Tactical.neighbors(next)).filter(func(c): return c != start and paths["first"].has(c) and not paths["occupied"].has(c) and Tactical.terrain_class(c) == "plains" and Tactical.cell_distance(c, goal) < Tactical.cell_distance(next, goal) and Tactical.cell_distance(next, goal) > stop)
		options.sort_custom(func(a,b): return Tactical.cell_distance(a,goal) < Tactical.cell_distance(b,goal) if Tactical.cell_distance(a,goal) != Tactical.cell_distance(b,goal) else a < b)
		# Landing adjacent to the pursued target is the point of a two-point
		# approach; only a different visible enemy's zone cancels the step.
		if not options.is_empty() and not context["knowledge"]["enemies"].any(func(e): return int(e.get("cell",-1)) >= 0 and (target.is_empty() or str(e.get("id","")) != str(target.get("id",""))) and Tactical.cell_distance(int(options[0]),int(e["cell"])) <= 1): path.append(int(options[0]))
	var action := {"type": kind, "tactical_contract": true, "goal_cell": execution_goal, "stop_distance": execution_stop, "path": path, "enemy": target.get("id", ""), "ally": ally.get("id", ""), "intent": Plan.templates()[template]["label"], "flank_ready":stage == "execute" and template == "flank_then_engage"}
	if path.size() > 2 and not Tactical.duty_step_allowed(int(path[1]),int(path[2]),int(auth["duty_cell"]),radius): path.pop_back()
	var candidate := {"id": "c%02d" % list.size(), "canonical_plan": canonical, "stage": stage, "action": action, "description": Plan.templates()[template]["label"], "target": target, "ally": ally, "next_cell": int(path[-1]), "reports": [], "eta_rounds": maxi(0, Tactical.cell_distance(start,goal) - stop)}
	candidate["progress_cell"] = progress_cell if credit < 1 else int(path[-1])
	action["position_goal"] = int(paths["destinations"].get(str(execution_goal)+":"+str(execution_stop),start))
	list.append(candidate)

static func generate(context: Dictionary) -> Array:
	var list: Array = []
	var paths := reach(context)
	var start := int(context["self"]["cell"])
	var own: Dictionary = context["self"]
	var board: Dictionary = context["knowledge"]["terrain"]
	add(list, context, paths, "hold_line", start)
	if context["authority"]["must_hold_objective"]: add(list,context,paths,"hold_line",int(context["authority"]["duty_cell"]),{},{},1)
	if context["task"]["role"] == "regroup" and int(context["task"]["anchor_cell"]) >= 0: add(list,context,paths,"hold_line",int(context["task"]["anchor_cell"]),{},{},1)
	var old: Dictionary = context["current_plan"]
	if not old.is_empty() and old.get("template", "") != "rally":
		var target := {}
		var ally := {}
		for e in context["knowledge"]["enemies"]:
			if e["id"] == old.get("target_id", ""): target = e
		for a in context["knowledge"]["allies"]:
			if a["id"] == old.get("ally_id", ""): ally = a
		var goal_current := true
		if old["template"] == "approach_objective" or (old["template"] == "hold_line" and context["task"]["role"] == "regroup"):
			goal_current = int(old["goal_cell"]) == int(context["task"]["anchor_cell"])
		if not target.is_empty():
			if old["template"] in ["advance","cover_ally"]: goal_current = int(old["goal_cell"]) == int(target["cell"])
			elif old["template"] == "fire_with_cover": goal_current = Tactical.cell_distance(int(old["goal_cell"]),int(target["cell"])) <= int(own["attack_range"])
			elif old["template"] == "flank_then_engage": goal_current = Tactical.cell_distance(int(old["goal_cell"]),int(target["cell"])) <= 3
		elif not ally.is_empty(): goal_current = int(old["goal_cell"]) == int(ally["cell"])
		if goal_current and (old.get("target_id", "") == "" or not target.is_empty()) and (old.get("ally_id", "") == "" or not ally.is_empty()): add(list,context,paths,old["template"],int(old["goal_cell"]),target,ally,int(old.get("stop_distance",0)))
	var near: Array = Array(Tactical.neighbors(start)).filter(func(c): return paths["first"].has(c))
	var enemy_limit := int(context["settings"].get("enemy_candidates",3))
	var selected_enemies: Array = context["knowledge"]["enemies"].slice(0,enemy_limit)
	# Bow-hunting cavalry must see a reachable archer even when closer infantry
	# would otherwise fill the whole enemy-candidate budget.
	if own["kind"] == "cavalry":
		for enemy in context["knowledge"]["enemies"]:
			if selected_enemies.size() >= enemy_limit + 2: break
			if selected_enemies.has(enemy): continue
			var enemy_cell := int(enemy.get("cell",-1))
			if enemy_cell < 0 or int(enemy["observed_round"]) < int(context["battle_round"]) - 1: continue
			if Roles.kind_from_mix(enemy.get("unit_mix_estimate",{})) != "archers": continue
			if Tactical.cell_distance(start,enemy_cell) > int(context["authority"]["region_radius"]): continue
			selected_enemies.append(enemy)
	for enemy in selected_enemies:
		var cell := int(enemy.get("cell", -1))
		if cell < 0: continue
		if int(enemy["observed_round"]) < int(context["battle_round"]) - 1: continue
		var template := "fire_with_cover" if int(own["attack_range"]) == 2 else "advance"
		add(list,context,paths,template,cell,enemy,{},int(own["attack_range"]))
		if context["task"]["role"] in ["flank", "raid_rear"] or own["kind"] == "cavalry":
			for side in [-2,2]:
				var flank := Tactical.cell_at(Tactical.column_of(cell)+side, Tactical.row_of(cell))
				add(list,context,paths,"flank_then_engage",flank,enemy)
		if int(own["attack_range"]) == 2 and Tactical.cell_distance(start,cell) <= 3:
			for option in near:
				if Tactical.cell_distance(option,cell) == 2: add(list,context,paths,"fire_with_cover",option,enemy)
	for ally in context["knowledge"]["allies"]:
		if int(ally.get("cell",-1)) < 0: continue
		if ally["id"] == context["task"].get("support_id", "") or ally.get("returning", false) or ally.get("local_state", "active") != "active":
			add(list,context,paths,"cover_ally",int(ally["cell"]),{},ally,1)
		if ally.get("needs_support",false):
			for enemy in context["knowledge"]["enemies"].slice(0,6):
				if int(enemy.get("cell",-1)) >= 0 and int(enemy["observed_round"]) >= int(context["battle_round"])-1 and Tactical.cell_distance(int(ally["cell"]),int(enemy["cell"])) <= 2:
					add(list,context,paths,"cover_ally",int(enemy["cell"]),enemy,ally,int(own["attack_range"]))
		if context["task"]["role"] in ["command","reserve"] and ally.get("role", "") == "main_attack" and not ally.get("returning",false):
			var slot := Tactical.cell_at(Tactical.column_of(int(ally["cell"])),Tactical.row_of(int(ally["cell"])) + int(context["side"]) * 3)
			add(list,context,paths,"hold_line",slot)
		if context["task"]["role"] == "reserve" and context["reserve_trigger"] and ally.get("needs_support",false): add(list,context,paths,"reserve_reinforce",int(ally["cell"]),{},ally,1)
	var objective := int(context["task"].get("anchor_cell", -1))
	if objective >= 0 and (context["task"]["role"] not in ["reserve","command"] or context.get("last_line",false) or (context["task"]["role"] == "command" and context.get("siege_approach",false))): add(list,context,paths,"approach_objective",objective,{}, {},int(context["task"].get("stop_distance",0)))
	if context["local_state"] in ["disengaging_local","repositioning","recovering"] and old.get("template","") == "rally": add(list,context,paths,"rally",int(old["goal_cell"]))
	var resting_here: bool = context["local_state"] == "recovering" and old.get("template","") == "rally" and int(old.get("goal_cell",-1)) == start and not own.get("under_fire",false) and int(own["contact"]["adjacent_enemies"]) == 0
	if context["authority"]["local_disengage"] and not context["authority"]["must_hold_objective"] and not resting_here:
		var options: Array = near.duplicate()
		for cell in paths["first"]:
			if int(paths["steps"][cell]) <= int(context["authority"]["local_retreat_cells"]) and int(paths["steps"][cell]) > 1: options.append(cell)
		var safe_values := {}
		for option in options: safe_values[option] = safety(context,option)
		options.sort_custom(func(a,b): return safe_values[a] > safe_values[b] if not is_equal_approx(safe_values[a],safe_values[b]) else a < b)
		for option in options.slice(0,3): add(list,context,paths,"rally",int(option))
		if context["local_state"] == "recovering": add(list,context,paths,"rally",start)
	# Bows evaluate a visible cavalry that could close within one legal round
	# (threat range 3) and keep withdrawal cells that increase the distance and
	# prefer friendly cover. Failure to find one simply leaves the pick to the
	# physical displacement option above; the bow never wanders blindly.
	if own["kind"] == "archers" and context["authority"]["local_disengage"] and not context["authority"]["must_hold_objective"] and not resting_here:
		var threat_now := Tactical.cavalry_threat(context["knowledge"]["enemies"],start)
		if threat_now < 99.0:
			var fallback: Array = []
			for cell in paths["first"]:
				var steps := int(paths["steps"][cell])
				if steps >= 1 and steps <= int(context["authority"]["local_retreat_cells"]): fallback.append(int(cell))
			fallback = fallback.filter(func(c): return Tactical.cavalry_threat(context["knowledge"]["enemies"],c) > threat_now)
			var cover_values := {}
			for option in fallback:
				var cover := 0
				for ally in context["knowledge"]["allies"]:
					if ally.get("can_support",false) and int(ally.get("cell",-1)) >= 0 and Tactical.cell_distance(int(option),int(ally["cell"])) <= 2: cover += 1
				cover_values[option] = cover
			fallback.sort_custom(func(a,b):
				var threat_a := Tactical.cavalry_threat(context["knowledge"]["enemies"],a)
				var threat_b := Tactical.cavalry_threat(context["knowledge"]["enemies"],b)
				if not is_equal_approx(threat_a,threat_b): return threat_a > threat_b
				if int(cover_values[a]) != int(cover_values[b]): return int(cover_values[a]) > int(cover_values[b])
				return a < b)
			for option in fallback.slice(0,3): add(list,context,paths,"rally",int(option))
	var limit := int(context["settings"].get("max_candidates",24))
	# Safety and the continuing plan must survive the budget, even with many targets.
	var preferred: Array = list.filter(func(c): return c["canonical_plan"]["template"] in ["rally","hold_line","approach_objective","reserve_reinforce"] or Plan.same(c["canonical_plan"],old))
	preferred = preferred.slice(0,limit)
	var positions := {}
	for c in preferred: positions[c["next_cell"]] = true
	for c in list:
		if preferred.size() >= limit: break
		if not positions.has(c["next_cell"]) and positions.size() >= int(context["settings"].get("max_positions",16)): continue
		if not preferred.has(c): preferred.append(c)
		positions[c["next_cell"]] = true
	for i in range(preferred.size()): preferred[i]["id"] = "c%02d" % i
	for cell in paths["occupied"]: paths["graph"].set_point_disabled(cell,false)
	return preferred.slice(0,limit)

static func support_needed(context: Dictionary, ally: Dictionary) -> bool:
	if not ally.get("needs_support",false) and not ally.get("returning",false) and ally.get("local_state","active") == "active": return false
	return context["knowledge"]["enemies"].any(func(e): return int(e.get("cell",-1)) >= 0 and int(e["observed_round"]) >= int(context["battle_round"])-1 and Tactical.cell_distance(int(ally["cell"]),int(e["cell"])) <= 3)

static func safety(context: Dictionary, cell: int) -> float:
	var gap := 6.0
	for enemy in context["knowledge"]["enemies"]:
		if int(enemy.get("cell",-1)) >= 0: gap = minf(gap,float(Tactical.cell_distance(cell,int(enemy["cell"]))))
	var cover := 0.0
	for ally in context["knowledge"]["allies"]:
		if ally.get("can_support",false) and int(ally.get("cell",-1)) >= 0 and Tactical.cell_distance(cell,int(ally["cell"])) <= 2: cover += 1
	return gap + minf(cover,2) - Tactical.cell_distance(cell,int(context["self"]["cell"])) * 0.1
