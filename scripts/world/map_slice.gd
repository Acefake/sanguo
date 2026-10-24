extends Node2D

const CitySkin = preload("res://scripts/ui/city_ui_skin.gd")
const WorldTerritories = preload("res://scripts/world/world_territories.gd")
const CampaignUI = preload("res://scripts/war/ui/campaign_ui.gd")

const MAP_DATA_PATH := "res://data/world_map.json"
const SCENARIO_PATH := "res://data/scenario_world_demo.json"
const MAP_IMAGE_PATH := "res://assets/map/supplied/world-relief.png"
const CITY_SCENE_PATH := "res://scenes/city_interior.tscn"
const INK := Color("241c16")
const GOLD := Color("f6d89b")
const PALE := Color("fff2d0")
const SHIELD_SPRITE: Texture2D = preload("res://assets/map/supplied/shield-silhouette.png")

var map_data: Dictionary = {}
var scenario: Dictionary = {}
var places: Dictionary = {}
var regions: Dictionary = {}
var routes: Array = []
var map_size := Vector2(1260, 710)
var camera: Camera2D
var hovered_id := ""
var selected_id := ""
var origin_id := "luoyang"
var blocked_pass_id := ""
var route_ids: Array[String] = []
var route_nodes: Array[String] = []
var route_cost := 0.0
var drag_active := false
var drag_moved := false
var drag_start := Vector2.ZERO

var detail_panel: PanelContainer
var detail_name: Label
var detail_meta: Label
var detail_description: Label
var detail_faction: Label
var detail_swatch: ColorRect
var detail_stats: GridContainer
var enter_button: Button
var tooltip: PanelContainer
var tooltip_label: Label
var city_view: CanvasLayer
var territories: Dictionary = {}
var faction_labels: Array[Label] = []
var map_mode := "faction"
var block_textures: Dictionary = {}
var shared_boundaries: Texture2D
var shield_shadow: Texture2D
var shield_outline: Texture2D
var neutral_white := false
var legend_panel: PanelContainer
var marker_font: Font
var city_labels: Dictionary = {}
var province_labels: Array[Label] = []
var label_detail := -1
var ownership_snapshot: Dictionary = {}
var war_ui: CanvasLayer
var ui_refresh_pending := false
const OVERVIEW_CITIES := ["jiuquan", "wuwei", "tianshui", "jinyang", "ji", "beiping", "xiangping", "ye", "nanpi", "jinan", "beihai", "changan", "luoyang", "chenliu", "puyang", "xiaopei", "xiapi", "xuchang", "runan", "hanzhong", "chengdu", "jiangzhou", "xiangyang", "jiangling", "changsha", "shouchun", "jianye", "wu", "kuaiji", "jiaozhi", "nanhai"]


func _ready() -> void:
	_load_map_data()
	if not GameState.pending_map_origin.is_empty():
		origin_id = GameState.pending_map_origin
		GameState.pending_map_origin = ""
	territories = WorldTerritories.build(map_data)
	for block in map_data.get("territory_blocks", []):
		block_textures[str(block["id"])] = load(str(block["texture"]))
	if not str(map_data.get("shared_boundaries", "")).is_empty():
		shared_boundaries = load(str(map_data["shared_boundaries"]))
	marker_font = CitySkin.font()
	shield_shadow = _create_shield_shadow()
	shield_outline = _create_shield_shadow(true)
	var background := Sprite2D.new()
	background.texture = load(str(map_data.get("background_texture", MAP_IMAGE_PATH)))
	background.centered = false
	background.scale = map_size / background.texture.get_size()
	background.z_index = -10
	add_child(background)
	_build_map_labels()
	_refresh_faction_labels()

	camera = Camera2D.new()
	add_child(camera)
	camera.make_current()
	_build_ui()
	_reset_view()
	get_viewport().size_changed.connect(_clamp_camera)
	GameState.city_changed.connect(_on_city_changed)
	GameState.month_changed.connect(_on_month_changed)
	_refresh_ui()
	war_ui = CampaignUI.new()
	war_ui.store = GameState
	add_child(war_ui)
	GameState.campaign_changed.connect(func():
		_schedule_ui_refresh()
		queue_redraw()
	)


func _load_map_data() -> void:
	var file := FileAccess.open(MAP_DATA_PATH, FileAccess.READ)
	if file == null:
		push_error("无法读取地图数据：" + MAP_DATA_PATH)
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if not parsed is Dictionary:
		push_error("地图数据不是有效的 JSON 对象")
		return
	map_data = parsed
	var size_data: Array = map_data.get("image_size", [1260, 710])
	map_size = Vector2(float(size_data[0]), float(size_data[1]))
	for place in map_data.get("places", []):
		places[str(place["id"])] = place
	for region in map_data.get("regions", []):
		regions[str(region["id"])] = region
	routes = map_data.get("routes", [])
	scenario = GameState.scenario


