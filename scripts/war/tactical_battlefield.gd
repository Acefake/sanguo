extends RefCounted

const Battle = preload("res://scripts/war/officer_battle.gd")
const Combat = preload("res://scripts/war/combat_system.gd")
const GridScript = preload("res://scripts/rtk14_hex_grid.gd")
const ROLES := {"main_attack": "主攻", "flank": "侧翼", "support": "支援", "reserve": "预备队", "rear_guard": "掩护撤退", "withdraw": "撤退", "command": "中军统筹", "raid_rear": "绕后奇袭", "cut_supply": "截断粮道", "regroup": "归建"}
const Terrain = preload("res://scripts/war/battle_terrain.gd")
const Formation = preload("res://scripts/war/battle_formation.gd")
const Duel = preload("res://scripts/war/duel_system.gd")
const Feedback = preload("res://scripts/war/battle_feedback.gd")
const GRID_WIDTH := 220

# Main-map renderer, selection and tactical rules share one grid service.
static func grid() -> RefCounted:
	return GridScript.shared()


static func column_of(cell: int) -> int: return cell % GRID_WIDTH

static func row_of(cell: int) -> int: return cell / GRID_WIDTH

static func cell_at(column: int, row: int) -> int: return row * GRID_WIDTH + column


static func cell_distance(a: int, b: int) -> int:
	return grid().distance(a, b)


static func neighbors(cell: int) -> PackedInt32Array:
	return grid().neighbors(cell)


static func world_cell(cell: int) -> Vector2:
	return grid().center(cell)


static func offset_cell(board: Dictionary, dq: int, dr: int) -> int:
	return cell_at(int(board["center_column"]) + dq, int(board["center_row"]) + dr)


static func in_battlefield(board: Dictionary, cell: int) -> bool:
	if cell < 0:
		return false
	var column := column_of(cell)
	var row := row_of(cell)
	if column < int(board["min_column"]) or column > int(board["max_column"]) or row < int(board["min_row"]) or row > int(board["max_row"]):
		return false
	return grid().walkable(cell) and not board["blocked"].has(cell)


static func terrain_class(cell: int) -> String:
	return Terrain.from_code(grid().terrain(cell))

static func can_attack(war, army: Dictionary) -> bool:
	return not army.get("formation_locked", false) and Terrain.entry_factor(army, war.rules) > 0

static func cell_text(cell: int) -> String:
	return "列%d行%d" % [column_of(cell), row_of(cell)]

static func migrate_positions(war) -> void:
	var board: Dictionary = war.state.get("battlefield",{})
	if board.is_empty(): return
	# Old saves allowed code 13. Rebuild restrictions from the shared grid and
	# place only stranded legacy units on the nearest free bank, once on load.
	for q in range(int(board["min_column"]),int(board["max_column"])+1):
		for r in range(int(board["min_row"]),int(board["max_row"])+1):
			var cell := cell_at(q,r)
			if not grid().walkable(cell) and not board["blocked"].has(cell): board["blocked"].append(cell)
	var occupied := {}
	for army in war.active_armies():
		if army.has("tactical") and in_battlefield(board,int(army["tactical"]["cell"])): occupied[int(army["tactical"]["cell"])] = true
	for army in war.active_armies():
		if not army.has("tactical") or in_battlefield(board,int(army["tactical"]["cell"])): continue
		var start: int = army["tactical"]["cell"]
		var queue: Array = [start]
		var seen := {start:true}
		var cursor := 0
		var destination := -1
		while cursor < queue.size():
			var current: int = queue[cursor]
			cursor += 1
			if in_battlefield(board,current) and not occupied.has(current): destination = current; break
			for other in neighbors(current):
				if column_of(other) < int(board["min_column"]) or column_of(other) > int(board["max_column"]) or row_of(other) < int(board["min_row"]) or row_of(other) > int(board["max_row"]) or seen.has(other): continue
				seen[other] = true
				queue.append(other)
		if destination < 0: continue
		army["tactical"]["cell"] = destination
		army["tactical"]["lane"] = column_of(destination)
		for field in ["previous_cell","previous_goal","terrain_delay","flank_goal","attack_target"]: army["tactical"].erase(field)
		army["tactical"]["terrain_migrated_at"] = war.state["tick"]
		army["last_reason"] = "通行规则更新，部队就近归岸"
		occupied[destination] = true


