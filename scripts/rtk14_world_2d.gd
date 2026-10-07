extends "res://scripts/map_slice.gd"

# Keep shared 3D coordinates; register the source texture independently.
const WORLD_EXTENT := 2048.0
const SOURCE_CITIES := "res://assets/rtk14/cities_map.json"
const MAP_BOUNDS := Rect2(372, 128, 1548, 1792)
const HexGrid = preload("res://scripts/rtk14_hex_grid.gd")
const HexOverlay = preload("res://scripts/rtk14_hex_overlay.gd")
const Fortifications = preload("res://scripts/war/city_fortifications.gd")
var hex_grid = HexGrid.shared()
var hex_overlay: Node2D
var hovered_cell := -1
var selected_cell := -1
var cell_path := PackedInt32Array()
var cell_panel: PanelContainer
var cell_label: Label
var path_message := ""
var map_bounds := MAP_BOUNDS
var texture_scale := Vector2.ONE * 0.25
var texture_offset := Vector2.ZERO
var texture_crop := Rect2(1488, 512, 6192, 7168)


func _ready() -> void:
	if not hex_grid.load_source():
		return
	var registration: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://assets/rtk14/world_2d_registration.json"))
	var pixel_parameters: Array = registration["texture_parameters"]
	texture_scale = Vector2(float(hex_grid.transform[0]) / float(pixel_parameters[0]), float(hex_grid.transform[1]) / float(pixel_parameters[1]))
	texture_offset = Vector2(hex_grid.transform[2], hex_grid.transform[3]) - Vector2(pixel_parameters[2], pixel_parameters[3]) * texture_scale
	map_bounds = Rect2(texture_crop.position * texture_scale + texture_offset, texture_crop.size * texture_scale)
	super._ready()
	for child in get_children():
		if child is Sprite2D and child.z_index == -10:
			child.region_enabled = true
			child.region_rect = texture_crop
			child.position = map_bounds.position
			child.scale = texture_scale
			child.region_filter_clip_enabled = true
			child.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	hex_overlay = HexOverlay.new()
	hex_overlay.map = self
	hex_overlay.grid = hex_grid
	hex_overlay.z_index = -1
	add_child(hex_overlay)
	_build_cell_panel()
	GameState.city_changed.connect(func(_id: String): hex_overlay.queue_redraw())
	queue_redraw()


func _load_map_data() -> void:
	super._load_map_data()
	var legacy_places := places.duplicate(true)
	var source: Variant = JSON.parse_string(FileAccess.get_file_as_string(SOURCE_CITIES))
	if not source is Array:
		push_error("无法读取三国志14城市坐标")
		return
	var city_places: Array = []
	var positions: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/war/world_3d_positions.json")).get("positions", {})
	for city_id in legacy_places:
		var place: Dictionary = legacy_places[city_id].duplicate(true)
		var site := Fortifications.for_city(GameState, city_id)
		var point: Vector2 = site["point"] if not site.is_empty() else Vector2(float(positions.get(city_id, {}).get("x", place["x"])), float(positions.get(city_id, {}).get("z", place["y"])))
		place["x"] = point.x
		place["y"] = point.y
		places[city_id] = place
		city_places.append(place)
	map_size = Vector2.ONE * WORLD_EXTENT
	map_data["places"] = city_places
	map_data["image_size"] = [WORLD_EXTENT, WORLD_EXTENT]
	map_data["background_texture"] = "res://assets/rtk14/world_2d.png"
	map_data["territory_blocks"] = []
	map_data["shared_boundaries"] = ""
	map_data["regions"] = []
	map_data["zoom_min"] = 0.15
	map_data["zoom_max"] = 12.0
	# Route endpoints now use the same registered campaign positions as the 3D map.


func _city_marker_visible(_city_id: String) -> bool:
	return true


