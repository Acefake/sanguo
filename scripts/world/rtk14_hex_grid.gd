extends RefCounted

const WIDTH := 220
const DEPTH := 220
const COUNT := WIDTH * DEPTH
# Same ground-unit restrictions as war/tactical_battlefield.gd.
const BLOCKED_TERRAIN := [0, 10, 11, 13, 14, 19, 22, 23]
var words := PackedInt32Array()
var transform: Array = []
var region_cities: Dictionary = {}
var city_cells: Dictionary = {}
var path_graph: AStar2D
static var _shared: RefCounted


static func shared() -> RefCounted:
	if _shared == null:
		_shared = load("res://scripts/world/rtk14_hex_grid.gd").new()
		_shared.load_source()
	return _shared


func load_source() -> bool:
	if words.size() == COUNT * 4 and transform.size() == 4: return true
	var file := FileAccess.open("res://assets/rtk14/map_grid.bin", FileAccess.READ)
	if file == null or file.get_length() != 4 + COUNT * 16 or file.get_32() != COUNT:
		push_error("原始六角格数据无效")
		return false
	words = file.get_buffer(COUNT * 16).to_int32_array()
	var registration: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://assets/rtk14/grid_transform.json"))
	if not registration is Dictionary or registration.get("parameters", []).size() != 4:
		push_error("六角格坐标转换无效")
		return false
	transform = registration["parameters"]
	var cities: Array = JSON.parse_string(FileAccess.get_file_as_string("res://assets/rtk14/cities_map.json"))
	for city in cities:
		region_cities[int(city["region"])] = str(city["id"])
		for cell in city.get("cells", []):
			city_cells[int(cell)] = str(city["id"])
	return true


func valid(cell: int) -> bool:
	return cell >= 0 and cell < COUNT and words.size() == COUNT * 4


func index_at(column: int, row: int) -> int:
	return row * WIDTH + column if column >= 0 and column < WIDTH and row >= 0 and row < DEPTH else -1


func center(cell: int) -> Vector2:
	var column := cell % WIDTH
	var row := cell / WIDTH
	return Vector2(float(transform[2]) + column * float(transform[0]),
		float(transform[3]) + (row + (column % 2) * 0.5) * float(transform[1]))


func polygon(cell: int) -> PackedVector2Array:
	var point := center(cell)
	var x := float(transform[0]) / 3.0
	var y := float(transform[1]) * 0.5
	return PackedVector2Array([point + Vector2(2*x, 0), point + Vector2(x, y),
		point + Vector2(-x, y), point + Vector2(-2*x, 0), point + Vector2(-x, -y), point + Vector2(x, -y)])


func neighbors(cell: int) -> PackedInt32Array:
	var result := PackedInt32Array()
	if not valid(cell):
		return result
	var column := cell % WIDTH
	var row := cell / WIDTH
	var offset := column % 2
	for delta in [Vector2i(0,-1), Vector2i(0,1), Vector2i(-1,-1+offset),
		Vector2i(-1,offset), Vector2i(1,-1+offset), Vector2i(1,offset)]:
		var other := index_at(column + delta.x, row + delta.y)
		if other >= 0:
			result.append(other)
	return result


func pick(point: Vector2) -> int:
	if words.is_empty():
		return -1
	var column := int(round((point.x - float(transform[2])) / float(transform[0])))
	# Test nearby polygons rather than rounding both axes independently.
	for c in range(column - 1, column + 2):
		var row := int(round((point.y - float(transform[3])) / float(transform[1]) - posmod(c, 2) * 0.5))
		for r in range(row - 1, row + 2):
			var cell := index_at(c, r)
			if cell >= 0 and Geometry2D.is_point_in_polygon(point, polygon(cell)):
				return cell
	return -1


func terrain(cell: int) -> int:
	return words[cell * 4 + 1] & 255 if valid(cell) else -1


func region(cell: int) -> int:
	return (words[cell * 4 + 1] >> 16) & 65535 if valid(cell) else 0


func controller(cell: int) -> String:
	return str(region_cities.get(region(cell), ""))


func walkable(cell: int) -> bool:
	return valid(cell) and region(cell) != 0 and terrain(cell) not in BLOCKED_TERRAIN


func info(cell: int) -> Dictionary:
	if not valid(cell):
		return {}
	return {"id": cell, "column": cell % WIDTH, "row": cell / WIDTH,
		"position": center(cell), "terrain": terrain(cell), "region": region(cell),
		"controller": controller(cell), "city": str(city_cells.get(cell, "")),
		"walkable": walkable(cell), "raw": words.slice(cell * 4, cell * 4 + 4)}


func distance(a: int, b: int) -> int:
	var aq := a % WIDTH
	var bq := b % WIDTH
	var ar := a / WIDTH - (aq - posmod(aq, 2)) / 2
	var br := b / WIDTH - (bq - posmod(bq, 2)) / 2
	return maxi(absi(aq - bq), maxi(absi(ar - br), absi(aq + ar - bq - br)))


func step_toward(start: int, goal: int, occupied: Dictionary, bounds: Dictionary, stop_distance: int) -> int:
	# Tactical occupancy changes each day; do not disable points in the cached
	# nationwide AStar used by the main-map route preview.
	var queue: Array = [start]
	var previous := {start: start}
	var cursor := 0
	var found := -1
	# board["blocked"] is an Array, so .has() was a linear scan inside the BFS inner
	# loop: up to 1710 scans per call against a mountain-heavy board. Build the set once.
	var blocked := {}
	for cell in bounds.get("blocked", []): blocked[cell] = true
	while cursor < queue.size():
		var cell: int = queue[cursor]
		cursor += 1
		if distance(cell, goal) <= stop_distance: found = cell; break
		for next in neighbors(cell):
			var column: int = next % WIDTH
			var row: int = next / WIDTH
			if column < int(bounds.get("min_column", 0)) or column > int(bounds.get("max_column", WIDTH - 1)) or row < int(bounds.get("min_row", 0)) or row > int(bounds.get("max_row", DEPTH - 1)): continue
			if not walkable(next) or blocked.has(next) or occupied.has(next) or previous.has(next): continue
			previous[next] = cell
			queue.append(next)
	if found < 0 or found == start: return start
	while previous[found] != start: found = previous[found]
	return found


func find_path(start: int, goal: int, blocked: Array = []) -> PackedInt32Array:
	if not walkable(start) or not walkable(goal):
		return PackedInt32Array()
	if blocked.has(start) or blocked.has(goal): return PackedInt32Array()
	if path_graph == null:
		path_graph = AStar2D.new()
		path_graph.reserve_space(COUNT)
		for cell in range(COUNT):
			if walkable(cell):
				path_graph.add_point(cell, center(cell))
		for cell in range(COUNT):
			if not path_graph.has_point(cell):
				continue
			for other in neighbors(cell):
				if other > cell and path_graph.has_point(other):
					path_graph.connect_points(cell, other)
	var result := PackedInt32Array()
	for value in blocked:
		var cell := int(value)
		if path_graph.has_point(cell): path_graph.set_point_disabled(cell, true)
	for cell in path_graph.get_id_path(start, goal):
		result.append(int(cell))
	for value in blocked:
		var cell := int(value)
		if path_graph.has_point(cell): path_graph.set_point_disabled(cell, false)
	return result