static func setup(war) -> void:
	var source_grid: RefCounted = grid()
	var transform: Array = source_grid.transform
	var cities: Array = JSON.parse_string(FileAccess.get_file_as_string("res://assets/rtk14/cities_map.json"))
	var center := Vector2.ZERO
	for city in cities:
		if city["name"] == "小沛": center = Vector2(city["x"], city["z"])
	var column := int(round((center.x + 30 - float(transform[2])) / float(transform[0])))
	column -= posmod(column, 2)
	var row := int(round((center.y - 30 - float(transform[3])) / float(transform[1])))
	var board := {
		"grid": "global", "battle_id": "xiaopei:" + str(war.state["next_id"]), "started_at": war.state["tick"], "log": [],
		"anchor": cell_at(column, row),
		"center_column": column, "center_row": row,
		"min_column": column - 7, "max_column": column + 7,
		"min_row": row - 9, "max_row": row + 9,
		"blocked": [], "cell_m": float(transform[1]), "transform": transform,
	}
	for q in range(-7, 8):
		for r in range(-9, 10):
			var cell := cell_at(column + q, row + r)
			if not source_grid.walkable(cell):
				board["blocked"].append(cell)
	war.state["battlefield"] = board
	for army in war.active_armies(): army["battlefield_id"] = board["battle_id"]
	for faction in ["liu_bei", "yuan_shao"]:
		var armies: Array = war.active_armies(faction)
		armies.sort_custom(func(a, b): return int(a["skills"].get("带兵", 50)) + int(a["skills"].get("治军", 50)) > int(b["skills"].get("带兵", 50)) + int(b["skills"].get("治军", 50)))
		if armies.is_empty(): continue
		var commander: String = armies[0]["id"]
		var sign_y := -1 if faction == "liu_bei" else 1
		for index in range(armies.size()):
			var role := "main_attack" if index < 3 else "flank" if index < 5 else "support" if index < armies.size() - 2 else "reserve"
			var dq := 0
			var dr := 0
			if index < 3:
				dq = index - 1
				dr = sign_y
			elif index < 5:
				dq = -5 if index == 3 else 5
				dr = sign_y * 2
			elif role == "support":
				dq = index - 6
				dr = sign_y * 3
			else:
				dq = index - armies.size() + 2
				dr = sign_y * 5
			var desired := offset_cell(board, dq, dr)
			# Find the closest available passable deployment cell, preserving ranks.
			var occupied := {}
			for deployed in war.active_armies():
				if deployed.has("tactical"): occupied[int(deployed["tactical"]["cell"])] = true
			var options: Array = []
			for q in range(-7, 8):
				for r in range(-8, 9):
					if r * sign_y <= 0: continue
					var cell := offset_cell(board, q, r)
					if not board["blocked"].has(cell) and not occupied.has(cell): options.append(cell)
			options.sort_custom(func(a, b): return cell_distance(a, desired) < cell_distance(b, desired))
			if not options.is_empty(): desired = options[0]
			armies[index]["tactical"] = {"cell": desired, "role": role, "commander": commander, "support_id": armies[mini(index, 2)]["id"], "attack_target": "", "phase": "接近", "plan_until": 0, "change_reason": "主帅分配作战位置与职责", "blocked": false, "blocked_days": 0, "lane": column_of(desired), "withdraw_preparation": 0}


static func distance(a: Dictionary, b: Dictionary) -> int:
	return cell_distance(int(a["tactical"]["cell"]), int(b["tactical"]["cell"]))


static func attack_range(army: Dictionary) -> int:
	return 3 if army["tactical"]["role"] == "support" and int(army["units"].get("archers", 0)) > 0 else 1


static func targets(war, army: Dictionary) -> Array:
	var result: Array = []
	for enemy in war.active_armies():
		if enemy["faction"] != army["faction"] and army["intel"]["enemies"].has(enemy["id"]) and enemy.has("tactical"):
			result.append(enemy)
	result.sort_custom(func(a, b): return distance(army, a) < distance(army, b))
	return result


