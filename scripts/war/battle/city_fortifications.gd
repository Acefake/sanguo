class_name CityFortifications
extends RefCounted
## 城防地理：城池道路与据点、城墙轮廓、破口通道、按势力的通行棋盘、城内外判定与视线。

const Grid = preload("res://scripts/world/rtk14_hex_grid.gd")
const Combat = preload("res://scripts/war/battle/combat_system.gd")
const Fate = preload("res://scripts/war/campaign/officer_fate.gd")
static var _native: Array = []
static var _positions: Dictionary = {}
static var _sites: Dictionary = {}
static var _geometry: Dictionary = {}
static var _route_cache: Dictionary = {}
static var _road_components: Dictionary = {}
static var _component_sizes: Dictionary = {}
static var _transport_graph: AStar2D
static var _approach_cache: Dictionary = {}
const WATER_CODES := [13, 14]
const MOUNTAIN_ROAD_CODES := [10]

static func _water_route(grid, blocked: Array, ends: Array) -> PackedInt32Array:
	if _transport_graph == null:
		_transport_graph = AStar2D.new()
		var obstacles := {}
		for cell in blocked: obstacles[int(cell)] = true
		for cell in range(Grid.COUNT):
			var special: bool = grid.region(cell) > 0 and (grid.terrain(cell) in WATER_CODES or grid.terrain(cell) in MOUNTAIN_ROAD_CODES)
			if obstacles.has(cell) or not (grid.walkable(cell) or special): continue
			# Existing strategic roads can cross highland trails and ferry legs;
			# tactical ground deployment still rejects these cells.
			_transport_graph.add_point(cell, grid.center(cell), 8.0 if grid.terrain(cell) in MOUNTAIN_ROAD_CODES else 4.0 if grid.terrain(cell) in WATER_CODES else 1.0)
		for cell in _transport_graph.get_point_ids():
			for other in grid.neighbors(int(cell)):
				if other > cell and _transport_graph.has_point(other): _transport_graph.connect_points(cell, other)
	var origins: Array = ends[0].keys()
	var destinations: Array = ends[1].keys()
	# Dictionary insertion order preserves the nearest exterior of each city.
	# Choosing the largest land mass can leave a pass across a river unreachable.
	for origin in origins:
		for destination in destinations:
			var path := PackedInt32Array()
			for cell in _transport_graph.get_id_path(int(ends[0][origin]), int(ends[1][destination])): path.append(int(cell))
			if not path.is_empty(): return path
	return PackedInt32Array()

static func _road_regions(grid, blocked: Array) -> void:
	if not _road_components.is_empty(): return
	var obstacles := {}
	for cell in blocked: obstacles[int(cell)] = true
	var region := 0
	for cell in range(Grid.COUNT):
		if _road_components.has(cell) or obstacles.has(cell) or not grid.walkable(cell): continue
		region += 1
		var queue: Array = [cell]
		var index := 0
		_road_components[cell] = region
		while index < queue.size():
			var current: int = queue[index]
			index += 1
			for neighbor in grid.neighbors(current):
				if _road_components.has(neighbor) or obstacles.has(neighbor) or not grid.walkable(neighbor): continue
				_road_components[neighbor] = region
				queue.append(neighbor)
		_component_sizes[region] = queue.size()