func _draw() -> void:
	# 用户底图、原始边界、动态领地、道路和城池分别绘制。
	for block in map_data.get("territory_blocks", []):
		var controller := str(block["city_id"])
		if map_mode == "faction":
			var rect_data: Array = block["rect"]
			var rect := Rect2(float(rect_data[0]), float(rect_data[1]), float(rect_data[2]), float(rect_data[3]))
			draw_texture_rect(block_textures[str(block["id"])], rect, false, _territory_color(controller))
		if controller == _selected_territory_controller():
			var selected_rect: Array = block["rect"]
			var shade_rect := Rect2(float(selected_rect[0]), float(selected_rect[1]), float(selected_rect[2]), float(selected_rect[3]))
			draw_texture_rect(block_textures[str(block["id"])], shade_rect, false, Color(0, 0, 0, 0.18))
	draw_texture(shared_boundaries, Vector2.ZERO)
	# 行军路线显示已按需求移除（底图路网与选中高亮均不再绘制）。
	for place_id in places:
		var place: Dictionary = places[place_id]
		if str(place["type"]) == "city" and not _city_marker_visible(str(place_id)):
			continue
		if str(place["type"]) == "pass":
			_draw_pass(str(place_id))
		else:
			_draw_city(str(place_id))

	if origin_id != "" and places.has(origin_id) and str(places[origin_id]["type"]) == "pass":
		_draw_marker(origin_id, Color("f0c879"), 21.0, 2.5)
	if hovered_id != "" and hovered_id != selected_id and str(places[hovered_id]["type"]) == "pass":
		_draw_marker(hovered_id, Color("ffffff"), 23.0, 2.0)
	if selected_id != "" and str(places[selected_id]["type"]) == "pass":
		_draw_marker(selected_id, Color("fff1bd"), 27.0, 3.5)
	# 行军路线封锁标记已按需求移除（不再绘制关隘封锁叉号）。
	if blocked_pass_id != "":
		pass
	if camera != null:
		for marker in GameState.war.player_markers():
			var point: Vector2 = GameState.war.graph.position(marker["location"]) + Vector2(0, 28)
			var radius: float = 9.0 / camera.zoom.x
			draw_circle(point, radius, Color("8b352b"))
			draw_arc(point, radius, 0, TAU, 24, Color("f6d89b"), 1.5 / camera.zoom.x, true)
			draw_string(marker_font, point + Vector2(radius + 4, 4), str(marker["name"]), HORIZONTAL_ALIGNMENT_LEFT, -1, int(16.0 / camera.zoom.x), PALE)


func _faction_id(place_id: String) -> String:
	var state: Dictionary = scenario.get("places", {}).get(place_id, {})
	var owner := str(state.get("faction", ""))
	return owner if scenario.get("factions", {}).has(owner) else ""


func _territory_color(place_id: String) -> Color:
	if map_mode == "terrain":
		return Color("ded7c0", 0.0)
	if _faction_id(place_id) == "":
		return Color("d9e0d3", 0.92) if neutral_white else Color("ffffff", 0.0)
	var color := _faction_color(place_id)
	color.a = 0.88
	return color


func _city_marker_visible(place_id: String) -> bool:
	return territories.has(place_id) or (camera != null and camera.zoom.x >= 0.85) or place_id == selected_id


func _selected_territory_controller() -> String:
	if not places.has(selected_id) or str(places[selected_id]["type"]) != "city":
		return ""
	return str(places[selected_id].get("territory_city_id", selected_id))


func _points_from_data(raw_points: Array) -> PackedVector2Array:
	var points := PackedVector2Array()
	for raw in raw_points:
		points.append(Vector2(float(raw[0]), float(raw[1])))
	return points