static func ordered_target(war, army: Dictionary) -> Dictionary:
	var available := targets(war, army)
	if available.is_empty(): return {}
	var tactical: Dictionary = army["tactical"]
	# Contact has priority; otherwise keep an observed target for a short order.
	# Merely becoming one tile nearer does not justify crossing another unit's line.
	var previous: Dictionary = war.state["armies"].get(tactical.get("attack_target", ""), {})
	if not previous.is_empty() and previous["status"] != "ended" and previous["faction"] != army["faction"] and army["intel"]["enemies"].has(previous["id"]):
		if distance(army, previous) <= attack_range(army): return previous
		if distance(army, available[0]) > attack_range(army) and int(war.state["tick"]) < int(tactical.get("target_until", 0)): return previous
	var selected: Dictionary = available[0]
	if selected["id"] != tactical.get("attack_target", ""):
		tactical["target_until"] = int(war.state["tick"]) + 4
	return selected


static func _path_step(start: int, goal: int, occupied: Dictionary, board: Dictionary, stop_distance: int) -> int:
	return grid().step_toward(start, goal, occupied, board, stop_distance)


static func contact_state(war, army: Dictionary) -> Dictionary:
	var attackers: Array = []
	var cover := 0
	for other in war.active_armies():
		if other["id"] == army["id"] or not other.has("tactical") or distance(army, other) > 1: continue
		if other["faction"] != army["faction"] and not bool(other["returning"]) and bool(war.orders_for(other)["engage"]): attackers.append(other["id"])
		elif other["faction"] == army["faction"] and not bool(other["returning"]) and other.get("operation", {}).get("role", "") == "rear_guard": cover += 1
	var flanked := false
	for first in attackers:
		for second in attackers:
			if first != second and distance(war.state["armies"][first], war.state["armies"][second]) >= 2: flanked = true
	return {"flanked": flanked, "engaged_by": attackers, "adjacent_enemies": attackers.size(), "covered_by": cover, "required_preparation": maxi(1, 1 + attackers.size() - mini(cover, 1)) + int(Formation.entry(army, war.rules).get("preparation", 0))}


static func _enemy_control(war, army: Dictionary) -> Dictionary:
	var controlled := {}
	for enemy in war.active_armies():
		if enemy["faction"] == army["faction"] or bool(enemy["returning"]) or not enemy.has("tactical") or not bool(war.orders_for(enemy)["engage"]): continue
		for cell in neighbors(int(enemy["tactical"]["cell"])): controlled[cell] = true
	return controlled


