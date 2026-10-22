class_name CampaignBattlefields
extends RefCounted
## 正式战役中的多个独立战场：建棋盘、道路、加入与运行、收尾清理。

const Fort = preload("res://scripts/war/battle/city_fortifications.gd")
const Tactical = preload("res://scripts/war/battle/tactical_battlefield.gd")

static func make_board(war, id: String, anchor: int, objectives: Dictionary) -> Dictionary:
	if war.state["battlefields"].has(id) and war.state["battlefields"][id].has("ended_at"):
		id += "@%d" % int(war.state["tick"])
		while war.state["battlefields"].has(id): id += "+"
	var q := anchor % 220
	var r := anchor / 220
	var board := {"battle_id": id, "grid": "global", "anchor": anchor, "center_column": q, "center_row": r, "min_column": maxi(0, q - 9), "max_column": mini(219, q + 9), "min_row": maxi(0, r - 9), "max_row": mini(219, r + 9), "blocked": [], "objectives": objectives, "started_at": int(war.state["tick"]), "log": [], "sides": {}}
	var ids: Array = war.state["battlefields"].keys()
	ids.sort()
	for key in ids:
		var existing: Dictionary = war.state["battlefields"][key]
		if existing.has("ended_at") or Tactical.cell_distance(anchor, int(existing["anchor"])) > 12: continue
		existing["objectives"].merge(objectives)
		for field in ["min_column", "min_row"]: existing[field] = mini(int(existing[field]), int(board[field]))
		for field in ["max_column", "max_row"]: existing[field] = maxi(int(existing[field]), int(board[field]))
		board = existing
		break
	board["blocked"] = []
	for column in range(int(board["min_column"]), int(board["max_column"]) + 1):
		for row in range(int(board["min_row"]), int(board["max_row"]) + 1):
			var cell := Tactical.cell_at(column, row)
			if not Tactical.grid().walkable(cell): board["blocked"].append(cell)
	Fort.attach(war, board)
	war.state["battlefields"][board["battle_id"]] = board
	return board

static func roads(war, motions: Dictionary) -> void:
	if war.store.battle_test or war.state.has("battlefield"): return
	var armies: Array = war.active_armies().filter(func(army): return not army.has("tactical") and war.ready(army))
	for first in armies:
		if first.has("tactical"): continue
		for second in armies:
			if second.has("tactical") or first["id"] == second["id"] or not war.hostile(str(first["faction"]), str(second["faction"])) or not war._contact(first, second, motions): continue
			var edge := str(first["location"].get("edge", ""))
			if edge == "": edge = str(motions.get(first["id"], {}).get("before", {}).get("edge", ""))
			if edge == "": continue
			var link: Dictionary = war.graph.edges[edge]
			var start: Dictionary = Fort.for_city(war.store, str(link["from"]))
			var finish: Dictionary = Fort.for_city(war.store, str(link["to"]))
			if start.is_empty() or finish.is_empty(): continue
			var fraction: float = (war._edge_coordinate(motions.get(first["id"], {}).get("before", first["location"])) + war._edge_coordinate(motions.get(second["id"], {}).get("before", second["location"]))) * 0.5
			var point: Vector2 = Fort.road_point(war.store, str(link["from"]), str(link["to"]), clampf(fraction, 0.1, 0.9))
			var anchor: int = Tactical.grid().pick(point)
			if not Tactical.grid().walkable(anchor):
				var candidates: Array = []
				for cell in range(maxi(0, anchor - 220 * 3), mini(220 * 220, anchor + 220 * 3)):
					if Tactical.grid().walkable(cell): candidates.append(cell)
				candidates.sort_custom(func(a, b): return Tactical.cell_distance(a, anchor) < Tactical.cell_distance(b, anchor))
				if candidates.is_empty(): continue
				anchor = candidates[0]
			var id := "road:" + edge
			var board: Dictionary = war.state["battlefields"].get(id, {})
			if board.is_empty() or board.has("ended_at"): board = make_board(war, id, anchor, {})
			if not board.has("roads"): board["roads"] = {}
			board["roads"][edge] = fraction
			join(war, board, first)
			join(war, board, second)
			for army in armies:
				var before: Dictionary = motions.get(army["id"], {}).get("before", army["location"])
				if not army.has("tactical") and army["location"].get("edge", "") == edge and (absf(war._edge_coordinate(army["location"]) - fraction) <= 0.15 or absf(war._edge_coordinate(before) - fraction) <= 0.15): join(war, board, army)
			for army in Tactical.participants(war, board):
				if army["location"].get("edge", "") == edge: army["location"]["progress"] = fraction if army["location"].get("from", "") == link["from"] else 1.0 - fraction
			break

