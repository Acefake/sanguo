class_name TacticalBattlefield
extends "res://scripts/war/battle/tactical_battlefield/resolution.gd"
## 战术战场：六角格上的布阵、移动与结算，全部是以 war（CampaignState）为第一个参数的静态函数。
##
## 本文件只留开战布阵 setup()；其余实现分在 tactical_battlefield/ 下四层
## （board → targeting → movement → resolution），本脚本继承最上层，
## 所以外部的 Tactical.move()、Tactical.ROLES、Tactical.GRID_WIDTH 等用法都不变。


## 建立主战场（15×19 格，中心为 anchor_cell，缺省取小沛所在格），按势力定阵营并给各军分配职责与初始阵位。
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
		"grid": "global", "battle_id": "xiaopei:" + str(war.state[StateKeys.NEXT_ID]), "started_at": war.state[StateKeys.TICK], "log": [],
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
	war.state[StateKeys.BATTLEFIELD] = board
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
