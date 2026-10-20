extends RefCounted

const Process = preload("res://scripts/officers/officer_process.gd")
const Combat = preload("res://scripts/war/combat_system.gd")
const GridScript = preload("res://scripts/rtk14_hex_grid.gd")
const ROLES := {"main_attack": "主攻", "flank": "侧翼", "support": "支援", "reserve": "预备队", "rear_guard": "掩护撤退", "withdraw": "撤退", "command": "中军统筹", "raid_rear": "绕后奇袭", "cut_supply": "截断粮道", "regroup": "归建"}
const Terrain = preload("res://scripts/war/battle_terrain.gd")
const Duel = preload("res://scripts/war/duel_system.gd")
const Feedback = preload("res://scripts/war/battle_feedback.gd")
const Edges = preload("res://scripts/war/officer_edges.gd")
const GRID_WIDTH := 220
const Fort = preload("res://scripts/war/city_fortifications.gd")
const Roles = preload("res://scripts/war/troop_roles.gd")
const Defense = preload("res://scripts/war/city_defense.gd")

static func board_for(war, army: Dictionary) -> Dictionary:
	var id := str(army.get("battlefield_id", ""))
	return war.state.get("battlefields", {}).get(id, war.state.get("battlefield", {}))

static func participants(war, board: Dictionary = {}) -> Array:
	if board.is_empty(): board = war.state.get("battlefield", {})
	var id := str(board.get("battle_id", ""))
	return war.active_armies().filter(func(army): return army.has("tactical") and str(army.get("battlefield_id", id)) == id)

static func side_for(board: Dictionary, faction: String) -> int:
	return int(board.get("sides", {}).get(faction, -1 if faction == "liu_bei" else 1))

static func can_enter(war, army: Dictionary, cell: int) -> bool:
	var board := board_for(war, army)
	return not board.is_empty() and in_battlefield(Fort.movement_board(war, board, str(army["faction"])), cell)

# Exploiting a broken or withdrawing enemy. Read from campaign_rules.json via combat.flank
# so the strike bonuses stay in one place; these are the fallback defaults.
static func _flank_tuning(war) -> Dictionary:
	return Combat.settings(war.rules).get("flank", {})

static func _flank_num(war, key: String, fallback: float) -> float:
	return float(_flank_tuning(war).get(key, fallback))

# Chase and breakthrough share the combat rules file. Both are bounded follow-ups
# on the same per-round movement budget; defaults keep older saves playable.
static func _chase_tuning(war) -> Dictionary:
	return Combat.settings(war.rules).get("chase", {})

static func _breakthrough_tuning(war) -> Dictionary:
	return Combat.settings(war.rules).get("breakthrough", {})

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

# Main-map renderer, selection and tactical rules share one grid service.
static func grid() -> RefCounted:
	return GridScript.shared()


static func column_of(cell: int) -> int: return cell % GRID_WIDTH

static func row_of(cell: int) -> int: return cell / GRID_WIDTH

static func cell_at(column: int, row: int) -> int: return row * GRID_WIDTH + column


static func cell_distance(a: int, b: int) -> int:
	return grid().distance(a, b)


# The unit this one is notionally covering. The old expression indexed armies[index]
# itself, so every formation reported its own id as its support and the AI prompt and
# the intel panel showed "协同对象：<自己>".
static func _support_id_for(armies: Array, index: int) -> String:
	if armies.size() < 2: return ""
	if index < armies.size() - 1: return str(armies[index + 1]["id"])
	return str(armies[maxi(index - 1, 0)]["id"])


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
	return not army.get("tactical",{}).get("placement_invalid",false) and Terrain.entry_factor(army, war.rules) > 0

