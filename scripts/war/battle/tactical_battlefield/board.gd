@abstract
class_name TacticalBoard
extends RefCounted
## 战术棋盘：共用常量、六角格坐标与距离、战场范围与可通行、参战部队、城防内外隔断、旧存档阵位整理。
##
## 链：TacticalBoard → TacticalTargeting → TacticalMovement → TacticalResolution → tactical_battlefield.gd，
## 全是静态函数，外部仍经 tactical_battlefield.gd（Tactical.xxx）调用。下层不能调用上层的函数。


const Process = preload("res://scripts/officers/officer_process.gd")
const Combat = preload("res://scripts/war/battle/combat_system.gd")
const GridScript = preload("res://scripts/world/rtk14_hex_grid.gd")
const ROLES := {"main_attack": "主攻", "flank": "侧翼", "support": "支援", "reserve": "预备队", "rear_guard": "掩护撤退", "withdraw": "撤退", "command": "中军统筹", "raid_rear": "绕后奇袭", "cut_supply": "截断粮道", "regroup": "归建"}
const Terrain = preload("res://scripts/war/battle/battle_terrain.gd")
const Duel = preload("res://scripts/war/duel/duel_system.gd")
const Feedback = preload("res://scripts/war/battle/battle_feedback.gd")
const Edges = preload("res://scripts/war/campaign/officer_edges.gd")
const GRID_WIDTH := 220
const Fort = preload("res://scripts/war/battle/city_fortifications.gd")
const Roles = preload("res://scripts/war/battle/troop_roles.gd")
const Defense = preload("res://scripts/war/battle/city_defense.gd")


## 该军所在的战场（多战场时按 battlefield_id，否则为主战场）。
static func board_for(war, army: Dictionary) -> Dictionary:
	var id := str(army.get("battlefield_id", ""))
	return war.state.get("battlefields", {}).get(id, war.state.get("battlefield", {}))


## 某个战场上仍在行动的参战部队；不传 board 时为主战场。
static func participants(war, board: Dictionary = {}) -> Array:
	if board.is_empty(): board = war.state.get("battlefield", {})
	var id := str(board.get("battle_id", ""))
	return war.active_armies().filter(func(army): return army.has("tactical") and str(army.get("battlefield_id", id)) == id)


## 势力在该战场上的阵营（-1 或 1）。
static func side_for(board: Dictionary, faction: String) -> int:
	return int(board.get("sides", {}).get(faction, -1 if faction == "liu_bei" else 1))


## 该军能否进入某格（按城防给该势力的通行棋盘）。
static func can_enter(war, army: Dictionary, cell: int) -> bool:
	var board := board_for(war, army)
	return not board.is_empty() and in_battlefield(Fort.movement_board(war, board, str(army["faction"])), cell)


# Main-map renderer, selection and tactical rules share one grid service.
static func grid() -> RefCounted:
	return GridScript.shared()


## 格号的列。
static func column_of(cell: int) -> int: return cell % GRID_WIDTH


## 格号的行。
static func row_of(cell: int) -> int: return cell / GRID_WIDTH


## 列、行对应的格号。
static func cell_at(column: int, row: int) -> int: return row * GRID_WIDTH + column


## 两格之间的六角格距离。
static func cell_distance(a: int, b: int) -> int:
	return grid().distance(a, b)


# The unit this one is notionally covering. The old expression indexed armies[index]
# itself, so every formation reported its own id as its support and the AI prompt and
# the intel panel showed "协同对象：<自己>".
static func _support_id_for(armies: Array, index: int) -> String:
	if armies.size() < 2: return ""
	if index < armies.size() - 1: return str(armies[index + 1]["id"])
	return str(armies[maxi(index - 1, 0)]["id"])


## 相邻的格。
static func neighbors(cell: int) -> PackedInt32Array:
	return grid().neighbors(cell)


## 格中心的世界坐标（x, z）。
static func world_cell(cell: int) -> Vector2:
	return grid().center(cell)


## 相对战场中心偏移 (dq, dr) 的格。
static func offset_cell(board: Dictionary, dq: int, dr: int) -> int:
	return cell_at(int(board["center_column"]) + dq, int(board["center_row"]) + dr)


## 格是否在战场范围内、可通行且未被阻挡。
static func in_battlefield(board: Dictionary, cell: int) -> bool:
	if cell < 0:
		return false
	var column := column_of(cell)
	var row := row_of(cell)
	if column < int(board["min_column"]) or column > int(board["max_column"]) or row < int(board["min_row"]) or row > int(board["max_row"]):
		return false
	return grid().walkable(cell) and not board["blocked"].has(cell)


## 格的地形类别（plains、mountains、ford 等）。
static func terrain_class(cell: int) -> String:
	return Terrain.from_code(grid().terrain(cell))


## 该军能否发动攻击（阵位有效且地形允许）。
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


## 格的中文描述“列x行y”。
static func cell_text(cell: int) -> String:
	return "列%d行%d" % [column_of(cell), row_of(cell)]


## 整理主战场阻挡格并挂上城防；旧存档里停在不可通行格的部队就近挪到空格，找不到就标记 placement_invalid。
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