func _draw_city(city_id: String) -> void:
	var center := _place_position(city_id)
	var scale_factor := minf(1.0, 0.8 / camera.zoom.x)
	draw_set_transform(center, 0, Vector2.ONE * scale_factor)
	var tint := _faction_color(city_id) if not _faction_id(city_id).is_empty() else Color("fbfaf0")
	if city_id == selected_id or city_id == hovered_id:
		draw_texture(shield_outline, Vector2(-32, -30))
	draw_texture_rect(SHIELD_SPRITE, Rect2(-15, -17, 30, 36), false, tint)
	var faction: Dictionary = scenario.get("factions", {}).get(_faction_id(city_id), {})
	var caption := str(faction.get("short", ""))
	var text_width := marker_font.get_string_size(caption, HORIZONTAL_ALIGNMENT_LEFT, -1, 20).x
	draw_string_outline(marker_font, Vector2(-text_width * 0.5, 5), caption, HORIZONTAL_ALIGNMENT_LEFT, -1, 20, 2, Color("30291e"))
	draw_string(marker_font, Vector2(-text_width * 0.5, 5), caption, HORIZONTAL_ALIGNMENT_LEFT, -1, 20, PALE)
	draw_set_transform(Vector2.ZERO)


func _update_label_detail() -> void:
	if camera == null:
		return
	for city_id in city_labels:
		var label: Label = city_labels[city_id]
		label.add_theme_color_override("font_outline_color", Color("15120e"))
		label.add_theme_constant_override("outline_size", 4)
		label.visible = camera.zoom.x >= 0.55 or city_id in OVERVIEW_CITIES or city_id == selected_id
		var display_scale := 0.72 / camera.zoom.x
		label.scale = Vector2.ONE * display_scale
		label.position = _place_position(str(city_id)) + Vector2(-55 * display_scale, 24)


func _reset_view() -> void:
	if camera == null:
		return
	var viewport_size := get_viewport_rect().size
	var fit := minf((viewport_size.x - 24) / map_bounds.size.x, (viewport_size.y - 104) / map_bounds.size.y) * 0.98
	camera.zoom = Vector2.ONE * fit
	camera.position = map_bounds.get_center()
	_clamp_camera()


func _clamp_camera() -> void:
	if camera == null:
		return
	var half_visible := get_viewport_rect().size * 0.5 / camera.zoom.x
	var center := map_bounds.get_center()
	camera.position.x = center.x if half_visible.x * 2 >= map_bounds.size.x else clampf(camera.position.x, map_bounds.position.x + half_visible.x, map_bounds.end.x - half_visible.x)
	camera.position.y = center.y if half_visible.y * 2 >= map_bounds.size.y else clampf(camera.position.y, map_bounds.position.y + half_visible.y, map_bounds.end.y - half_visible.y)
	_update_label_detail()
	if hex_overlay != null:
		hex_overlay.queue_redraw()


func _draw() -> void:
	_draw_cell_selection()
	for city_id in places:
		if _city_marker_visible(str(city_id)):
			_draw_city(str(city_id))
	if camera == null:
		return
	for marker in GameState.war.player_markers():
		var location := str(marker["location"])
		if not places.has(location):
			continue
		var point := _place_position(location) + Vector2(0, 28)
		var radius := 9.0 / camera.zoom.x
		draw_circle(point, radius, Color("8b352b"))
		draw_arc(point, radius, 0, TAU, 24, GOLD, 1.5 / camera.zoom.x, true)
		draw_string(marker_font, point + Vector2(radius + 4, 4), str(marker["name"]),
			HORIZONTAL_ALIGNMENT_LEFT, -1, int(16.0 / camera.zoom.x), PALE)


func _select_at(world_pos: Vector2) -> void:
	selected_cell = hex_grid.pick(world_pos)
	cell_path.clear()
	path_message = ""
	_refresh_cell_panel()
	queue_redraw()
	for marker in GameState.war.player_markers():
		var location := str(marker["location"])
		if places.has(location) and world_pos.distance_to(_place_position(location) + Vector2(0, 28)) < 15.0 / camera.zoom.x:
			war_ui.show_reports()
			return
	var city_id := _nearest_place(world_pos)
	if city_id.is_empty():
		selected_id = ""
		_refresh_ui()
		return
	if city_id == selected_id:
		_enter_selected_city()
		return
	selected_id = city_id
	tooltip.hide()
	_refresh_ui()


