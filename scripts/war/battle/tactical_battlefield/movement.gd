@abstract
class_name TacticalMovement
extends "res://scripts/war/battle/tactical_battlefield/targeting.gd"
## 战术移动：每回合的移动阶段（承诺移动、追击、破口入城步进）、职责区约束与骑兵威胁读数。


# Chase and breakthrough share the combat rules file. Both are bounded follow-ups
# on the same per-round movement budget; defaults keep older saves playable.
static func _chase_tuning(war) -> Dictionary:
	return Combat.settings(war.rules).get("chase", {})


# A visible, non-routing enemy cavalry's contact reach next round: whole steps
# it could legally walk on its own ground, plus the best-case fraction carry,
# plus contact range 1. The known view only: hidden squadrons must not steer a
# bow's plan, and rough ground must not be reported as a plains-speed threat.
static func authority_duty_cell(war, army: Dictionary, orders: Dictionary) -> int:
	var task: Dictionary = army.get("corps_task",{})
	var tactical: Dictionary = army.get("tactical",{})
	var anchor := int(task.get("cell",-1))
	var hold: bool = bool(orders.get("must_hold_objective",false)) or bool(task.get("must_hold_objective",false))
	if hold and anchor < 0:
		anchor = int(tactical.get("siege_slot",-1))
		var role := str(army.get("operation",{}).get("role",tactical.get("role","main_attack")))
		if anchor < 0 and role not in ["reserve","command"]:
			anchor = int(war.state.get("battlefield",{}).get("control_point",{}).get("cell",-1))
	if anchor < 0: anchor = int(army.get("battle_ai",{}).get("duty_cell",tactical.get("cell",-1)))
	return anchor


## 从 start 走到 next 是否守住职责区（半径 radius）；已在区外时只许靠近。
static func duty_step_allowed(start: int, next: int, duty: int, radius: int) -> bool:
	if cell_distance(next,duty) <= radius: return true
	# A new order can put an existing formation outside its new region. It may
	# return toward the duty position, but may not make that deviation larger.
	return cell_distance(start,duty) > radius and cell_distance(next,duty) < cell_distance(start,duty)


static func cavalry_reach(enemy: Dictionary) -> int:
	var mix: Dictionary = enemy.get("unit_mix_estimate",{})
	var enemy_cell := int(enemy.get("cell",-1))
	if enemy_cell < 0: return 1
	var mobility := Roles.mobility({"units":mix},terrain_class(enemy_cell))
	return floori(minf(2.0,0.99 + mobility)) + 1


## 敌骑下回合能接触到该格的最近距离；没有威胁时为 99。
static func cavalry_threat(enemies: Array, cell: int) -> float:
	var nearest := 99.0
	for enemy in enemies:
		var enemy_cell := int(enemy.get("cell",-1))
		if enemy_cell < 0 or bool(enemy.get("routing",false)): continue
		if Roles.kind_from_mix(enemy.get("unit_mix_estimate",{})) != "cavalry": continue
		var gap := cell_distance(cell,enemy_cell)
		if gap > cavalry_reach(enemy): continue
		nearest = minf(nearest,float(gap))
	return nearest


static func _path_step(start: int, goal: int, occupied: Dictionary, board: Dictionary, stop_distance: int) -> int:
	return grid().step_toward(start, goal, occupied, board, stop_distance)


# 破口入城专用步进：用共享网格的实际寻路绕开墙面，取路径第一步；每次只走一格。
# 攻城入城是突击动作，不按日常行军预算折算（器械部队 hold 时 mobility<1 也能进门）。
static func _entry_step(war, army: Dictionary, board: Dictionary, start: int, goal: int, occupied: Dictionary, legal: Dictionary) -> int:
	if goal == start: return start
	var route: PackedInt32Array = grid().find_path(start, goal, legal["blocked"])
	if route.size() < 2: return start
	var next := int(route[1])
	if occupied.has(next) or not in_battlefield(legal, next): return start
	return next