static func road_path(store, start: String, finish: String) -> PackedInt32Array:
	var key := start + ">" + finish
	if _route_cache.has(key): return _route_cache[key]
	var grid = Grid.shared()
	var blocked: Array = []
	for site in sites(store).values():
		for cell in site["cells"]:
			if not blocked.has(int(cell)): blocked.append(int(cell))
	_road_regions(grid, blocked)
	var ends: Array = []
	for node in [start, finish]:
		var site := for_city(store, node)
		if site.is_empty(): return PackedInt32Array()
		var center := int(site["center"])
		var options: Array = []
		for q in range(maxi(0, center % 220 - 6), mini(219, center % 220 + 6) + 1):
			for r in range(maxi(0, center / 220 - 6), mini(219, center / 220 + 6) + 1):
				var cell: int = grid.index_at(q, r)
				if grid.walkable(cell) and not blocked.has(cell): options.append(cell)
		options.sort_custom(func(a, b): return grid.distance(a, center) < grid.distance(b, center) if grid.distance(a, center) != grid.distance(b, center) else a < b)
		if options.is_empty(): return PackedInt32Array()
		var by_region := {}
		for cell in options:
			var region: int = _road_components.get(cell, -1)
			if region >= 0 and not by_region.has(region): by_region[region] = cell
		ends.append(by_region)
	var origin: int = ends[0].keys()[0]
	var destination: int = ends[1].keys()[0]
	var path := PackedInt32Array()
	if origin == destination: path = grid.find_path(int(ends[0][origin]), int(ends[1][destination]), blocked)
	else: path = _water_route(grid, blocked, ends)
	_route_cache[key] = path
	var reverse := path.duplicate()
	reverse.reverse()
	_route_cache[finish + ">" + start] = reverse
	return path

static func road_point(store, start: String, finish: String, progress: float) -> Vector2:
	var path := road_path(store, start, finish)
	if path.is_empty():
		var site := for_city(store, start)
		return site.get("point", Vector2(1024, 1024))
	var position := clampf(progress, 0.0, 1.0) * maxi(0, path.size() - 1)
	var index := mini(int(position), path.size() - 1)
	return Grid.shared().center(path[index]).lerp(Grid.shared().center(path[mini(index + 1, path.size() - 1)]), position - index)

static func sites(store) -> Dictionary:
	if not _sites.is_empty(): return _sites
	if _native.is_empty():
		_native = JSON.parse_string(FileAccess.get_file_as_string("res://assets/rtk14/cities_map.json"))
		_native.append_array(JSON.parse_string(FileAccess.get_file_as_string("res://assets/rtk14/source_gates.json")))
		_positions = JSON.parse_string(FileAccess.get_file_as_string("res://data/war/world_3d_positions.json")).get("positions", {})
		_geometry = JSON.parse_string(FileAccess.get_file_as_string("res://data/war/city_geometry.json")).get("models", {})
	var result := {}
	var grid = Grid.shared()
	for entry in _native:
		var logical: String = store.canonical_city_id(str(entry["id"]))
		var cells: Array = entry.get("cells", []).duplicate()
		var point := Vector2(float(entry["x"]), float(entry["z"]))
		var center: int = grid.pick(point)
		var bounds: Dictionary = _geometry.get(str(entry["model"]), {})
		var polygon := PackedVector2Array()
		if not bounds.is_empty():
			cells.clear()
			var scale_value := float(entry.get("model_scale", 1.0))
			var rotation := float(entry.get("rotation", 0.0))
			var corners: Array = [Vector2(bounds["min_x"], bounds["min_z"]), Vector2(bounds["max_x"], bounds["min_z"]), Vector2(bounds["max_x"], bounds["max_z"]), Vector2(bounds["min_x"], bounds["max_z"])]
			if bounds.get("wall_outline",[]).size() >= 3:
				corners = bounds["wall_outline"].map(func(p): return Vector2(float(p[0]),float(p[1])))
			for corner: Vector2 in corners:
				polygon.append(point + (corner * scale_value).rotated(-rotation))
			for column in range(maxi(0, center % 220 - 6), mini(219, center % 220 + 6) + 1):
				for row in range(maxi(0, center / 220 - 6), mini(219, center / 220 + 6) + 1):
					var cell: int = grid.index_at(column, row)
					# A tiny corner overlap must not block an entire exterior hex.
					if Geometry2D.is_point_in_polygon(grid.center(cell),polygon): cells.append(cell)
		if not cells.has(center): cells.append(center)
		result[str(entry["id"])] = {"id": logical, "render_id": entry["id"], "center": center, "cells": cells, "point": point, "gate": int(cells[0]) if not cells.is_empty() else center, "height": 4.5, "native": true, "wall_anchors": bounds.get("wall_anchors", {})}
		result[str(entry["id"])]["footprint"] = Array(polygon).map(func(p): return [p.x,p.y])
	var represented := {}
	for site in result.values():
		if site["id"] != "": represented[site["id"]] = true
	for id in store.scenario.get("places", {}):
		if represented.has(id) or not store.city_state(id).has("garrison") or not _positions.has(id): continue
		var point := Vector2(float(_positions[id]["x"]), float(_positions[id]["z"]))
		var center: int = grid.pick(point)
		if not grid.walkable(center):
			var options: Array = []
			for cell in range(maxi(0, center - 220 * 5), mini(Grid.COUNT, center + 220 * 5)):
				if grid.walkable(cell): options.append(cell)
			options.sort_custom(func(a, b): return grid.distance(a, center) < grid.distance(b, center))
			if options.is_empty(): continue
			center = options[0]
			point = grid.center(center)
		result[id] = {"id": id, "render_id": "", "center": center, "cells": [center], "point": point, "gate": center, "height": 4.5, "native": false}
	_sites = result
	return result