# 城防内外互不相通：同处城内或同处城外的部队才能互相攻击。
# 破口只是开放的通道；攻方必须真正从破口入城，才能与城内部队交战，
# 城内部队也必须出城（或入城）才会成为目标。城内目标不会被外部弓箭射穿。
static func shield_between(war, army: Dictionary, enemy: Dictionary) -> bool:
	if not army.has("tactical") or not enemy.has("tactical"): return false
	var board: Dictionary = board_for(war, army)
	return Fort.inside_city(board, int(army["tactical"]["cell"])) != Fort.inside_city(board, int(enemy["tactical"]["cell"]))

# Shared by melee damage and duel eligibility, including contact during repositioning.
static func can_engage(war, army: Dictionary) -> bool:
	return army.has("tactical") and not bool(army.get("returning", false)) and army.get("action", {}).get("type", "") in ["engage", "pursue", "support", "flank", "continue", "hold", "reposition"] and bool(war.orders_for(army)["engage"]) and can_attack(war, army)

static func cell_text(cell: int) -> String:
	return "列%d行%d" % [column_of(cell), row_of(cell)]

static func migrate_positions(war) -> void:
	var board: Dictionary = war.state.get("battlefield",{})
	if board.is_empty(): return
	var normalized: Array = []
	for value in board.get("blocked", []):
		var cell := int(value)
		if not normalized.has(cell): normalized.append(cell)
	board["blocked"] = normalized
	Fort.attach(war, board)
	# Old saves allowed code 13. Rebuild restrictions from the shared grid and
	# place only stranded legacy units on the nearest free bank, once on load.
	for q in range(int(board["min_column"]),int(board["max_column"])+1):
		for r in range(int(board["min_row"]),int(board["max_row"])+1):
			var cell := cell_at(q,r)
			if not grid().walkable(cell) and not board["blocked"].has(cell): board["blocked"].append(cell)
	var occupied := {}
	var displaced: Array = []
	for army in participants(war, board):
		var cell := int(army["tactical"]["cell"])
		if can_enter(war, army, cell) and not occupied.has(cell):
			occupied[cell] = army["id"]
			army["tactical"].erase("placement_invalid")
		else: displaced.append(army)
	for army in displaced:
		var start: int = army["tactical"]["cell"]
		# Seed inside the board even for corrupt save indices.
		var seed := cell_at(clampi(column_of(maxi(start,0)),int(board["min_column"]),int(board["max_column"])),clampi(row_of(maxi(start,0)),int(board["min_row"]),int(board["max_row"])))
		var queue: Array = [seed]
		var seen := {seed:true}
		var cursor := 0
		var destination := -1
		while cursor < queue.size():
			var current: int = queue[cursor]
			cursor += 1
			if can_enter(war, army, current) and not occupied.has(current): destination = current; break
			for other in neighbors(current):
				if column_of(other) < int(board["min_column"]) or column_of(other) > int(board["max_column"]) or row_of(other) < int(board["min_row"]) or row_of(other) > int(board["max_row"]) or seen.has(other): continue
				seen[other] = true
				queue.append(other)
		if destination < 0:
			army["tactical"]["placement_invalid"] = true
			army["tactical"]["blocked"] = true
			continue
		occupied[destination] = army["id"]
		army["tactical"].erase("placement_invalid")
		army["tactical"]["cell"] = destination
		army["tactical"]["lane"] = column_of(destination)
		army["tactical"]["move_path"] = [destination]
		army["tactical"]["blocked"] = false
		army["combat_targets"] = []
		for field in ["previous_cell","previous_goal","terrain_delay","flank_goal","attack_target"]: army["tactical"].erase(field)
		army["tactical"]["terrain_migrated_at"] = war.state["tick"]
		army["last_reason"] = "通行规则更新，部队就近归岸"