## 战术移动阶段：所有参战部队按军令和目标走一回合，返回本回合的移动记录（motions）。
static func move(war) -> Dictionary:
	migrate_positions(war)
	_enemy_control_cache_clear()
	clear_target_cache()
	var board: Dictionary = war.state["battlefield"]
	var occupied := {}
	var armies: Array = participants(war)
	var motions := {}
	var lines := {}
	# Use one start-of-day formation snapshot, unaffected by movement priority.
	for corps in war.state.get("corps", {}).values():
		var front: Array = []
		for id in corps["units"]:
			var unit: Dictionary = war.state["armies"][id]
			if unit["status"] != "ended" and not unit["returning"] and unit.has("tactical") and unit["corps_task"]["type"] == "main_attack": front.append(int(unit["tactical"]["cell"]))
		if not front.is_empty():
			var q := 0.0
			var r := 0.0
			for cell in front: q += column_of(cell); r += row_of(cell)
			lines[corps["id"]] = cell_at(int(round(q / front.size())), int(round(r / front.size())))
	for army in armies:
		if army.has("tactical") and not army["tactical"].get("placement_invalid",false): occupied[int(army["tactical"]["cell"])] = army["id"]
	# Alternate movement priority so one faction does not always claim free cells first.
	if int(war.state["tick"]) % 2 == 0: armies.reverse()
	for army in armies:
		if not army.has("tactical"): continue
		if army["tactical"].get("placement_invalid",false): continue
		if not war.ready(army): continue
		if army.get("action",{}).get("tactical_contract",false) and not army["returning"]:
			_move_committed(war,army,board,occupied,motions)
			continue
		var tactical: Dictionary = army["tactical"]
		tactical.erase("terrain_delay")
		var contact := contact_state(war, army)
		tactical["contact"] = contact
		var start: int = int(tactical["cell"])
		var enemies := targets(war, army)
		var action: String = army["action"]["type"]
		# Immediate contact outranks a stale route/support task, but obey disengage orders.
		if not army["returning"] and war.orders_for(army)["engage"] and action not in ["withdraw"] and army.get("corps_task",{}).get("type","") != "regroup" and float(army["morale"]) >= 35 and float(army["organization"]) >= 30:
			var adjacent := enemies.filter(func(e): return distance(army,e) == 1 and int(army["intel"]["enemies"].get(e["id"],{}).get("observed_at",-1)) == int(war.state["tick"]))
			adjacent.sort_custom(func(a,b): return war.state.get("corps",{}).get(a.get("corps_id",""),{}).get("root_id","") == a["id"] and war.state.get("corps",{}).get(b.get("corps_id",""),{}).get("root_id","") != b["id"])
			if not adjacent.is_empty():
				army["action"] = {"type":"engage","enemy":adjacent[0]["id"]}
				army["last_reason"] = "发现相邻敌军，优先处理眼前威胁"
				action = "engage"
				tactical["attack_target"] = adjacent[0]["id"]
		var selected: String = str(army["action"].get("enemy", ""))
		var previous_target: Dictionary = war.state["armies"].get(tactical.get("attack_target", ""), {})
		if not previous_target.is_empty() and previous_target["status"] != "ended" and _seen_now(war,army,previous_target) and distance(army, previous_target) <= attack_range(army): selected = previous_target["id"]
		var enemy: Dictionary = war.state["armies"].get(selected, {})
		if enemy.is_empty() or not enemy.has("tactical") or distance(army, enemy) >= 10000 or enemy["status"] == "ended" or not war.hostile(str(enemy["faction"]), str(army["faction"])) or not _seen_now(war,army,enemy):
			enemy = enemies[0] if not enemies.is_empty() else {}
		if not enemies.is_empty() and distance(army, enemies[0]) <= 1 and (enemy.is_empty() or distance(army, enemy) > attack_range(army)):
			enemy = enemies[0]
		var siege_march: bool = war.state.get("corps", {}).get(army.get("corps_id", ""), {}).get("siege_approach", false) and tactical.has("siege_slot")
		var city_approach: bool = enemy.is_empty() and army["mission_type"] == "capture" and board.get("objectives", {}).has(army["target"]) and war.hostile(str(war.store.city_state(army["target"]).get("faction", "")), str(army["faction"]))
		var goal: int = start
		var stop_distance := 0
		var entry_assault := false
		tactical["attack_target"] = enemy.get("id", "")
		if bool(army["returning"]) or army.get("corps_task", {}).get("type", "") == "regroup":
			var exit_row: int = int(board["min_row"]) if side_for(board, str(army["faction"])) < 0 else int(board["max_row"])
			goal = cell_at(clampi(column_of(start), int(board["min_column"]), int(board["max_column"])), exit_row)
			var regrouping: bool = army.get("corps_task", {}).get("type", "") == "regroup" and not bool(army["returning"])
			if regrouping:
				var commander: Dictionary = war.state["armies"].get(war.state["corps"][army["corps_id"]]["root_id"], {})
				# The commander can leave this battlefield before its detachment.
				# Follow the exit route until both share a tactical board again.
				if commander.get("status", "ended") != "ended" and distance(army, commander) < 10000:
					goal = int(commander["tactical"]["cell"])
					stop_distance = 1
				else:
					regrouping = false
			if not regrouping:
				var exit_board := Fort.movement_board(war,board,str(army["faction"]))
				var exits: Array = []
				for column in range(int(board["min_column"]),int(board["max_column"])+1):
					var exit_cell := cell_at(column,exit_row)
					if grid().walkable(exit_cell) and not occupied.has(exit_cell) and not exit_board["blocked"].has(exit_cell): exits.append(exit_cell)
				exits.sort_custom(func(a,b): return cell_distance(start,a) < cell_distance(start,b) if cell_distance(start,a) != cell_distance(start,b) else a < b)
				goal = int(exits[0]) if not exits.is_empty() else start
			tactical["phase"] = "脱离"
			if int(contact["adjacent_enemies"]) > 0:
				var preparation := int(tactical.get("withdraw_preparation", 0)) + 1
				tactical["withdraw_preparation"] = preparation
				army["organization"] = maxf(0, float(army["organization"]) - 3 * int(contact["adjacent_enemies"]))
				if preparation < int(contact["required_preparation"]):
					goal = start
					tactical["phase"] = "被夹击  准备突围" if bool(contact["flanked"]) else "接战  准备脱离"
			else: tactical["withdraw_preparation"] = 0
		elif action == "evade" and not enemy.is_empty():
			var firing_cell := int(army["intel"]["enemies"][enemy["id"]]["tactical_cell"])
			var safe_board := Fort.movement_board(war, board, str(army["faction"]))
			var best_gap := cell_distance(start, firing_cell)
			for option in neighbors(start):
				if not in_battlefield(safe_board, option) or safe_board["blocked"].has(option) or occupied.has(option): continue
				var threatened := false
				for sight in army["intel"]["enemies"].values():
					if int(sight.get("observed_at", -100)) == int(war.state["tick"]) and int(sight.get("tactical_cell", -1)) >= 0 and cell_distance(option, int(sight["tactical_cell"])) <= 1: threatened = true
				if threatened: continue
				var gap := cell_distance(option, firing_cell)
				if gap > best_gap:
					goal = option
					best_gap = gap
			tactical["phase"] = "中军避射  呼叫压制" if goal != start else "避射通路受阻"
		elif siege_march and (str(army.get("autonomy", {}).get("stance", "obey")) == "obey" or action in ["continue", "besiege", "engage"]):
			goal = int(tactical["siege_slot"])
			var entry := siege_entry_goal(war, army, board)
			if entry >= 0:
				# 破口已开：步兵/骑兵走缺口入城，弓兵保持城下射位。
				goal = entry
				entry_assault = true
				tactical["phase"] = "突入破口" if Fort.inside_city(board, start) != str(army["target"]) else "入城巷战"
			else:
				tactical["phase"] = "军团向城下集结" if start != goal else "城下待命"
			if start == goal: army["action"] = {"type": "hold"}
		elif action == "support" and army.get("operation", {}).get("role", "") == "rear_guard" and war.state["armies"].has(army["action"].get("ally", "")):
			var friend: Dictionary = war.state["armies"][army["action"]["ally"]]
			if friend["status"] != "ended" and friend.has("tactical"):
				var anchor: int = int(friend["tactical"]["cell"])
				goal = cell_at(column_of(anchor), clampi(row_of(anchor) + (1 if side_for(board, str(army["faction"])) < 0 else -1), int(board["min_row"]) + 1, int(board["max_row"]) - 1))
				tactical["phase"] = "接应撤退友军"
		elif army.get("corps_task", {}).get("type", "") in ["raid_rear", "cut_supply"] and army["corps_task"].get("stage", "") != "attack" and int(army["corps_task"].get("cell", -1)) >= 0:
			goal = int(army["corps_task"]["cell"])
			stop_distance = 1 if army["corps_task"]["type"] == "cut_supply" else 0
			tactical["phase"] = "绕后行军" if army["corps_task"]["type"] == "raid_rear" else "奔袭粮道"
		elif board.has("control_point") and army.get("corps_task", {}).get("type", "") in ["main_attack", "flank", "support"] and war.orders_for(army)["engage"] and (enemy.is_empty() or distance(army, enemy) > 3):
			goal = int(board["control_point"]["cell"])
			stop_distance = 1
			tactical["phase"] = "争夺" + str(board["control_point"]["name"])
		elif action in ["engage", "pursue", "continue", "flank", "support"] and not enemy.is_empty():
			goal = int(army["intel"]["enemies"].get(enemy["id"], {}).get("tactical_cell", enemy["tactical"]["cell"]))
			stop_distance = attack_range(army)
			tactical["phase"] = "支援接近" if stop_distance > 1 else "接近"
			if action == "flank":
				tactical["phase"] = "侧翼绕行"
				if tactical.get("flank_target", "") != enemy["id"]:
					tactical["flank_target"] = enemy["id"]
					tactical["flank_ready"] = false
					tactical.erase("flank_goal")
				if not tactical.get("flank_ready", false):
					if not tactical.has("flank_goal"):
						var side := -1 if int(tactical.get("lane", column_of(start))) < int(board["center_column"]) else 1
						var desired := cell_at(clampi(column_of(goal) + 2 * side, int(board["min_column"]), int(board["max_column"])), row_of(goal))
						var options: Array = []
						for q in range(int(board["min_column"]), int(board["max_column"]) + 1):
							for r in range(int(board["min_row"]), int(board["max_row"]) + 1):
								var option := cell_at(q, r)
								if in_battlefield(board, option) and not occupied.has(option): options.append(option)
						options.sort_custom(func(a, b): return cell_distance(a, desired) < cell_distance(b, desired))
						if not options.is_empty(): tactical["flank_goal"] = options[0]
					goal = int(tactical.get("flank_goal", start))
					stop_distance = 0
			if action == "support" and (distance(army, enemy) > attack_range(army) or army.get("operation", {}).get("role", "") == "rear_guard"):
				var friend: Dictionary = war.state["armies"].get(str(army["action"].get("ally", "")), {})
				if not friend.is_empty() and friend["status"] != "ended" and friend["faction"] == army["faction"]:
					var anchor: int = int(friend["tactical"]["cell"])
					var gap := 1 if army.get("operation", {}).get("role", "") == "rear_guard" else 2
					goal = cell_at(clampi(int(tactical.get("lane", column_of(start))), int(board["min_column"]), int(board["max_column"])), clampi(row_of(anchor) + (-gap if side_for(board, str(army["faction"])) < 0 else gap), int(board["min_row"]) + 1, int(board["max_row"]) - 1))
					if gap == 1: tactical["phase"] = "接应撤退友军"
					stop_distance = 0
		elif action in ["continue", "engage", "besiege"] and army["mission_type"] == "capture" and board.get("objectives", {}).has(army["target"]) and war.store.city_state(army["target"]).get("faction", "") != army["faction"]:
			var entry := siege_entry_goal(war, army, board)
			if entry >= 0:
				goal = entry
				entry_assault = true
				tactical["phase"] = "突入破口" if Fort.inside_city(board, start) != str(army["target"]) else "入城巷战"
			else:
				var approaches := Fort.approach(war, board, str(army["faction"]), str(army["target"]), start)
				goal = int(approaches[0]) if not approaches.is_empty() else start
				tactical["phase"] = "向城下推进" if start != goal else "城下围攻"
			stop_distance = 0
		else:
			tactical["phase"] = "预备待命" if tactical["role"] == "reserve" else "驻守"
			if tactical["role"] in ["command", "reserve"] and not bool(army["returning"]) and lines.has(army.get("corps_id", "")):
				var line: int = lines[army["corps_id"]]
				var behind := -1 if side_for(board, str(army["faction"])) < 0 else 1
				var slot := cell_at(clampi(column_of(line) + (2 if tactical["role"] == "reserve" else 0), int(board["min_column"]), int(board["max_column"])), clampi(row_of(line) + behind * 3, int(board["min_row"]) + 1, int(board["max_row"]) - 1))
				if cell_distance(start, slot) > 1 and in_battlefield(board, slot):
					goal = slot
					stop_distance = 1
					tactical["phase"] = "中军跟进阵线" if tactical["role"] == "command" else "预备队随阵跟进"
		# Hold a clear bow firing position; the ally support anchor must not
		# drag a ranged detachment into melee while it can already shoot.
		if not bool(army["returning"]) and not enemy.is_empty() and attack_range(army) == 2 and distance(army,enemy) == 2 and war.orders_for(army)["engage"] and action not in ["evade","withdraw"] and army.get("corps_task",{}).get("type","") not in ["regroup","rear_guard","raid_rear","cut_supply"] and Fort.line_of_sight(board,start,int(enemy["tactical"]["cell"])):
			goal = start
			tactical["phase"] = "保持射程  弓手待发"
			army["action"] = {"type":"engage","enemy":enemy["id"]}
		# Melee units must disengage before leaving adjacent enemy control.
		if not bool(army["returning"]) and army.get("corps_task", {}).get("type", "") != "regroup" and int(contact["adjacent_enemies"]) > 0:
			goal = start
			tactical["phase"] = "接战固守"
			if action == "flank": tactical["flank_ready"] = true
		# Pursuit is bounded around the last battle line, including flank troops.
		# A retreating opponent must not drag the whole formation to the map edge.
		if not siege_march and not enemy.is_empty() and bool(enemy["returning"]) and not bool(army["returning"]) and army.get("corps_task", {}).get("type", "") not in ["raid_rear", "cut_supply", "regroup", "rear_guard"]:
			if not tactical.has("pursuit_origin"): tactical["pursuit_origin"] = start
			if not war.orders_for(army)["pursue"] or cell_distance(start, int(tactical["pursuit_origin"])) >= 3:
				goal = start
				tactical["phase"] = "停止追击  保持战线"
		elif enemy.is_empty() or not bool(enemy["returning"]): tactical.erase("pursuit_origin")
		# 破口开放后，被 hold/驻守钉在城下的部队也改走缺口入城；
		# 契约行动（tactical_contract）在 _move_committed 中有同类规则。
		if goal == start and not bool(army["returning"]) and action in ["continue", "engage", "besiege"] and army.get("corps_task", {}).get("type", "") != "regroup" and bool(war.orders_for(army)["engage"]) and str(army["mission_type"]) == "capture":
			var entry_node := str(army["target"])
			if Fort.distance_to_wall(board, entry_node, start) <= 2 or Fort.inside_city(board, start) == entry_node:
				var entry_goal := siege_entry_goal(war, army, board)
				if entry_goal >= 0 and entry_goal != start:
					goal = entry_goal
					entry_assault = true
					stop_distance = 0
					tactical["phase"] = "突入破口"
		occupied.erase(start)
		var known_occupied := {}
		for key in occupied:
			var occupant: Dictionary = war.state["armies"][occupied[key]]
			if occupant["faction"] == army["faction"] or int(army["intel"]["enemies"].get(occupant["id"], {}).get("observed_at", -1)) == int(war.state["tick"]): known_occupied[key] = occupant["id"]
		var legal_board := Fort.movement_board(war, board, str(army["faction"]))
		var next := _entry_step(war, army, board, start, goal, known_occupied, legal_board) if entry_assault else _path_step(start, goal, known_occupied, legal_board, stop_distance)
		if occupied.has(next): next = start
		if not bool(army["returning"]) and army.get("corps_task", {}).get("type", "") != "regroup" and next != start and next == int(tactical.get("previous_cell", -1)) and goal == int(tactical.get("previous_goal", -1)) and int(tactical.get("blocked_days", 0)) < 2:
			next = start
			tactical["phase"] = "等待通路  避免往返"
		if (bool(army["returning"]) or army.get("corps_task", {}).get("type", "") == "regroup") and int(contact["adjacent_enemies"]) > 0:
			var controlled := _enemy_control(war, army)
			if controlled.has(next) and int(tactical.get("withdraw_preparation", 0)) < int(contact["required_preparation"]) + 1: next = start
		elif not bool(army["returning"]):
			if int(contact["adjacent_enemies"]) > 0 and next != start:
				var keeps_contact := false
				for id in contact["engaged_by"]:
					if cell_distance(next, int(war.state["armies"][id]["tactical"]["cell"])) <= 1: keeps_contact = true
				if not keeps_contact:
					next = start
					tactical["phase"] = "接战牵制  需先脱离"
			# A front unit cannot abandon its supporting line to chase a distant target.
			var role: String = str(army.get("operation", {}).get("role", tactical["role"]))
			var requires_line: bool = war.state.get("corps", {}).get(army.get("corps_id", ""), {}).get("units", []).any(func(id): return id != army["id"] and war.state["armies"].get(id, {}).get("status", "ended") != "ended" and not war.state["armies"][id]["returning"] and distance(army,war.state["armies"][id]) < 10000)
			if requires_line and not city_approach and role == "main_attack" and int(contact["adjacent_enemies"]) == 0 and next != start:
				var nearby := 0
				for friend in war.active_armies(str(army["faction"])):
					if friend["id"] != army["id"] and not friend["returning"] and friend.has("tactical") and cell_distance(next, int(friend["tactical"]["cell"])) <= 3: nearby += 1
				if nearby == 0 and int(tactical.get("blocked_days",0)) < 3:
					next = start
					tactical["phase"] = "等待友军跟进"
			if not siege_march and not city_approach and role in ["main_attack", "support", "reserve"] and absi(column_of(next) - int(tactical.get("lane", column_of(start)))) > 2:
				# A deployment lane is a cohesion guide, not a permanent wall.
				# Let a blocked front shift with nearby allies through narrow terrain.
				var can_shift := int(tactical.get("blocked_days", 0)) >= 3
				var supported := false
				for friend in war.active_armies(str(army["faction"])):
					if friend["id"] == army["id"] or friend["returning"] or not friend.has("tactical"): continue
					if cell_distance(next, int(friend["tactical"]["cell"])) <= 3: supported = true
				if can_shift and (supported or not requires_line):
					tactical["lane"] = column_of(next)
					tactical["phase"] = "调整通路  协同接敌"
				else:
					next = start
					tactical["phase"] = "保持阵线"
		tactical["previous_goal"] = goal
		var points := minf(2.0,float(tactical.get("movement_credit",0))+preload("res://scripts/war/battle/troop_roles.gd").mobility(army,terrain_class(start),war.rules))
		var path: Array = [start]
		if next != start and points < 1.0: next = start
		if next != start:
			path.append(next)
			points -= 1.0
			# Extra cavalry step is checked separately; never leap over units, rough
			# ground, or a visible enemy's adjacent zone of control.
			if points >= 1.0 and terrain_class(start) == "plains" and terrain_class(next) == "plains" and int(contact["adjacent_enemies"]) == 0 and not enemies.any(func(e): return cell_distance(next,int(e["tactical"]["cell"])) <= attack_range(army)):
				var extra := _path_step(next,goal,known_occupied,legal_board,stop_distance)
				if extra != next and not occupied.has(extra) and terrain_class(extra) == "plains" and in_battlefield(legal_board,extra):
					next = extra
					path.append(extra)
					points -= 1.0
		points = maxf(points, 0.0)
		tactical["movement_credit"] = minf(points,0.99) if goal != start else 0.0
		# The true remaining budget must survive the 0.99 cap above: the unified
		# chase phase spends whole steps and must see a real 1.0, not 0.99.
		tactical["round_points"] = minf(points,2.0)
		tactical["round_marker"] = int(war.state["tick"])
		tactical["move_path"] = path
		if next != start:
			tactical["previous_cell"] = start
			tactical["moved_tick"] = int(war.state["tick"])
			var entered := terrain_class(next)
			if entered in ["mountains", "ford"]: tactical["terrain_delay"] = entered
		tactical["cell"] = next
		if next != start: army["fatigue"] = minf(100, float(army["fatigue"]) + Process.fatigue_cost(army, 3*maxi(1,path.size()-1)))
		if action == "flank" and next == goal: tactical["flank_ready"] = true
		tactical["blocked"] = next == start and goal != start and cell_distance(start, goal) > stop_distance
		tactical["blocked_days"] = int(tactical.get("blocked_days", 0)) + 1 if tactical["blocked"] else 0
		occupied[next] = army["id"]
		motions[army["id"]] = {"before": army["location"].duplicate(true), "after": army["location"].duplicate(true)}
		if bool(army["returning"]) and (row_of(next) == int(board["min_row"]) or row_of(next) == int(board["max_row"])):
			if war.store.battle_test:
				army["location"] = {"node": army["home"], "edge": "", "progress": 0.0}
				war._finish(army, str(army.get("outcome", "撤退")))
			else:
				army.erase("tactical")
				army.erase("battlefield_id")
				war._start_return(army)
	# One unified follow-up after every normal move, so both movement orders can
	# catch a target that walked away during this same round. Refresh positions
	# before following so the pursuit uses the current occupied cells.
	var direct := _fresh_sightings(war)
	_chase_phase(war, board, occupied, direct)
	return motions