static func for_city(store, node: String) -> Dictionary:
	for site in sites(store).values():
		if site["id"] == node: return site
	return {}

static func attach(war, board: Dictionary) -> void:
	board["fortifications"] = {}
	var all_sites := sites(war.store)
	for key in all_sites:
		var site: Dictionary = all_sites[key]
		var cell: int = site["center"]
		if cell % 220 < int(board["min_column"]) or cell % 220 > int(board["max_column"]) or cell / 220 < int(board["min_row"]) or cell / 220 > int(board["max_row"]): continue
		# JSON saves contain no Vector2 values; authoritative board data stays scalar.
		var saved := site.duplicate(true)
		saved.erase("point")
		board["fortifications"][key] = saved

static func blocked_for(war, board: Dictionary, faction: String) -> Array:
	var blocked: Array = board.get("blocked", []).duplicate()
	for site in board.get("fortifications", {}).values():
		var node := str(site["id"])
		var friendly: bool = node != "" and war.store.city_state(node).get("faction", "") == faction
		var siege: Dictionary = war.state.get("sieges", {}).get(node, {})
		var breach: int = int(siege.get("breach_cell", -1))
		# 破口状态：新档读 breach_open；旧档用 breach_cell / wall<=0 兜底。
		var open: bool = bool(siege.get("breach_open", false)) or breach >= 0 or (not siege.is_empty() and float(siege.get("wall", 1.0)) <= 0.0)
		var passage := {}
		if open and breach >= 0:
			# 仅开放缺口到城心的内侧通道，不能把缺口周围尚完整的墙一起解锁。
			passage = breach_passage(site, breach)
		for value in site["cells"]:
			var cell := int(value)
			if cell == breach or (friendly and cell == int(site["gate"])): continue
			if passage.has(cell): continue
			if not blocked.has(cell): blocked.append(cell)
	return blocked

static func breach_passage(site: Dictionary, breach: int) -> Dictionary:
	var passage := {breach: true}
	var cells := {}
	for value in site["cells"]: cells[int(value)] = true
	var center := int(site["center"])
	if not cells.has(center): return passage
	var queue: Array = [breach]
	var parents := {breach: -1}
	var index := 0
	var grid = Grid.shared()
	while index < queue.size() and not parents.has(center):
		var current: int = queue[index]
		index += 1
		for neighbor in grid.neighbors(current):
			if not cells.has(int(neighbor)) or parents.has(int(neighbor)) or not grid.walkable(int(neighbor)): continue
			parents[int(neighbor)] = current
			queue.append(int(neighbor))
	if parents.has(center):
		var cursor := center
		while cursor >= 0:
			passage[cursor] = true
			cursor = int(parents[cursor])
	return passage

static func movement_board(war, board: Dictionary, faction: String) -> Dictionary:
	var result := board.duplicate()
	result["blocked"] = blocked_for(war, board, faction)
	return result

static func footprint(site: Dictionary) -> PackedVector2Array:
	var polygon := PackedVector2Array()
	for p in site.get("footprint",[]): polygon.append(Vector2(float(p[0]),float(p[1])))
	return polygon