static func setup(war, anchor_cell: int = -1) -> void:
	var source_grid: RefCounted = grid()
	var transform: Array = source_grid.transform
	# transform[0]/[1] are divisors below, and load_source()'s success flag is discarded
	# by shared(), so a missing or short grid_transform.json would index out of bounds.
	if transform.size() < 4 or float(transform[0]) == 0.0 or float(transform[1]) == 0.0:
		push_error("战场建立失败：网格变换缺失或无效（rtk14_hex_grid.transform）")
		return
	var cities: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://assets/rtk14/cities_map.json"))
	if not cities is Array:
		push_error("战场建立失败：cities_map.json 解析失败")
		return
	var center := Vector2.ZERO
	for city in cities:
		if city["name"] == "小沛": center = Vector2(city["x"], city["z"])
	# Anchor through the grid's own city->cell mapping. The hand-rolled inverse with
	# unexplained +30/-30 pixel nudges disagreed with grid().pick(), so the battlefield
	# could be centred on a different hex than the city occupies.
	# source_grid is typed as RefCounted, so pick() returns Variant here and `:=`
	# cannot infer the type. Declare it explicitly; grid().pick() is documented int.
	var anchor_from_city: int = source_grid.pick(center)
	var column := column_of(anchor_from_city) if anchor_from_city >= 0 else int(round((center.x - float(transform[2])) / float(transform[0])))
	var row := row_of(anchor_from_city) if anchor_from_city >= 0 else int(round((center.y - float(transform[3])) / float(transform[1]) - posmod(column, 2) * 0.5))
	column -= posmod(column, 2)
	if anchor_cell >= 0:
		column = column_of(anchor_cell)
		row = row_of(anchor_cell)
	var board := {
		"grid": "global", "battle_id": "xiaopei:" + str(war.state["next_id"]), "started_at": war.state["tick"], "log": [],
		"anchor": cell_at(column, row),
		"center_column": column, "center_row": row,
		"min_column": column - 7, "max_column": column + 7,
		"min_row": row - 9, "max_row": row + 9,
		"blocked": [],
	}
	for q in range(-7, 8):
		for r in range(-9, 10):
			var cell := cell_at(column + q, row + r)
			if not source_grid.walkable(cell):
				board["blocked"].append(cell)
	war.state["battlefield"] = board
	Fort.attach(war, board)
	board["sides"] = {}
	for army in war.active_armies():
		army["battlefield_id"] = board["battle_id"]
		army["edge"] = Edges.ensure(army, war.roster.officers.get(str(army.get("officer_id", "")), {}), true)
	var factions := {}
	for army in war.active_armies(): factions[army["faction"]] = true
	for faction in factions:
		var armies: Array = war.active_armies(faction)
		armies.sort_custom(func(a, b): return int(a["skills"].get("带兵", 50)) + int(a["skills"].get("治军", 50)) > int(b["skills"].get("带兵", 50)) + int(b["skills"].get("治军", 50)))
		if armies.is_empty(): continue
		var commander: String = armies[0]["id"]
		var sign_y := -1 if board["sides"].is_empty() else 1
		board["sides"][faction] = sign_y
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
					if in_battlefield(Fort.movement_board(war, board, faction), cell) and not occupied.has(cell): options.append(cell)
			options.sort_custom(func(a, b): return cell_distance(a, desired) < cell_distance(b, desired))
			if not options.is_empty(): desired = options[0]
			armies[index]["tactical"] = {"cell": desired, "role": role, "commander": commander, "support_id": _support_id_for(armies, index), "attack_target": "", "phase": "接近", "plan_until": 0, "change_reason": "主帅分配作战位置与职责", "blocked": false, "blocked_days": 0, "lane": column_of(desired), "withdraw_preparation": 0}


static func distance(a: Dictionary, b: Dictionary) -> int:
	if not a.has("tactical") or not b.has("tactical") or str(a.get("battlefield_id", "")) != str(b.get("battlefield_id", "")): return 10000
	return cell_distance(int(a["tactical"]["cell"]), int(b["tactical"]["cell"]))


static func attack_range(army: Dictionary) -> int:
	return 2 if preload("res://scripts/war/troop_roles.gd").kind(army) == "archers" else 1


# Observed enemies, nearest first. Called four to six times per attacker per day from
# ordered_target/move/resolve and again from army_corps, always for the same tick, so
# the result is memoised per (tick, army).
static var _target_cache: Dictionary = {}