# Formal campaigns own multiple independent boards. The legacy battlefield key
# is reserved for the standalone scenario and a synchronous tactical call scope.
static func prepare(war) -> void:
	if war.store.battle_test or war.state.has("battlefield"): return
	for army in war.active_armies():
		if army.has("tactical") or army["returning"] or not war.ready(army): continue
		var location: Dictionary = army["location"]
		var node := str(location.get("node", ""))
		if location.get("edge", "") != "" or not war.store.city_state(node).has("garrison"): continue
		var enemy_city: bool = army["mission_type"] == "capture" and node == army["target"] and war.hostile(str(war.store.city_state(node).get("faction", "")), str(army["faction"]))
		var contact := false
		for enemy in war.active_armies():
			if war.hostile(str(enemy["faction"]), str(army["faction"])) and enemy["location"].get("edge", "") == "" and enemy["location"].get("node", "") == node: contact = true
		if not enemy_city and not contact: continue
		var id := "city:" + node
		var current: Dictionary = {}
		var ids: Array = war.state["battlefields"].keys()
		ids.sort()
		for key in ids:
			var existing: Dictionary = war.state["battlefields"][key]
			if not existing.has("ended_at") and existing["objectives"].has(node): current = existing; break
		if not war.state["battlefields"].has(id) or war.state["battlefields"][id].has("ended_at"):
			var site := Fort.for_city(war.store, node)
			if site.is_empty(): continue
			var anchor := int(site["center"])
			if current.is_empty(): current = make_board(war, id, anchor, {node: anchor})
		elif current.is_empty(): current = war.state["battlefields"][id]
		for participant in war.active_armies():
			if not war.ready(participant): continue
			if participant.has("tactical") or participant["location"].get("edge", "") != "" or participant["location"].get("node", "") != node: continue
			join(war, current, participant)
	# A reinforcement joins an existing board at arrival, with no global reset.
	for board in war.state["battlefields"].values():
		if board.has("ended_at"): continue
		for army in war.active_armies():
			if not war.ready(army): continue
			var near_city: bool = army["location"].get("edge", "") == "" and board["objectives"].has(army["location"].get("node", ""))
			var edge := str(army["location"].get("edge", ""))
			var roads: Dictionary = board.get("roads", {board["road"]: board.get("road_fraction", 0.5)} if board.has("road") else {})
			var near_road: bool = roads.has(edge) and absf(war._edge_coordinate(army["location"]) - float(roads.get(edge, 0.5))) <= 0.15
			if not army.has("tactical") and (near_city or near_road): join(war, board, army)

static func join(war, board: Dictionary, army: Dictionary) -> void:
	var faction := str(army["faction"])
	if not board["sides"].has(faction): board["sides"][faction] = -1 if board["sides"].is_empty() else 1
	var sign_y := int(board["sides"][faction])
	var desired := Tactical.offset_cell(board, 0, sign_y * (2 if board.has("roads") or board.has("road") else 6))
	var node := str(army["location"].get("node", ""))
	var origin := str(army["location"].get("from", ""))
	if army["location"].get("edge", "") == "" and board["objectives"].has(node) and origin != "":
		var arrival := Fort.road_path(war.store, origin, node)
		if not arrival.is_empty(): desired = arrival[-1]
	var occupied := {}
	for other in war.active_armies():
		if other.has("tactical"): occupied[int(other["tactical"]["cell"])] = true
	var options: Array = []
	var legal := Fort.movement_board(war, board, faction)
	for q in range(int(board["min_column"]), int(board["max_column"]) + 1):
		for r in range(int(board["min_row"]), int(board["max_row"]) + 1):
			var cell := Tactical.cell_at(q, r)
			if Tactical.in_battlefield(legal, cell) and not occupied.has(cell): options.append(cell)
	options.sort_custom(func(a, b): return Tactical.cell_distance(a, desired) < Tactical.cell_distance(b, desired))
	if options.is_empty(): return
	var cell := int(options[0])
	army["battlefield_id"] = board["battle_id"]
	army["tactical"] = {"cell": cell, "role": army.get("corps_task", {}).get("type", "main_attack"), "commander": army["id"], "support_id": "", "attack_target": "", "phase": "抵达战场", "plan_until": 0, "blocked": false, "blocked_days": 0, "lane": Tactical.column_of(cell), "withdraw_preparation": 0}

static func run(war, method: String) -> Dictionary:
	var motions := {}
	var ids: Array = war.state["battlefields"].keys()
	ids.sort()
	for id in ids:
		var board: Dictionary = war.state["battlefields"][id]
		if board.has("ended_at") and Tactical.participants(war, board).is_empty(): continue
		war.state["battlefield"] = board
		if method == "move": motions.merge(Tactical.move(war))
		else: Tactical.resolve(war)
		war.state.erase("battlefield")
	return motions

static func cleanup(war) -> void:
	for board in war.state["battlefields"].values():
		var participants := Tactical.participants(war, board)
		if board.has("ended_at") and participants.is_empty(): continue
		var hostile := participants.any(func(army): return not army["returning"] and army["mission_type"] == "capture" and board["objectives"].has(army["target"]) and war.hostile(str(war.store.city_state(army["target"]).get("faction", "")), str(army["faction"])))
		var factions := {}
		for army in participants:
			if not army["returning"]: factions[army["faction"]] = true
		var fighting := false
		for first in factions:
			for second in factions:
				if war.hostile(str(first), str(second)): fighting = true
		if hostile or fighting: continue
		board["ended_at"] = int(war.state["tick"])
		for army in participants:
			army.erase("tactical")
			army.erase("battlefield_id")
			if army["returning"]: war._start_return(army)