static func contains_point(board: Dictionary, point: Vector2) -> bool:
	for site in board.get("fortifications",{}).values():
		var polygon := footprint(site)
		if polygon.size() >= 3 and Geometry2D.is_point_in_polygon(point,polygon): return true
	return false

static func distance_to_wall(board: Dictionary, node: String, cell: int) -> int:
	var distance := 10000
	for site in board.get("fortifications", {}).values():
		if site["id"] != node: continue
		for wall in site["cells"]: distance = mini(distance, Grid.shared().distance(cell, int(wall)))
	return distance

static func approach(war, board: Dictionary, faction: String, node: String, start: int, ring: int = 1) -> Array:
	var legal := movement_board(war, board, faction)
	var grid = Grid.shared()
	var key := str([board["min_column"], board["max_column"], board["min_row"], board["max_row"], hash(legal["blocked"]), node, ring])
	if not _approach_cache.has(key):
		var obstacles := {}
		for cell in legal["blocked"]: obstacles[int(cell)] = true
		var regions := {}
		var candidates := {}
		var region := 0
		for column in range(int(board["min_column"]), int(board["max_column"]) + 1):
			for row in range(int(board["min_row"]), int(board["max_row"]) + 1):
				var cell: int = grid.index_at(column, row)
				if regions.has(cell) or obstacles.has(cell) or not grid.walkable(cell): continue
				region += 1
				var queue: Array = [cell]
				var index := 0
				regions[cell] = region
				candidates[region] = []
				while index < queue.size():
					var current: int = queue[index]
					index += 1
					if distance_to_wall(board, node, current) == ring: candidates[region].append(current)
					for neighbor in grid.neighbors(current):
						if regions.has(neighbor) or obstacles.has(neighbor) or not grid.walkable(neighbor): continue
						if neighbor % 220 < int(board["min_column"]) or neighbor % 220 > int(board["max_column"]) or neighbor / 220 < int(board["min_row"]) or neighbor / 220 > int(board["max_row"]): continue
						regions[neighbor] = region
						queue.append(neighbor)
		if _approach_cache.size() >= 64: _approach_cache.clear()
		_approach_cache[key] = {"regions": regions, "candidates": candidates}
	var cached: Dictionary = _approach_cache[key]
	var options: Array = cached["candidates"].get(cached["regions"].get(start, -1), []).duplicate()
	options.sort_custom(func(a, b):
		var left: int = Grid.shared().distance(a, start)
		var right: int = Grid.shared().distance(b, start)
		return left < right if left != right else a < b)
	return options

static func line_of_sight(board: Dictionary, start: int, target: int, source_city: String = "") -> bool:
	var grid = Grid.shared()
	var count: int = grid.distance(start, target)
	var buildings := {}
	for site in board.get("fortifications", {}).values():
		if source_city != "" and site["id"] == source_city: continue
		for cell in site["cells"]: buildings[int(cell)] = true
	for index in range(1, count):
		var cell: int = grid.pick(grid.center(start).lerp(grid.center(target), float(index) / count))
		if not grid.walkable(cell) or buildings.has(cell): return false
	return true

static func inside_city(board: Dictionary, cell: int) -> String:
	# 城防内部判定：部队所在格属于某城 footprint 时返回该城节点，否则返回空。
	# 城内侧与城外侧互不通行攻击，只有破口开放且真正入城才能与驻军交战。
	for site in board.get("fortifications", {}).values():
		for value in site["cells"]:
			if int(value) == cell: return str(site["id"])
	return ""