static func targets(war, army: Dictionary) -> Array:
	var key := "%d:%d:%s" % [war.get_instance_id(), int(war.state["tick"]), str(army["id"])]
	if _target_cache.has(key):
		return _target_cache[key].filter(func(enemy): return enemy.get("status", "") != "ended" and not enemy.get("tactical",{}).get("placement_invalid",false) and distance(army, enemy) < 10000 and _seen_now(war,army,enemy) and not shield_between(war,army,enemy))
	var result: Array = []
	for enemy in war.active_armies():
		if war.hostile(str(enemy["faction"]), str(army["faction"])) and _seen_now(war,army,enemy) and enemy.has("tactical") and not enemy.get("tactical",{}).get("placement_invalid",false) and distance(army, enemy) < 10000 and not shield_between(war,army,enemy):
			result.append(enemy)
	result.sort_custom(func(a, b):
		var left := _target_priority(war,army,a)
		var right := _target_priority(war,army,b)
		return left > right if not is_equal_approx(left,right) else str(a["id"]) < str(b["id"]))
	_target_cache[key] = result
	return result

static func _seen_now(war, army: Dictionary, enemy: Dictionary) -> bool:
	return int(army.get("intel",{}).get("enemies",{}).get(enemy["id"],{}).get("observed_at",-1)) == int(war.state["tick"])

static func _is_commander(war, army: Dictionary) -> bool:
	return war.state.get("corps",{}).get(army.get("corps_id",""),{}).get("root_id","") == army["id"]

static func _target_priority(war, army: Dictionary, enemy: Dictionary) -> float:
	var gap := distance(army,enemy)
	# Handle an adjacent threat before shooting past it. Within that tier prefer
	# an exposed commander, then a recent attacker or a favorable troop matchup.
	var score := 1000.0 if gap == 1 else 500.0 if gap <= attack_range(army) else -float(gap)*10.0
	if gap <= attack_range(army):
		if _is_commander(war,enemy): score += 60
		if army.get("last_enemy_id","") == enemy["id"] and int(war.state["tick"])-int(army.get("last_enemy_tick",-10)) <= 2: score += 18
		if army.get("tactical",{}).get("attack_target","") == enemy["id"]: score += 12
		var known: Dictionary = army["intel"]["enemies"][enemy["id"]]
		var estimate := float(known.get("strength_estimate",10000))
		if estimate < Combat.strength(army)*0.4: score += 10
		if preload("res://scripts/war/troop_roles.gd").kind(army) == "cavalry" and float(known.get("unit_mix_estimate",{}).get("archers",0)) > estimate*0.6: score += 22
	return score


static func clear_target_cache() -> void:
	_target_cache.clear()


static func ordered_target(war, army: Dictionary) -> Dictionary:
	var available := targets(war, army)
	if available.is_empty(): return {}
	var tactical: Dictionary = army["tactical"]
	# Contact has priority; otherwise keep an observed target for a short order.
	# Merely becoming one tile nearer does not justify crossing another unit's line.
	var previous: Dictionary = war.state["armies"].get(tactical.get("attack_target", ""), {})
	if not previous.is_empty() and previous["status"] != "ended" and war.hostile(str(previous["faction"]), str(army["faction"])) and _seen_now(war,army,previous):
		if distance(army, previous) <= attack_range(army) and _target_priority(war,army,previous) >= _target_priority(war,army,available[0]): return previous
		if distance(army, available[0]) > attack_range(army) and int(war.state["tick"]) < int(tactical.get("target_until", 0)): return previous
	var selected: Dictionary = available[0]
	if selected["id"] != tactical.get("attack_target", ""):
		tactical["target_until"] = int(war.state["tick"]) + 4
	return selected


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