static func move(war) -> Dictionary:
	var board: Dictionary = war.state["battlefield"]
	var occupied := {}
	var armies: Array = war.active_armies()
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
		if army.has("tactical"): occupied[int(army["tactical"]["cell"])] = army["id"]
	# Alternate movement priority so one faction does not always claim free cells first.
	if int(war.state["tick"]) % 2 == 0: armies.reverse()
	for army in armies:
		if not army.has("tactical"): continue
		var tactical: Dictionary = army["tactical"]
		tactical.erase("terrain_delay")
		if army.get("formation_locked", false):
			tactical["phase"] = "变阵整顿"
			continue
		var contact := contact_state(war, army)
		tactical["contact"] = contact
		var start: int = int(tactical["cell"])
		var enemies := targets(war, army)
		var action: String = army["action"]["type"]
		var selected: String = str(army["action"].get("enemy", ""))
		var previous_target: Dictionary = war.state["armies"].get(tactical.get("attack_target", ""), {})
		if not previous_target.is_empty() and previous_target["status"] != "ended" and distance(army, previous_target) <= attack_range(army): selected = previous_target["id"]
		var enemy: Dictionary = war.state["armies"].get(selected, {})
		if enemy.is_empty() or enemy["status"] == "ended" or enemy["faction"] == army["faction"] or not army["intel"]["enemies"].has(enemy["id"]):
			enemy = enemies[0] if not enemies.is_empty() else {}
		if not enemies.is_empty() and distance(army, enemies[0]) <= 1 and (enemy.is_empty() or distance(army, enemy) > attack_range(army)):
			enemy = enemies[0]
		var siege_march: bool = war.state.get("corps", {}).get(army.get("corps_id", ""), {}).get("siege_approach", false) and tactical.has("siege_slot")
		var goal: int = start
		var stop_distance := 0
		tactical["attack_target"] = enemy.get("id", "")
		if bool(army["returning"]) or army.get("corps_task", {}).get("type", "") == "regroup":
			var exit_row: int = int(board["min_row"]) if army["faction"] == "liu_bei" else int(board["max_row"])
			goal = cell_at(clampi(column_of(start), int(board["min_column"]), int(board["max_column"])), exit_row)
			var regrouping: bool = army.get("corps_task", {}).get("type", "") == "regroup" and not bool(army["returning"])
			if regrouping:
				goal = int(war.state["armies"][war.state["corps"][army["corps_id"]]["root_id"]]["tactical"]["cell"])
				stop_distance = 1
			if not regrouping and (occupied.has(goal) or board["blocked"].has(goal)):
				for offset in range(1, 15):
					var exit_cell := cell_at(clampi(column_of(start) + (offset / 2 + 1) * (-1 if offset % 2 else 1), int(board["min_column"]), int(board["max_column"])), exit_row)
					if not occupied.has(exit_cell) and not board["blocked"].has(exit_cell):
						goal = exit_cell
						break
			tactical["phase"] = "脱离"
			if int(contact["adjacent_enemies"]) > 0:
				var preparation := int(tactical.get("withdraw_preparation", 0)) + 1
				tactical["withdraw_preparation"] = preparation
				army["organization"] = maxf(0, float(army["organization"]) - 3 * int(contact["adjacent_enemies"]))
				if preparation < int(contact["required_preparation"]):
					goal = start
					tactical["phase"] = "被夹击·准备突围" if bool(contact["flanked"]) else "接战·准备脱离"
			else: tactical["withdraw_preparation"] = 0
		elif siege_march:
			goal = int(tactical["siege_slot"])
			tactical["phase"] = "军团向城下集结" if start != goal else "城下待命"
			if start == goal: army["action"] = {"type": "hold"}
		elif action == "support" and army.get("operation", {}).get("role", "") == "rear_guard" and war.state["armies"].has(army["action"].get("ally", "")):
			var friend: Dictionary = war.state["armies"][army["action"]["ally"]]
			if friend["status"] != "ended" and friend.has("tactical"):
				var anchor: int = int(friend["tactical"]["cell"])
				goal = cell_at(column_of(anchor), clampi(row_of(anchor) + (1 if army["faction"] == "liu_bei" else -1), int(board["min_row"]) + 1, int(board["max_row"]) - 1))
				tactical["phase"] = "接应撤退友军"
		elif army.get("corps_task", {}).get("type", "") in ["raid_rear", "cut_supply"] and army["corps_task"].get("stage", "") != "attack" and int(army["corps_task"].get("cell", -1)) >= 0:
			goal = int(army["corps_task"]["cell"])
			stop_distance = 1 if army["corps_task"]["type"] == "cut_supply" else 0
			tactical["phase"] = "绕后行军" if army["corps_task"]["type"] == "raid_rear" else "奔袭粮道"
		elif action in ["engage", "pursue", "continue", "flank", "support"] and not enemy.is_empty():
			goal = int(army["intel"]["enemies"][enemy["id"]].get("tactical_cell", enemy["tactical"]["cell"]))
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
					goal = cell_at(clampi(int(tactical.get("lane", column_of(start))), int(board["min_column"]), int(board["max_column"])), clampi(row_of(anchor) + (-gap if army["faction"] == "liu_bei" else gap), int(board["min_row"]) + 1, int(board["max_row"]) - 1))
					if gap == 1: tactical["phase"] = "接应撤退友军"
					stop_distance = 0
		elif action in ["continue", "engage"] and army["mission_type"] == "capture" and board.get("objectives", {}).has(army["target"]) and war.store.city_state(army["target"]).get("faction", "") != army["faction"]:
			goal = int(board["objectives"][army["target"]])
			stop_distance = 2
			tactical["phase"] = "向城下推进" if cell_distance(start, goal) > 2 else "城下围攻"
		else:
			tactical["phase"] = "预备待命" if tactical["role"] == "reserve" else "驻守"
			if tactical["role"] in ["command", "reserve"] and not bool(army["returning"]) and lines.has(army.get("corps_id", "")):
				var line: int = lines[army["corps_id"]]
				var behind := -1 if army["faction"] == "liu_bei" else 1
				var slot := cell_at(clampi(column_of(line) + (2 if tactical["role"] == "reserve" else 0), int(board["min_column"]), int(board["max_column"])), clampi(row_of(line) + behind * 3, int(board["min_row"]) + 1, int(board["max_row"]) - 1))
				if cell_distance(start, slot) > 1 and in_battlefield(board, slot):
					goal = slot
					stop_distance = 1
					tactical["phase"] = "中军跟进阵线" if tactical["role"] == "command" else "预备队随阵跟进"
		# Melee is resolved from the current cell. Offensive circling while already
		# in contact is not free movement; a withdrawal/regroup must disengage first.
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
				tactical["phase"] = "停止追击·保持战线"
		elif enemy.is_empty() or not bool(enemy["returning"]): tactical.erase("pursuit_origin")
		occupied.erase(start)
		var known_occupied := {}
		for key in occupied:
			var occupant: Dictionary = war.state["armies"][occupied[key]]
			if occupant["faction"] == army["faction"] or int(army["intel"]["enemies"].get(occupant["id"], {}).get("observed_at", -1)) == int(war.state["tick"]): known_occupied[key] = occupant["id"]
		var next := _path_step(start, goal, known_occupied, board, stop_distance)
		if occupied.has(next): next = start
		if not bool(army["returning"]) and army.get("corps_task", {}).get("type", "") != "regroup" and next != start and next == int(tactical.get("previous_cell", -1)) and goal == int(tactical.get("previous_goal", -1)) and int(tactical.get("blocked_days", 0)) < 2:
			next = start
			tactical["phase"] = "等待通路·避免往返"
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
					tactical["phase"] = "接战牵制·需先脱离"
			# A front unit cannot abandon its supporting line to chase a distant target.
			var role: String = str(army.get("operation", {}).get("role", tactical["role"]))
			if role == "main_attack" and int(contact["adjacent_enemies"]) == 0 and next != start:
				var nearby := 0
				for friend in war.active_armies(str(army["faction"])):
					if friend["id"] != army["id"] and not friend["returning"] and friend.has("tactical") and cell_distance(next, int(friend["tactical"]["cell"])) <= 3: nearby += 1
				if nearby == 0:
					next = start
					tactical["phase"] = "等待友军跟进"
			if not siege_march and role in ["main_attack", "support", "reserve"] and absi(column_of(next) - int(tactical.get("lane", column_of(start)))) > 2:
				next = start
				tactical["phase"] = "保持阵线"
		tactical["previous_goal"] = goal
		if next != start:
			tactical["previous_cell"] = start
			tactical["moved_tick"] = int(war.state["tick"])
			var entered := terrain_class(next)
			if entered in ["mountains", "ford"]: tactical["terrain_delay"] = entered
		tactical["cell"] = next
		if next != start: army["fatigue"] = minf(100, float(army["fatigue"]) + Battle.fatigue_cost(army, 3))
		if action == "flank" and next == goal: tactical["flank_ready"] = true
		tactical["blocked"] = next == start and goal != start and cell_distance(start, goal) > stop_distance
		tactical["blocked_days"] = int(tactical.get("blocked_days", 0)) + 1 if tactical["blocked"] else 0
		occupied[next] = army["id"]
		motions[army["id"]] = {"before": army["location"].duplicate(true), "after": army["location"].duplicate(true)}
		if bool(army["returning"]) and (row_of(next) == int(board["min_row"]) or row_of(next) == int(board["max_row"])):
			army["location"] = {"node": army["home"], "edge": "", "progress": 0.0}
			war._finish(army, str(army.get("outcome", "撤退")))
	return motions