static func breach(war, node: String, attackers: Array) -> void:
	var site := for_city(war.store, node)
	if site.is_empty(): return
	# 通道格必须可通行：优先从既有 site.cells 里选 walkable 的墙格；
	# 全部不可通行时才退回原规则（不虚构几何）。
	var grid = Grid.shared()
	var candidates: Array = []
	for value in site["cells"]:
		if grid.walkable(int(value)): candidates.append(int(value))
	if candidates.is_empty():
		for value in site["cells"]: candidates.append(int(value))
	var gate := int(site["gate"])
	if not attackers.is_empty() and attackers[0].has("tactical"):
		var source: int = attackers[0]["tactical"]["cell"]
		candidates.sort_custom(func(a, b):
			var left: int = grid.distance(source, int(a))
			var right: int = grid.distance(source, int(b))
			return left < right if left != right else int(a) < int(b))
		gate = int(candidates[0])
	elif not candidates.has(gate):
		gate = int(candidates[0])
	war.state["sieges"][node]["breach_cell"] = gate
	war.state["sieges"][node]["breach_open"] = true
	for army in war.active_armies():
		if army.has("tactical"):
			army["tactical"].erase("previous_goal")
			army["tactical"].erase("flank_goal")

static func fire(war) -> void:
	war.state["city_volleys"] = []
	var grid = Grid.shared()
	var cities: Array = war.store.scenario.get("places", {}).keys()
	cities.sort()
	for node in cities:
		var city: Dictionary = war.store.city_state(node)
		if not city.has("garrison") or int(city.get("garrison", 0)) <= 0: continue
		if int(city.get("last_volley_tick", -10)) + 2 > int(war.state["tick"]): continue
		var site := for_city(war.store, node)
		if site.is_empty(): continue
		var targets: Array = []
		for army in war.active_armies():
			if not army.has("tactical") or not war.hostile(str(army["faction"]), str(city.get("faction", ""))): continue
			var board: Dictionary = war.Tactical.board_for(war, army)
			if not board.get("objectives", {}).has(node): continue
			var cell: int = army["tactical"]["cell"]
			if distance_to_wall(board, node, cell) > 2: continue
			if line_of_sight(board, int(site["center"]), cell, node): targets.append(army)
		if targets.is_empty(): continue
		targets.sort_custom(func(a, b):
			var left: int = grid.distance(int(site["center"]), int(a["tactical"]["cell"]))
			var right: int = grid.distance(int(site["center"]), int(b["tactical"]["cell"]))
			return left < right if left != right else str(a["id"]) < str(b["id"]))
		war._sync_inventory(city)
		var guard := Fate.garrison(war, node, city)
		# One garrison bow budget is divided between all visible enemies in range.
		# Adding targets never duplicates the city's archers or wall-duty infantry.
		var archers := int(city["units"].get("archers", 0)) + int(int(city["units"].get("infantry", 0)) * 0.2)
		if archers <= 0: continue
		var count := mini(targets.size(), archers)
		var share := archers / count
		var remainder := archers % count
		city["last_volley_tick"] = int(war.state["tick"])
		for index in range(count):
			var target: Dictionary = targets[index]
			var shooters: int = share + (1 if index < remainder else 0)
			var target_cell := int(target["tactical"]["cell"])
			var defender := {"units": {"infantry": 0, "archers": shooters, "cavalry": 0}, "training": city.get("training", 50), "equipment": city.get("equipment", 50), "morale": 100.0, "organization": 100.0, "fatigue": 0.0, "ranged_attack": true, "skills": war.roster.officers[guard["officer_id"]]["skills"], "officer_id": guard["officer_id"]}
			var hit := Combat.losses_detail(defender, target, war.rules, war.Tactical.terrain_class(target_cell), 0.45)
			var dead_before := int(target.get("dead", 0))
			var loss := Combat.apply_loss(target, int(hit["loss"]))
			Fate.credit_garrison(war, guard, int(target["dead"]) - dead_before, float(hit.get("personal_fraction", 0)))
			war.Feedback.loss(war, target, loss)
			war._check_rout(target)
			war.state["city_volleys"].append({"id": "%s:%d:%s" % [node, int(war.state["tick"]), target["id"]], "city": node, "faction": city.get("faction", ""), "target": target["id"], "target_cell": target_cell, "source_cell": int(site["center"]), "wall_height": site["height"], "tick": int(war.state["tick"]), "loss": loss, "shooters": shooters, "target_count": count})
			war._report(target, "城墙反击", "%s城防向%s齐射，损失%d人。" % [war.graph.name_of(node), target["name"], loss], false)