func _unhandled_input(event: InputEvent) -> void:
	if city_view != null:
		return
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP or event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom_at(event.position, 1.14 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / 1.14)
			_refresh_cell_panel()
			get_viewport().set_input_as_handled()
			return
		if event.button_index == MOUSE_BUTTON_LEFT and event.shift_pressed:
			_preview_cell_path(hex_grid.pick(get_global_mouse_position()))
			get_viewport().set_input_as_handled()
			return
	if event is InputEventMouseMotion:
		var next_cell: int = hex_grid.pick(get_global_mouse_position())
		if next_cell != hovered_cell:
			hovered_cell = next_cell
			_refresh_cell_panel()
			queue_redraw()
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_G or event.keycode == KEY_B:
			if event.keycode == KEY_G:
				hex_overlay.show_lines = not hex_overlay.show_lines
			else:
				hex_overlay.show_ownership = not hex_overlay.show_ownership
			hex_overlay.queue_redraw()
			get_viewport().set_input_as_handled()
			return
		if event.keycode == KEY_ESCAPE:
			selected_cell = -1
			cell_path.clear()
			path_message = ""
			_refresh_cell_panel()
	super._unhandled_input(event)


func _draw_cell_selection() -> void:
	if camera == null or hex_grid.words.is_empty():
		return
	for cell in [hovered_cell, selected_cell]:
		if not hex_grid.valid(cell):
			continue
		var polygon: PackedVector2Array = hex_grid.polygon(cell)
		var color := GOLD if cell == selected_cell else Color.WHITE
		draw_colored_polygon(polygon, Color(color, 0.25))
		polygon.append(polygon[0])
		draw_polyline(polygon, color, 2.0 / camera.zoom.x, true)
	if cell_path.size() > 1:
		var points := PackedVector2Array()
		for cell in cell_path:
			points.append(hex_grid.center(cell))
		draw_polyline(points, GOLD, 3.0 / camera.zoom.x, true)
		for endpoint in [cell_path[0], cell_path[-1]]:
			draw_circle(hex_grid.center(endpoint), 4.0 / camera.zoom.x, GOLD)


func _preview_cell_path(goal: int) -> void:
	if not hex_grid.valid(goal):
		return
	if not hex_grid.valid(selected_cell):
		selected_cell = goal
		path_message = "已设起点；Shift 点击目标格"
	else:
		var bounds := {"min_column": 0, "max_column": 219, "min_row": 0, "max_row": 219, "blocked": []}
		Fortifications.attach(GameState.war, bounds)
		cell_path = hex_grid.find_path(selected_cell, goal, Fortifications.blocked_for(GameState.war, bounds, str(GameState.war.state["player_faction"])))
		path_message = "路径预览：%d 格" % cell_path.size() if not cell_path.is_empty() else "此地形不可通行，或两格之间无通路"
	_refresh_cell_panel()
	queue_redraw()


func _build_cell_panel() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	cell_panel = PanelContainer.new()
	cell_panel.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	cell_panel.offset_left = 14
	cell_panel.offset_top = -158
	cell_panel.offset_right = 360
	cell_panel.offset_bottom = -14
	cell_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cell_panel.add_theme_stylebox_override("panel", CitySkin.dark_panel(0.95, 10))
	cell_label = _label("", 15, PALE)
	cell_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cell_panel.add_child(cell_label)
	layer.add_child(cell_panel)
	_refresh_cell_panel()


func _refresh_cell_panel() -> void:
	if cell_label == null:
		return
	var cell := hovered_cell if hovered_cell >= 0 else selected_cell
	var hint := "滚轮缩放  拖动平移  点击选格\nG 格线  B 势力格  Shift 点击预览路径"
	if not hex_grid.valid(cell):
		cell_label.text = "六角地图  48,400 格\n" + hint
		return
	var data: Dictionary = hex_grid.info(cell)
	var city_id := str(data["controller"])
	var city_name := str(places.get(city_id, {}).get("name", "未归属城市"))
	var faction_id := _faction_id(city_id)
	var faction_name := str(scenario.get("factions", {}).get(faction_id, {}).get("name", "无主"))
	cell_label.text = "格 %d  列 %d / 行 %d\n地形 %d  区域 %d  %s\n%s  %s\n%s" % [cell, data["column"], data["row"], data["terrain"], data["region"], "可通行" if data["walkable"] else "不可通行", city_name, faction_name, path_message + "\n" + hint if not path_message.is_empty() else hint]