# Refresh every hostile participant after movement; distance does not hide units.
static func _fresh_sightings(war) -> Dictionary:
	var result := {}
	for army in participants(war):
		if not army.has("tactical") or army["tactical"].get("placement_invalid", false): continue
		var seen := {}
		for enemy in participants(war):
			if enemy["id"] == army["id"] or not enemy.has("tactical"): continue
			if enemy["tactical"].get("placement_invalid", false): continue
			if not war.hostile(str(enemy["faction"]), str(army["faction"])): continue
			var enemy_id := str(enemy["id"])
			seen[enemy_id] = true
			army["intel"]["enemies"][enemy_id] = war.enemy_intel(enemy)
		result[str(army["id"])] = seen
	return result


static func _move_committed(war, army: Dictionary, board: Dictionary, occupied: Dictionary, motions: Dictionary) -> void:
	var tactical: Dictionary = army["tactical"]
	var action: Dictionary = army["action"]
	var start := int(tactical["cell"])
	var current := start
	var contact := contact_state(war,army)
	var legal_board := Fort.movement_board(war,board,str(army["faction"]))
	var path: Array = [start]
	var points := minf(2.0,float(tactical.get("movement_credit",0)) + preload("res://scripts/war/battle/troop_roles.gd").mobility(army,terrain_class(start),war.rules))
	var kind := str(action["type"])
	var task: Dictionary = army.get("corps_task",{})
	var orders: Dictionary = war.orders_for(army)
	var duty := authority_duty_cell(war,army,orders)
	var radius := 1 if orders.get("must_hold_objective",false) or task.get("must_hold_objective",false) else int(task.get("region_radius",16))
	tactical.erase("terrain_delay")
	tactical["contact"] = contact
	tactical["phase"] = str(action.get("intent","临机行动"))
	var ready_to_leave := int(contact["adjacent_enemies"]) == 0
	if kind == "local_disengage":
		if not war.orders_for(army).get("local_disengage",war.orders_for(army)["retreat"]): ready_to_leave = false
		elif not ready_to_leave:
			tactical["withdraw_preparation"] = int(tactical.get("withdraw_preparation",0)) + 1
			army["organization"] = maxf(0,float(army["organization"])-3*int(contact["adjacent_enemies"]))
			ready_to_leave = int(tactical["withdraw_preparation"]) >= int(contact["required_preparation"])
			tactical["phase"] = "准备局部脱离" if not ready_to_leave else "局部后撤"
	else:
		tactical["withdraw_preparation"] = 0
	for value in action.get("path",[]).slice(1):
		var next := int(value)
		if points < 1 or occupied.has(next) or cell_distance(current,next) != 1 or not in_battlefield(legal_board,next): break
		if not ready_to_leave: break
		if not duty_step_allowed(current,next,duty,radius): break
		# 已入城的部队不再被机动契约拉回城外：巷战部队要撤离必须走
		# withdraw / local_disengage / regroup 契约，普通机动不能自行退出。
		if kind not in ["local_disengage", "withdraw", "evade", "regroup"] and not army["returning"] and Fort.inside_city(board, current) != "" and Fort.inside_city(board, next) == "":
			break
		if kind == "local_disengage" and _enemy_control(war,army).has(next) and int(tactical.get("withdraw_preparation",0)) < int(contact["required_preparation"])+1: break
		occupied.erase(current)
		current = next
		occupied[current] = army["id"]
		points -= 1
		path.append(current)
	# 破口开放后，围城契约不再把部队钉在城下：向缺口再推进一格（骑兵同样可以
	# 经破口入城；弓兵由 siege_entry_goal 返回 -1 保留城下射位）。只在城下
	# 短距内生效，且后撤/脱离类契约不抢路。
	var entry_intent: bool = str(action.get("template", "")) == "approach_objective"
	if points >= 1.0 and entry_intent and not army["returning"] and bool(war.orders_for(army)["engage"]) and kind in ["reposition", "continue", "besiege", "engage"] and str(army.get("mission_type", "")) == "capture":
		var siege_node := str(army["target"])
		if Fort.distance_to_wall(board, siege_node, current) <= 2 or Fort.inside_city(board, current) == siege_node:
			var entry := siege_entry_goal(war, army, board)
			if entry >= 0 and entry != current:
				var step := _entry_step(war, army, board, current, entry, occupied, legal_board)
				if step != current and duty_step_allowed(current,step,duty,radius):
					occupied.erase(current)
					current = step
					occupied[current] = army["id"]
					points = maxf(0.0, points - 1.0)
					path.append(current)
					tactical["previous_cell"] = start
					tactical["moved_tick"] = int(war.state["tick"])
					tactical["phase"] = "入城巷战" if Fort.inside_city(board, current) == siege_node else "突入破口"
					if terrain_class(current) in ["mountains","ford"]: tactical["terrain_delay"] = terrain_class(current)
	var selected := str(action.get("enemy",""))
	var target: Dictionary = war.state["armies"].get(selected,{})
	tactical["attack_target"] = selected if not target.is_empty() and target["status"] != "ended" and _seen_now(war,army,target) else ""
	tactical["move_path"] = path
	tactical["flank_ready"] = bool(action.get("flank_ready",false))
	tactical["cell"] = current
	tactical["previous_goal"] = int(action.get("goal_cell",start))
	tactical["movement_credit"] = minf(points,0.99) if int(action.get("goal_cell",start)) != start else 0
	# Exact remainder for this round, surviving the 0.99 fraction cap. The chase
	# phase and the breakthrough step both spend from this one pool.
	tactical["round_points"] = minf(points,2.0)
	tactical["round_marker"] = int(war.state["tick"])
	if current != start:
		tactical["previous_cell"] = start
		tactical["moved_tick"] = int(war.state["tick"])
		army["fatigue"] = minf(100,float(army["fatigue"]) + Process.fatigue_cost(army,3*(path.size()-1)))
		if terrain_class(current) in ["mountains","ford"]: tactical["terrain_delay"] = terrain_class(current)
	tactical["blocked"] = current == start and action.get("path",[]).size() > 1 and points >= 1
	tactical["blocked_days"] = int(tactical.get("blocked_days",0))+1 if tactical["blocked"] else 0
	if tactical["blocked"]: tactical["phase"] = "通路或接触受阻，下轮重新判断"
	motions[army["id"]] = {"before":army["location"].duplicate(true),"after":army["location"].duplicate(true)}
	if army.has("battle_ai") and not army["battle_ai"]["history"].is_empty():
		army["battle_ai"]["history"][-1]["executed_cell"] = current
		army["battle_ai"]["history"][-1]["blocked"] = tactical["blocked"]