static func resolve(war) -> void:
	var damages := {}
	var dealt := {}
	var before := {}
	for unit in war.active_armies(): before[unit["id"]] = Combat.strength(unit)
	var attackers := {}
	# Apply one-time contact effects before the simultaneous damage snapshot.
	for army in war.active_armies():
		if not army.has("tactical") or army["returning"] or not war.orders_for(army)["engage"] or not can_attack(war, army): continue
		var contact_targets := targets(war, army)
		var selected_contact: String = str(army["tactical"].get("attack_target", ""))
		for enemy in contact_targets:
			if enemy["id"] == selected_contact:
				contact_targets.erase(enemy); contact_targets.push_front(enemy); break
		if not contact_targets.is_empty() and distance(army, contact_targets[0]) <= 1: war._battle_contact(army, contact_targets[0])
	for army in war.active_armies():
		if not army.has("tactical") or not can_attack(war, army): continue
		for enemy in targets(war, army):
			if distance(army, enemy) == 1 and can_attack(war, enemy):
				Duel.challenge(war, army, enemy)
				break
	# Leaving contact exposes a retreating unit to a parting attack.
	for army in war.active_armies():
		if not army.has("tactical") or (not bool(army["returning"]) and army.get("corps_task", {}).get("type", "") != "regroup"): continue
		for id in army["tactical"].get("contact", {}).get("engaged_by", []):
			var pursuer: Dictionary = war.state["armies"].get(id, {})
			if pursuer.is_empty() or pursuer["status"] == "ended" or bool(pursuer["returning"]) or distance(army, pursuer) <= 1: continue
			var loss: int = Combat.losses(pursuer, army, war.rules, terrain_class(army["tactical"]["cell"]), 0.5)
			damages[army["id"]] = int(damages.get(army["id"], 0)) + loss
			army["battle_factors"] = Feedback.factors(pursuer,army,war.rules,terrain_class(army["tactical"]["cell"]))
			pursuer["combat_tick"] = war.state["tick"]
			pursuer["tactical"]["phase"] = "追击脱离部队"
	for army in war.active_armies():
		if not army.has("tactical") or bool(army["returning"]) or army["action"]["type"] not in ["engage", "pursue", "support", "flank", "continue", "hold"] or not bool(war.orders_for(army)["engage"]) or not can_attack(war, army): continue
		var enemies := targets(war, army)
		var selected: String = str(army["tactical"].get("attack_target", ""))
		if war.state["armies"].has(selected):
			var preferred: Dictionary = war.state["armies"][selected]
			if enemies.has(preferred): enemies.erase(preferred); enemies.push_front(preferred)
		for enemy in enemies:
			var separation := distance(army, enemy)
			if army["action"]["type"] == "hold" and separation > 1: continue
			if separation > attack_range(army): continue
			var attacker: Dictionary = army.duplicate(true)
			if separation > 1:
				attacker["units"] = {"infantry": 0, "archers": army["units"]["archers"], "cavalry": 0}
				attacker["ranged_attack"] = true
			var flank: bool = army["action"]["type"] == "flank" and bool(army["tactical"].get("flank_ready", false)) and row_of(int(army["tactical"]["cell"])) == row_of(int(enemy["tactical"]["cell"]))
			var pressure := contact_state(war, enemy)
			var multiplier := (Formation.flank(army, war.rules) if flank else 1.0) * (1.25 if bool(enemy["returning"]) and separation <= 1 else 1.0) * (1.15 if bool(pressure["flanked"]) else 1.0)
			attacker["flanking_hit"] = flank or bool(pressure["flanked"])
			var terrain := terrain_class(enemy["tactical"]["cell"])
			var loss: int = Combat.losses(attacker, enemy, war.rules, terrain, war.rng.randf_range(0.9, 1.1) * multiplier)
			enemy["battle_factors"] = Feedback.factors(attacker, enemy, war.rules, terrain)
			if flank: Feedback.event(war, "侧击", army["name"] + "侧击" + enemy["name"], army["faction"])
			damages[enemy["id"]] = int(damages.get(enemy["id"], 0)) + loss
			if not dealt.has(army["id"]): dealt[army["id"]] = {}
			dealt[army["id"]][enemy["id"]] = float(loss)
			if not attackers.has(enemy["id"]): attackers[enemy["id"]] = []
			attackers[enemy["id"]].append(army)
			army["combat_tick"] = war.state["tick"]
			army["tactical"]["attack_target"] = enemy["id"]
			army["tactical"]["phase"] = "近战" if separation <= 1 else "远射"
			if flank: army["tactical"]["phase"] = "侧击"
			break
	# A unit being hit in melee counters unless it is withdrawing or ordered to ignore.
	# Contact may have moved into range after its order was chosen this morning.
	for id in damages.keys():
		var defender: Dictionary = war.state["armies"][id]
		if dealt.has(id) or defender["returning"] or not war.orders_for(defender)["engage"] or not can_attack(war, defender): continue
		for attacker in attackers.get(id, []):
			if distance(defender, attacker) > 1: continue
			var loss := Combat.losses(defender, attacker, war.rules, terrain_class(attacker["tactical"]["cell"]), war.rng.randf_range(0.9, 1.1))
			damages[attacker["id"]] = int(damages.get(attacker["id"], 0)) + loss
			attacker["battle_factors"] = Feedback.factors(defender,attacker,war.rules,terrain_class(attacker["tactical"]["cell"]))
			dealt[id] = {attacker["id"]: float(loss)}
			if not attackers.has(attacker["id"]): attackers[attacker["id"]] = []
			attackers[attacker["id"]].append(defender)
			defender["combat_tick"] = war.state["tick"]
			defender["tactical"]["attack_target"] = attacker["id"]
			defender["tactical"]["phase"] = "近战反击"
			break
	# Commit losses after every attack has been calculated from the same state.
	for id in damages:
		var army: Dictionary = war.state["armies"][id]
		var loss := Combat.apply_loss(army, damages[id], false, 0.0)
		army["daily_loss"] = loss
		army["daily_loss_tick"] = war.state["tick"]
		army["fatigue"] = minf(100, army["fatigue"] + Battle.fatigue_cost(army, 4, true))
		war._report(army, "战线交战", "%s在%s承受攻击，损失%d人。" % [army["name"], cell_text(int(army["tactical"]["cell"])) + "·" + Terrain.name_of(terrain_class(army["tactical"]["cell"])), loss], false)
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
		for other in war.active_armies():
			if other["id"] == id or other["returning"] or not other.has("tactical") or distance(unit, other) > 3: continue
			if other["faction"] == unit["faction"]: friendly += before[other["id"]]
			elif unit["intel"]["enemies"].has(other["id"]): hostile += before[other["id"]]
		unit["combat_tick"] = war.state["tick"]
		Combat.battle_morale(unit, mini(int(damages.get(id, 0)), int(before[id])), inflicted, int(before[id]), opponent_before, friendly, hostile, contact_state(war, unit)["flanked"])
	for id in participants: war._check_rout(war.state["armies"][id])
	for id in attackers:
		if war.state["armies"][id]["returning"] or war.state["armies"][id]["status"] == "ended":
			for winner in attackers[id]: war._battle_victory(winner)
	if not war.state["battlefield"].has("winner"):
		var camps := {"liu_bei": 0, "yuan_shao": 0}
		for army in war.active_armies():
			if not bool(army["returning"]): camps[army["faction"]] += Combat.strength(army)
		if camps["liu_bei"] == 0 or camps["yuan_shao"] == 0:
			var winner := "draw" if camps["liu_bei"] == 0 and camps["yuan_shao"] == 0 else "liu_bei" if camps["liu_bei"] > 0 else "yuan_shao"
			if winner == "yuan_shao" and war.state["battlefield"].get("objectives", {}).has("xiaopei") and war.store.city_state("xiaopei")["faction"] != winner:
				war.state["battlefield"]["field_winner"] = winner
				return
			war.state["battlefield"]["winner"] = winner
			war.state["battlefield"]["ended_at"] = war.state["tick"]
			for army in war.state["armies"].values():
				if army["faction"] == "liu_bei":
					war._report(army, "战局结果", "双方均已脱离战场。" if winner == "draw" else "%s控制战场，对方部队已撤退或覆没。" % ("我军" if winner == "liu_bei" else "敌军"), true)
					break