func _smooth_route(route: Dictionary) -> PackedVector2Array:
	var controls := _points_from_data(route["points"])
	var result := PackedVector2Array()
	if controls.size() < 3:
		return controls
	for i in range(controls.size() - 1):
		var p0: Vector2 = controls[maxi(i - 1, 0)]
		var p1: Vector2 = controls[i]
		var p2: Vector2 = controls[i + 1]
		var p3: Vector2 = controls[mini(i + 2, controls.size() - 1)]
		for step in range(8):
			var t := float(step) / 8.0
			var t2 := t * t
			var t3 := t2 * t
			result.append(0.5 * ((2.0 * p1) + (-p0 + p2) * t + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2 + (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3))
	result.append(controls[controls.size() - 1])
	return result


func _draw_city(place_id: String) -> void:
	var center := _place_position(place_id)
	draw_texture(shield_shadow, center + Vector2(-32, -28))
	var city_color := _faction_color(place_id)
	var badge_rect := Rect2(center + Vector2(-15, -17), Vector2(30, 36))
	var shield_tint := city_color if _faction_id(place_id) != "" else Color("fbfaf0")
	if place_id == selected_id or place_id == hovered_id:
		draw_texture(shield_outline, center + Vector2(-32, -30))
	draw_texture_rect(SHIELD_SPRITE, badge_rect, false, shield_tint)
	if camera != null:
		var faction: Dictionary = scenario.get("factions", {}).get(_faction_id(place_id), {})
		var caption := str(faction.get("short", ""))
		var font_size := 20
		var text_width := marker_font.get_string_size(caption, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
		var baseline := -4.0 + (marker_font.get_ascent(font_size) - marker_font.get_descent(font_size)) * 0.5
		var text_position := center + Vector2(-text_width * 0.5, baseline)
		draw_string_outline(marker_font, text_position, caption, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, 1, Color("30291e", 0.85))
		draw_string(marker_font, text_position, caption, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color("fffaf0"))


func _create_shield_shadow(outline_only: bool = false) -> Texture2D:
	var shadow_image := Image.create(64, 72, false, Image.FORMAT_RGBA8)
	var shape := _shield(Vector2(32, 30), 1.0)
	for y in range(72):
		for x in range(64):
			var point := Vector2(x + 0.5, y + 0.5)
			var distance := INF
			for i in range(shape.size()):
				var nearest := Geometry2D.get_closest_point_to_segment(point, shape[i], shape[(i + 1) % shape.size()])
				distance = minf(distance, point.distance_to(nearest))
			if Geometry2D.is_point_in_polygon(point, shape):
				distance = -distance
			var opacity := smoothstep(-3.5, 3.5, -distance) * 0.30
			if outline_only:
				opacity = exp(-pow(distance / 0.9, 2.0)) * 0.48
			shadow_image.set_pixel(x, y, Color(0, 0, 0, opacity))
	return ImageTexture.create_from_image(shadow_image)


func _shield(center: Vector2, scale_factor: float) -> PackedVector2Array:
	var points := PackedVector2Array()
	for offset in [Vector2(-15, -17), Vector2(15, -17), Vector2(15, 8), Vector2(0, 19), Vector2(-15, 8)]:
		points.append(center + offset * scale_factor)
	return points

func _draw_pass(place_id: String) -> void:
	var center := _place_position(place_id)
	var badge_rect := Rect2(center + Vector2(-11, -13), Vector2(22, 27))
	draw_texture_rect(shield_shadow, Rect2(center + Vector2(-23.5, -20.5), Vector2(47, 53)), false)
	var shield_tint := Color("e7e2d5")
	if place_id == selected_id or place_id == hovered_id:
		draw_texture_rect(shield_outline, Rect2(center + Vector2(-23.5, -22), Vector2(47, 53)), false)
	draw_texture_rect(SHIELD_SPRITE, badge_rect, false, shield_tint)


func _faction_color(place_id: String) -> Color:
	var city_state: Dictionary = scenario.get("places", {}).get(place_id, {})
	var faction: Dictionary = scenario.get("factions", {}).get(str(city_state.get("faction", "")), {})
	return Color(str(faction.get("color", "#e6e4da")))


func _build_map_labels() -> void:
	for place_id in places:
		var place: Dictionary = places[place_id]
		if str(place["type"]) != "city":
			continue
		var label := _map_label(str(place["name"]), 21, Color("fff9e7"))
		var location := _place_position(str(place_id))
		var above: bool = place_id in ["puyang", "henei", "hedong", "jinan", "beihai", "jianye", "shanyang", "ye", "zhongshan"]
		label.position = location + Vector2(-55, -53 if above else 21)
		label.size = Vector2(110, 33)
		label.z_index = 4
		add_child(label)
		city_labels[place_id] = label
	for region in map_data.get("regions", []):
		var label := _map_label(str(region["name"]), 26, Color("eee5c9", 0.45))
		label.position = Vector2(float(region["label"][0]) - 50.0, float(region["label"][1]) - 17.0)
		label.size = Vector2(100, 38)
		label.z_index = 1
		add_child(label)
		province_labels.append(label)
		label.hide()


func _refresh_faction_labels() -> void:
	for place_id in places:
		ownership_snapshot[place_id] = _faction_id(str(place_id))
	for label in faction_labels:
		remove_child(label)
		label.queue_free()
	faction_labels.clear()
	var occupied: Array[Rect2] = []
	for place_id in city_labels:
		var city_label: Label = city_labels[place_id]
		if city_label.visible:
			occupied.append(city_label.get_rect().grow(8))
	for place_id in places:
		occupied.append(Rect2(_place_position(str(place_id)) - Vector2(20, 20), Vector2(40, 40)))
	var groups: Dictionary = {}
	for place_id in territories:
		var owner := _faction_id(str(place_id))
		if owner == "":
			continue
		if not groups.has(owner):
			groups[owner] = []
		for polygon in territories[place_id]:
			groups[owner].append(polygon)
	for owner in groups:
		var pieces: Array = groups[owner]
		var total := 0.0
		var weighted := Vector2.ZERO
		var largest := 0.0
		var fallback := Vector2.ZERO
		for polygon in pieces:
			var info := _polygon_centroid(polygon)
			var area := float(info["area"])
			var center: Vector2 = info["center"]
			weighted += center * area
			total += area
			if area > largest:
				largest = area
				fallback = center
		var center := weighted / maxf(total, 1.0)
		if not _point_in_pieces(center, pieces):
			center = fallback
		var faction: Dictionary = scenario["factions"][owner]
		var point_size := 34 if total > 18000 else 27
		var title := str(faction["name"])
		var dimensions := Vector2(title.length() * point_size + 12, point_size + 12)
		center = _find_label_space(center, pieces, dimensions, occupied)
		var label := _map_label(title, point_size, Color("fff3cd", 0.96))
		label.position = center - dimensions * 0.5
		label.size = dimensions
		occupied.append(Rect2(label.position, dimensions).grow(8))
		label.z_index = 3
		label.visible = map_mode == "faction" and bool(map_data.get("show_faction_labels", false))
		add_child(label)
		faction_labels.append(label)


func _polygon_centroid(polygon: PackedVector2Array) -> Dictionary:
	var twice_area := 0.0
	var weighted := Vector2.ZERO
	for i in range(polygon.size()):
		var a := polygon[i]
		var b := polygon[(i + 1) % polygon.size()]
		var cross := a.cross(b)
		twice_area += cross
		weighted += (a + b) * cross
	return {"area": absf(twice_area) * 0.5, "center": weighted / (3.0 * twice_area) if absf(twice_area) > 0.1 else polygon[0]}


func _point_in_pieces(point: Vector2, pieces: Array) -> bool:
	for polygon in pieces:
		if Geometry2D.is_point_in_polygon(point, polygon):
			return true
	return false


func _find_label_space(center: Vector2, pieces: Array, dimensions: Vector2, occupied: Array[Rect2]) -> Vector2:
	var best := center
	var best_score := -INF
	var candidates: Array[Vector2] = [center]
	for polygon in pieces:
		var bounds := Rect2(polygon[0], Vector2.ZERO)
		for vertex in polygon:
			bounds = bounds.expand(vertex)
		for x in range(int(bounds.position.x) + 30, int(bounds.end.x), 45):
			for y in range(int(bounds.position.y) + 20, int(bounds.end.y), 40):
				candidates.append(Vector2(x, y))
	for point in candidates:
		if not _point_in_pieces(point, pieces):
			continue
		var candidate_rect := Rect2(point - dimensions * 0.5, dimensions)
		var overlaps := 0
		for rect in occupied:
			if candidate_rect.intersects(rect):
				overlaps += 1
		var score := 1000.0 - overlaps * 500.0 - point.distance_to(center) * 0.4
		for place_id in places:
			if point.distance_to(_place_position(str(place_id))) < 32:
				score -= 500
		if score > best_score:
			best_score = score
			best = point
	return best


func _update_label_detail() -> void:
	var next := 1 if camera.zoom.x >= 0.85 else 0
	if next == label_detail:
		return
	label_detail = next
	for place_id in city_labels:
		city_labels[place_id].visible = next == 1 or territories.has(place_id)
	_refresh_faction_labels()

func _map_label(value: String, size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = value
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_override("font", CitySkin.font())
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_shadow_color", Color("231d17", 0.95))
	label.add_theme_color_override("font_outline_color", Color("28251e", 0.85))
	label.add_theme_constant_override("outline_size", 2)
	label.add_theme_constant_override("shadow_offset_x", 2)
	label.add_theme_constant_override("shadow_offset_y", 2)
	return label


func _draw_marker(place_id: String, color: Color, radius: float, width: float) -> void:
	var center := _place_position(place_id)
	if str(places[place_id]["type"]) == "pass":
		draw_rect(Rect2(center - Vector2(radius, radius), Vector2.ONE * radius * 2.0), color, false, width)
		return
	var outline := _shield(center, radius / 16.0)
	var border: PackedVector2Array = outline.duplicate()
	border.append(border[0])
	draw_polyline(border, color, width, true)

func _unhandled_input(event: InputEvent) -> void:
	if city_view != null:
		return
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				drag_active = true
				drag_moved = false
				drag_start = event.position
			else:
				if drag_active and not drag_moved:
					_select_at(get_global_mouse_position())
				drag_active = false
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion:
		var next_hover := _nearest_place(get_global_mouse_position())
		if next_hover != hovered_id:
			hovered_id = next_hover
			queue_redraw()
		_update_tooltip(event.position)
		if drag_active and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			if event.position.distance_to(drag_start) > 5.0:
				drag_moved = true
			if drag_moved:
				camera.position -= event.relative / camera.zoom.x
				_clamp_camera()
				get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			selected_id = ""
			_clear_route()
			_refresh_ui()
		elif event.keycode == KEY_F:
			_reset_view()
		elif event.keycode == KEY_M:
			_toggle_map_mode()
		elif event.keycode == KEY_N:
			_toggle_neutral_style()
		elif event.keycode == KEY_L:
			_toggle_legend()
		elif event.keycode == KEY_T:
			get_tree().change_scene_to_file("res://scenes/rtk14_world_3d.tscn")


func _select_at(world_pos: Vector2) -> void:
	for marker in GameState.war.player_markers():
		if world_pos.distance_to(GameState.war.graph.position(marker["location"]) + Vector2(0, 28)) < 15.0 / camera.zoom.x:
			war_ui.show_reports()
			return
	var place_id := _nearest_place(world_pos)
	if place_id == "":
		return
	if place_id == selected_id and str(places[place_id]["type"]) == "city":
		_enter_selected_city()
		return
	selected_id = place_id
	tooltip.hide()
	_update_route()
	_refresh_ui()


func _nearest_place(world_pos: Vector2) -> String:
	var best_id := ""
	var hit_radius := 24.0 / camera.zoom.x
	var best_distance := hit_radius
	for place_id in places:
		if str(places[place_id]["type"]) == "city" and not _city_marker_visible(str(place_id)):
			continue
		var distance := world_pos.distance_to(_place_position(str(place_id)))
		if distance < best_distance:
			best_distance = distance
			best_id = str(place_id)
	if best_id != "":
		return best_id
	for controller in territories:
		if _point_in_pieces(world_pos, territories[controller]):
			return str(controller)
	return ""


func _place_position(place_id: String) -> Vector2:
	var place: Dictionary = places.get(place_id, {})
	return Vector2(float(place.get("x", 0)), float(place.get("y", 0)))


func _zoom_at(screen_pos: Vector2, factor: float) -> void:
	var before := get_global_mouse_position()
	var next_zoom := clampf(camera.zoom.x * factor, float(map_data.get("zoom_min", 0.45)), float(map_data.get("zoom_max", 3.2)))
	camera.zoom = Vector2.ONE * next_zoom
	var viewport_center := get_viewport_rect().size * 0.5
	camera.position = before - (screen_pos - viewport_center) / next_zoom
	_clamp_camera()
	queue_redraw()


func _reset_view() -> void:
	if camera == null:
		return
	var viewport_size := get_viewport_rect().size
	var fit := minf((viewport_size.x - 24.0) / map_size.x, (viewport_size.y - 104.0) / map_size.y) * 0.98
	camera.zoom = Vector2.ONE * fit
	camera.position = map_size * 0.5
	_clamp_camera()


func _clamp_camera() -> void:
	if camera == null:
		return
	var half_visible := get_viewport_rect().size * 0.5 / camera.zoom.x
	var pos := camera.position
	if half_visible.x * 2.0 >= map_size.x:
		pos.x = map_size.x * 0.5
	else:
		pos.x = clampf(pos.x, half_visible.x, map_size.x - half_visible.x)
	if half_visible.y * 2.0 >= map_size.y:
		pos.y = map_size.y * 0.5
	else:
		pos.y = clampf(pos.y, half_visible.y, map_size.y - half_visible.y)
	camera.position = pos
	_update_label_detail()


func _update_route() -> void:
	_clear_route()
	if selected_id == "" or selected_id == origin_id:
		return
	var result := _find_route(origin_id, selected_id)
	if bool(result["found"]):
		route_ids.assign(result["route_ids"])
		route_nodes.assign(result["nodes"])
		route_cost = float(result["cost"])
	queue_redraw()


func _clear_route() -> void:
	route_ids.clear()
	route_nodes.clear()
	route_cost = 0.0
	queue_redraw()


func _find_route(start_id: String, end_id: String) -> Dictionary:
	var distance: Dictionary = {start_id: 0.0}
	var previous: Dictionary = {}
	var visited: Dictionary = {}
	var frontier: Array[String] = [start_id]
	while not frontier.is_empty():
		var best_index := 0
		for i in range(1, frontier.size()):
			if float(distance[frontier[i]]) < float(distance[frontier[best_index]]):
				best_index = i
		var current := frontier[best_index]
		frontier.remove_at(best_index)
		if visited.has(current):
			continue
		visited[current] = true
		if current == end_id:
			break
		for route in routes:
			var next_id := ""
			if str(route["from"]) == current:
				next_id = str(route["to"])
			elif str(route["to"]) == current:
				next_id = str(route["from"])
			if next_id == "" or visited.has(next_id):
				continue
			if blocked_pass_id != "" and (current == blocked_pass_id or next_id == blocked_pass_id):
				continue
			var candidate := float(distance[current]) + float(route["cost"])
			if not distance.has(next_id) or candidate < float(distance[next_id]):
				distance[next_id] = candidate
				previous[next_id] = {"place": current, "route": str(route["id"])}
				frontier.append(next_id)
	if not distance.has(end_id):
		return {"found": false, "nodes": [], "route_ids": [], "cost": 0.0}
	var nodes: Array[String] = [end_id]
	var edges: Array[String] = []
	var cursor := end_id
	while cursor != start_id:
		var step: Dictionary = previous[cursor]
		edges.push_front(str(step["route"]))
		cursor = str(step["place"])
		nodes.push_front(cursor)
	return {"found": true, "nodes": nodes, "route_ids": edges, "cost": distance[end_id]}


func _route_by_id(route_id: String) -> Dictionary:
	for route in routes:
		if str(route["id"]) == route_id:
			return route
	return {}


func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var map_switch := _button("切换3D地图", func() -> void: get_tree().change_scene_to_file("res://scenes/rtk14_world_3d.tscn"))
	map_switch.name = "Switch3DMap"
	map_switch.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	map_switch.offset_left = -142
	map_switch.offset_right = -14
	map_switch.offset_top = 14
	map_switch.offset_bottom = 48
	layer.add_child(map_switch)
	# 顶栏与底部提示条已按需求移除，只留地图本体。
	# 原顶栏功能改用键盘：M 势力/地形切换，N 无主样式切换，
	# L 势力图例，F 回到全图，T 进入 3D 山河，Esc 清除选中与路线。

	detail_panel = PanelContainer.new()
	detail_panel.anchor_left = 1.0
	detail_panel.anchor_right = 1.0
	detail_panel.anchor_bottom = 1.0
	detail_panel.offset_left = -278
	detail_panel.offset_right = -14
	detail_panel.offset_top = 70
	detail_panel.offset_bottom = -12
	var paper := StyleBoxTexture.new()
	paper.texture = load("res://assets/city/han/ui/user-atlas/detail-paper.png")
	paper.axis_stretch_horizontal = StyleBoxTexture.AXIS_STRETCH_MODE_TILE
	paper.axis_stretch_vertical = StyleBoxTexture.AXIS_STRETCH_MODE_TILE
	paper.set_content_margin_all(14)
	detail_panel.add_theme_stylebox_override("panel", paper)
	layer.add_child(detail_panel)
	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 8)
	detail_panel.add_child(outer)
	var heading := PanelContainer.new()
	var heading_style := StyleBoxTexture.new()
	heading_style.texture = load("res://assets/city/han/ui/user-atlas/detail-heading.png")
	heading_style.set_content_margin_all(5)
	heading.add_theme_stylebox_override("panel", heading_style)
	outer.add_child(heading)
	var header := HBoxContainer.new()
	heading.add_child(header)
	detail_name = _label("", 21, PALE)
	header.add_child(detail_name)
	var header_space := Control.new()
	header_space.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(header_space)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	outer.add_child(scroll)
	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 9)
	scroll.add_child(content)
	detail_meta = _label("", 17, Color("79664d"))
	content.add_child(detail_meta)
	var faction_row := HBoxContainer.new()
	faction_row.add_theme_constant_override("separation", 8)
	content.add_child(faction_row)
	detail_swatch = ColorRect.new()
	detail_swatch.custom_minimum_size = Vector2(11, 11)
	faction_row.add_child(detail_swatch)
	detail_faction = _label("", 17, Color("352e25"))
	faction_row.add_child(detail_faction)
	detail_description = _label("", 14, Color("665a48"))
	detail_description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(detail_description)
	content.add_child(HSeparator.new())
	content.add_child(_label("城务与军备", 16, Color("91664c")))
	detail_stats = GridContainer.new()
	detail_stats.columns = 1
	detail_stats.add_theme_constant_override("h_separation", 12)
	detail_stats.add_theme_constant_override("v_separation", 10)
	content.add_child(detail_stats)
	# 行军路线区块、「从此地出发」与「封锁/开放东侧关隘」已按需求移除。
	enter_button = _button("进入城市", _enter_selected_city, true)
	outer.add_child(enter_button)
	var dispatch_button := _button("派遣武将", func(): war_ui.show_dispatch(selected_id), true)
	dispatch_button.name = "DispatchOfficer"
	outer.add_child(dispatch_button)
	var disclaimer := _label("演示数值，待按剧本年份校定", 11, Color("79664d"))
	disclaimer.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	outer.add_child(disclaimer)
	detail_panel.hide()
	_build_legend(layer)

	tooltip = PanelContainer.new()
	tooltip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tooltip.custom_minimum_size = Vector2(198, 74)
	tooltip.add_theme_stylebox_override("panel", _panel_style(0.96))
	layer.add_child(tooltip)
	tooltip_label = _label("", 13, PALE)
	tooltip_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tooltip.add_child(tooltip_label)
	tooltip.hide()


func _panel_style(alpha: float) -> StyleBoxTexture:
	return CitySkin.dark_panel(alpha, 11)


func _build_legend(layer: CanvasLayer) -> void:
	legend_panel = PanelContainer.new()
	legend_panel.position = Vector2(665, 70)
	legend_panel.size = Vector2(575, 245)
	legend_panel.add_theme_stylebox_override("panel", _panel_style(0.96))
	layer.add_child(legend_panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 12)
	legend_panel.add_child(column)
	column.add_child(_label("势力图例  /  领地与城池归属", 18, GOLD))
	var grid := GridContainer.new()
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", 18)
	grid.add_theme_constant_override("v_separation", 12)
	column.add_child(grid)
	for faction_id in scenario["factions"]:
		var faction: Dictionary = scenario["factions"][faction_id]
		_legend_item(grid, str(faction["name"]), Color(str(faction["color"])))
	_legend_item(grid, "无主", Color("e6e4da"))
	column.add_child(_label("无主地默认保留地形，可用顶部按钮切换灰白底色。", 13, PALE))
	legend_panel.hide()


func _legend_item(grid: GridContainer, caption: String, color: Color) -> void:
	var row := HBoxContainer.new()
	row.custom_minimum_size.x = 115
	row.add_theme_constant_override("separation", 7)
	var swatch := ColorRect.new()
	swatch.color = color
	swatch.custom_minimum_size = Vector2(14, 14)
	swatch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(swatch)
	row.add_child(_label(caption, 15, PALE))
	grid.add_child(row)


func _toggle_legend() -> void:
	legend_panel.visible = not legend_panel.visible
	if legend_panel.visible:
		detail_panel.hide()


func _toggle_map_mode() -> void:
	map_mode = "terrain" if map_mode == "faction" else "faction"
	for label in faction_labels:
		label.visible = map_mode == "faction" and bool(map_data.get("show_faction_labels", false))
	for label in province_labels:
		label.visible = map_mode == "terrain"
	queue_redraw()


func _toggle_neutral_style() -> void:
	neutral_white = not neutral_white
	queue_redraw()


func _label(value: String, size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = value
	label.add_theme_font_override("font", CitySkin.font())
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	return label


func _button(value: String, callback: Callable, primary: bool = false) -> Button:
	var button := Button.new()
	button.text = value
	button.custom_minimum_size = Vector2(0, 32)
	button.add_theme_font_override("font", CitySkin.font())
	button.add_theme_font_size_override("font_size", 13)
	CitySkin.style_button(button, primary)
	button.pressed.connect(callback)
	return button

func _refresh_ui() -> void:
	if selected_id == "":
		detail_panel.hide()
		queue_redraw()
		return
	detail_panel.show()
	legend_panel.hide()
	var place: Dictionary = places[selected_id]
	var state: Dictionary = scenario.get("places", {}).get(selected_id, {})
	var faction: Dictionary = scenario.get("factions", {}).get(str(state.get("faction", "")), {})
	detail_name.text = str(place["name"])
	var region: Dictionary = regions.get(str(place["region_id"]), {})
	var type_name := "关隘" if str(place["type"]) == "pass" else "城池"
	enter_button.visible = str(place["type"]) == "city"
	enter_button.disabled = str(place["type"]) != "city"
	detail_meta.text = "%s  %s" % [str(region.get("name", "未分区")), type_name]
	detail_swatch.color = _faction_color(selected_id)
	detail_faction.text = str(faction.get("name", "无主")) + "  势力归属"
	detail_description.text = str(state.get("description", "暂无城池记述。"))
	for child in detail_stats.get_children():
		detail_stats.remove_child(child)
		child.queue_free()
	if str(place["type"]) == "pass":
		_add_stat("驻守兵力", _format_count(int(state.get("garrison", 0))))
		_add_stat("关防", "%d / 100" % int(state.get("defense", 0)))
	else:
		_add_stat("人口", _format_count(int(state.get("population", 0))))
		_add_stat("经济", "%d / 100" % int(state.get("economy", 0)))
		_add_stat("驻军", _format_count(int(state.get("garrison", 0))))
		_add_stat("城防", "%d / 100" % int(state.get("defense", 0)))
		_add_stat("粮草", _format_count(int(state.get("grain", 0))) + "斛")
		queue_redraw()


func _schedule_ui_refresh() -> void:
	if ui_refresh_pending:
		return
	ui_refresh_pending = true
	_flush_ui_refresh.call_deferred()


func _flush_ui_refresh() -> void:
	ui_refresh_pending = false
	_refresh_ui()


func _add_stat(caption: String, value: String) -> void:
	var cell := HBoxContainer.new()
	cell.custom_minimum_size = Vector2(220, 32)
	cell.add_theme_constant_override("separation", 12)
	var title := _label(caption, 17, Color("91664c"))
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cell.add_child(title)
	cell.add_child(_label(value, 19, Color("352e25")))
	detail_stats.add_child(cell)


func _format_count(value: int) -> String:
	if value >= 10000:
		return "%.1f万" % (float(value) / 10000.0)
	return str(value)


func _update_tooltip(screen_pos: Vector2) -> void:
	if hovered_id == "" or hovered_id == selected_id:
		tooltip.hide()
		return
	var place: Dictionary = places[hovered_id]
	var state: Dictionary = scenario.get("places", {}).get(hovered_id, {})
	var faction: Dictionary = scenario.get("factions", {}).get(str(state.get("faction", "")), {})
	if not GameState.war.player_has_city_access(hovered_id):
		var intel: Dictionary = GameState.war.player_city_intel(hovered_id)
		tooltip_label.text = "%s  %s\n%s" % [place["name"], faction.get("name", "无主"), "驻军 " + _format_count(int(intel["strength_estimate"]))]
	elif str(place["type"]) == "pass":
		tooltip_label.text = "%s  %s\n守军 %s  关防 %d" % [str(place["name"]), str(faction.get("name", "无主")), _format_count(int(state.get("garrison", 0))), int(state.get("defense", 0))]
	else:
		tooltip_label.text = "%s  %s\n人口 %s  驻军 %s" % [str(place["name"]), str(faction.get("name", "无主")), _format_count(int(state.get("population", 0))), _format_count(int(state.get("garrison", 0)))]
	var viewport_size := get_viewport_rect().size
	tooltip.position = Vector2(minf(screen_pos.x + 18.0, viewport_size.x - 212.0), minf(screen_pos.y + 18.0, viewport_size.y - 88.0))
	tooltip.show()


func _clear_selection() -> void:
	selected_id = ""
	_clear_route()
	_refresh_ui()


func _enter_selected_city() -> void:
	if selected_id == "" or str(places[selected_id]["type"]) != "city" or city_view != null:
		return
	var packed: PackedScene = load(CITY_SCENE_PATH)
	city_view = packed.instantiate()
	add_child(city_view)
	var place: Dictionary = places[selected_id]
	var region: Dictionary = regions.get(str(place["region_id"]), {})
	city_view.open_city(selected_id, str(place["name"]), str(region.get("name", "未分区")))
	city_view.closed.connect(_on_city_closed)
	tooltip.hide()
	if war_ui != null:
		war_ui.hide()


func _on_city_closed() -> void:
	city_view.queue_free()
	city_view = null
	if war_ui != null:
		war_ui.show()
	_refresh_ui()
	queue_redraw()


func _on_city_changed(_city_id: String) -> void:
	if str(ownership_snapshot.get(_city_id, "")) != _faction_id(_city_id):
		_refresh_faction_labels()
	if _city_id == selected_id:
		# 选中城市的归属变化立即同步详情面板，不等下帧。
		_refresh_ui()
	else:
		queue_redraw()


func _on_month_changed() -> void:
	_schedule_ui_refresh()