static func contact_state(war, army: Dictionary) -> Dictionary:
	# Positions, assignments and returns can change within the same campaign day.
	# Contact is a current rule query, not a day-level observation cache.
	var attackers: Array = []
	var cover := 0
	for other in participants(war):
		if other["id"] == army["id"] or not other.has("tactical") or distance(army, other) > 1: continue
		if shield_between(war, army, other): continue
		if war.hostile(str(other["faction"]), str(army["faction"])) and not bool(other["returning"]) and bool(war.orders_for(other)["engage"]): attackers.append(other["id"])
		elif other["faction"] == army["faction"] and not bool(other["returning"]) and other.get("operation", {}).get("role", "") == "rear_guard": cover += 1
	var flanked := false
	for first in attackers:
		for second in attackers:
			if first != second and distance(war.state["armies"][first], war.state["armies"][second]) >= 2: flanked = true
	# One rear-guard cancelled the whole penalty regardless of how many attackers there
	# were, so the second and third rear-guard units were dead weight. Cover now offsets
	# one attacker each, capped so it can never make disengaging free.
	return {"flanked": flanked, "engaged_by": attackers, "adjacent_enemies": attackers.size(), "covered_by": cover, "required_preparation": maxi(1, 1 + maxi(0, attackers.size() - cover))}


static func _enemy_control(war, army: Dictionary) -> Dictionary:
	var key := "%d:%d:%s" % [war.get_instance_id(), int(war.state["tick"]), str(army["id"])]
	if _enemy_control_cache.has(key):
		return _enemy_control_cache[key]
	var result := _cached_enemy_control(war, army)
	_enemy_control_cache[key] = result
	return result


static func _cached_enemy_control(war, army: Dictionary) -> Dictionary:
	var controlled := {}
	for enemy in participants(war):
		if not war.hostile(str(enemy["faction"]), str(army["faction"])) or bool(enemy["returning"]) or not enemy.has("tactical") or not bool(war.orders_for(enemy)["engage"]): continue
		if shield_between(war, army, enemy): continue
		for cell in neighbors(int(enemy["tactical"]["cell"])): controlled[cell] = true
	return controlled


static func _enemy_control_cache_clear() -> void:
	_enemy_control_cache.clear()


static var _enemy_control_cache: Dictionary = {}


# 破口开放后，非弓兵部队从缺口入城：先走缺口外侧落点，再进缺口格；
# 已入城则向城心推进。城内其余格仍由 blocked_for 控制，通道只在破口走廊。
# 返回 -1 表示保持原有城下位置（尚未破城或该兵种应留在城下）。
static func siege_entry_goal(war, army: Dictionary, board: Dictionary) -> int:
	if attack_range(army) > 1: return -1
	var node := str(army["target"])
	var breach: int = Defense.breach_cell(war, node)
	if breach < 0: return -1
	var legal: Dictionary = Fort.movement_board(war, board, str(army["faction"]))
	var start := int(army["tactical"]["cell"])
	if Fort.inside_city(board, start) == node:
		var center := int(board.get("objectives", {}).get(node, breach))
		return center if in_battlefield(legal, center) else start
	if not in_battlefield(legal, breach): return -1
	if cell_distance(start, breach) <= 1: return breach
	# 城外远处：先到缺口外侧的落点，避免直线穿墙导致寻路卡死。
	var outside := -1
	var best := 10000
	for neighbor in neighbors(breach):
		var cell := int(neighbor)
		if not in_battlefield(legal, cell) or Fort.inside_city(board, cell) != "": continue
		var gap := cell_distance(start, cell)
		if gap < best:
			best = gap
			outside = cell
	return outside if outside >= 0 else breach


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
		var points := minf(2.0,float(tactical.get("movement_credit",0))+preload("res://scripts/war/troop_roles.gd").mobility(army,terrain_class(start),war.rules))
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
	var points := minf(2.0,float(tactical.get("movement_credit",0)) + preload("res://scripts/war/troop_roles.gd").mobility(army,terrain_class(start),war.rules))
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
		preload("res://scripts/war/officer_fate.gd").credit(war, weights, int(army["dead"]) - dead_before, {}, personal)
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