# A bounded follow-up across every formation: at most one extra follow per unit
# per round, spending only the real points left in this round's pool. The target
# must be in this round's fresh direct-sight set; the live cell is read only for
# units in that set, never from hidden positions.
static func _chase_phase(war, board: Dictionary, occupied: Dictionary, direct: Dictionary) -> void:
	var tuning := _chase_tuning(war)
	if not bool(tuning.get("enabled", true)): return
	var max_steps := maxi(1,int(tuning.get("max_steps", 2)))
	var tick := int(war.state["tick"])
	var armies := participants(war)
	if tick % 2 == 1: armies.reverse()
	for army in armies:
		if not army.has("tactical"): continue
		if army["tactical"].get("placement_invalid",false): continue
		if army.get("status","") == "ended" or bool(army.get("returning",false)): continue
		if not war.ready(army): continue
		if attack_range(army) != 1: continue
		var tactical: Dictionary = army["tactical"]
		if int(tactical.get("round_marker",-1)) != tick: continue
		if int(tactical.get("chase_marker",-1)) == tick: continue
		if float(army["morale"]) < 35 or float(army["organization"]) < 30: continue
		var orders: Dictionary = war.orders_for(army)
		if not bool(orders.get("engage", true)): continue
		var ai: Dictionary = army.get("battle_ai", {})
		if str(ai.get("plan",{}).get("template","")) == "rally": continue
		if str(ai.get("local_state","active")) in ["disengaging_local","repositioning","recovering"]: continue
		var target_id := str(army.get("action",{}).get("enemy", tactical.get("attack_target","")))
		if target_id == "": continue
		var visible_now: Dictionary = direct.get(str(army["id"]), {})
		if not visible_now.has(target_id): continue
		var target: Dictionary = war.state["armies"].get(target_id, {})
		if target.is_empty() or target.get("status","") == "ended" or int(Combat.strength(target)) <= 0: continue
		if distance(army,target) >= 10000: continue
		if shield_between(war, army, target): continue
		# The record was refreshed by _fresh_sightings on the compliant hit above.
		var goal := int(target["tactical"]["cell"])
		if goal < 0: continue
		if bool(target.get("returning",false)) and not bool(orders.get("pursue", true)): continue
		var contact := contact_state(war, army)
		if int(contact["adjacent_enemies"]) > 0: continue
		var start := int(tactical["cell"])
		if cell_distance(start, goal) <= attack_range(army): continue
		var remaining := float(tactical.get("round_points", 0.0))
		var steps := mini(int(floor(remaining)), max_steps)
		if steps < 1: continue
		# Other directly visible enemies keep their adjacency wall; only the chased
		# unit may be closed on this round.
		var other_enemy_cells := {}
		for enemy_id in visible_now:
			if enemy_id == target_id: continue
			var other: Dictionary = war.state["armies"].get(str(enemy_id), {})
			if other.is_empty() or not other.has("tactical") or bool(other.get("returning",false)): continue
			other_enemy_cells[int(other["tactical"]["cell"])] = true
		var task: Dictionary = army.get("corps_task", {})
		var duty := int(task.get("cell", -1))
		if duty < 0: duty = int(tactical.get("duty_cell", start))
		var hold: bool = bool(orders.get("must_hold_objective", false)) or bool(task.get("must_hold_objective", false))
		var radius := int(task.get("region_radius", 16))
		# A hold order never follows; the unit keeps its post even against a lure.
		if hold: continue
		var legal_board := Fort.movement_board(war,board,str(army["faction"]))
		var path: Array = []
		var current := start
		for step in range(steps):
			if cell_distance(current, goal) <= attack_range(army): break
			var next := _path_step(current, goal, occupied, legal_board, attack_range(army))
			if next == current or occupied.has(next) or not in_battlefield(legal_board,next): break
			if cell_distance(next, duty) > radius: break
			var screened := false
			for cell in other_enemy_cells:
				if cell_distance(next, int(cell)) <= 1: screened = true; break
			if screened: break
			occupied.erase(current)
			current = next
			occupied[current] = army["id"]
			path.append(current)
		if path.is_empty(): continue
		tactical["chase_marker"] = tick
		var routes: Array = tactical.get("move_path", [start])
		if routes.is_empty() or int(routes[-1]) != start: routes = [start]
		for cell in path: routes.append(int(cell))
		tactical["move_path"] = routes
		tactical["cell"] = current
		tactical["previous_cell"] = start
		tactical["moved_tick"] = tick
		tactical["phase"] = "追击跟进"
		if terrain_class(current) in ["mountains","ford"]: tactical["terrain_delay"] = terrain_class(current)
		army["fatigue"] = minf(100, float(army["fatigue"]) + Process.fatigue_cost(army, 3*path.size()))
		tactical["round_points"] = maxf(0.0, remaining - float(path.size()))
		tactical["movement_credit"] = minf(float(tactical["round_points"]),0.99)
		tactical["blocked"] = false
		tactical["blocked_days"] = 0
		if army.has("battle_ai") and not army["battle_ai"]["history"].is_empty():
			var record: Dictionary = army["battle_ai"]["history"][-1]
			record["executed_cell"] = current
			record["chase_cells"] = path.size()
