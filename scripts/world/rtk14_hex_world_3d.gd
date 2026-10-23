extends Node3D

signal cell_selected(cell: int, preview: bool)

const Grid = preload("res://scripts/world/rtk14_hex_grid.gd")
const MapSkin = preload("res://scripts/ui/city_ui_skin.gd")
const Fortifications = preload("res://scripts/war/battle/city_fortifications.gd")
const StateKeys = preload("res://scripts/war/campaign/war_state_keys.gd")
var map: Node3D
var grid = Grid.shared()
var materials: Array[ShaderMaterial] = []
var enabled := false
var ui_visible := true
var hovered_cell := -1
var selected_cell := -1
var path := PackedInt32Array()
var path_mesh: MeshInstance3D
var panel: PanelContainer
var label: Label
var timer := 0.0
var path_message := ""
var last_mouse := Vector2(INF, INF)
var last_camera := Transform3D()
var maximum_surface_height := 100.0


func _ready() -> void:
	if not grid.load_source():
		return
	for value in map.heights:
		maximum_surface_height = maxf(maximum_surface_height, value * map.HEIGHT_SCALE + 20)
	for chunk in map.terrain_root.get_children():
		if chunk is MeshInstance3D and chunk.material_override is ShaderMaterial:
			var material: ShaderMaterial = chunk.material_override
			if not materials.has(material):
				materials.append(material)
	for material in materials:
		material.set_shader_parameter("hex_transform", Vector4(grid.transform[0], grid.transform[1], grid.transform[2], grid.transform[3]))
		material.set_shader_parameter("hex_grid_enabled", enabled)
	path_mesh = MeshInstance3D.new()
	path_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(path_mesh)
	var layer := CanvasLayer.new()
	add_child(layer)
	panel = PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	panel.offset_left = 14
	panel.offset_right = 340
	panel.offset_top = -266
	panel.offset_bottom = -116
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_theme_stylebox_override("panel", MapSkin.dark_panel(0.92, 10))
	label = Label.new()
	label.add_theme_font_override("font", MapSkin.font())
	label.add_theme_font_size_override("font_size", 15)
	label.add_theme_color_override("font_color", Color("fff2d0"))
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(label)
	layer.add_child(panel)
	panel.hide()
	_refresh_panel()


func _process(delta: float) -> void:
	if label == null:
		return
	var active: bool = enabled and map.city_interior == null and (map.officer_page == null or not map.officer_page.visible)
	panel.visible = false
	if not active:
		_set_hover(-1)
		return
	timer -= delta
	if timer > 0:
		return
	timer = 0.08
	var mouse := get_viewport().get_mouse_position()
	if mouse.is_equal_approx(last_mouse) and map.camera.global_transform.is_equal_approx(last_camera):
		return
	last_mouse = mouse
	last_camera = map.camera.global_transform
	if get_viewport().gui_get_hovered_control() != null or map.dragging_button != 0:
		_set_hover(-1)
		return
	_set_hover(cell_at_screen(mouse))


func _set_hover(cell: int) -> void:
	if hovered_cell == cell:
		return
	hovered_cell = cell
	for material in materials:
		material.set_shader_parameter("hex_hover", _shader_cell(cell))
	_refresh_panel()


func _shader_cell(cell: int) -> Vector2:
	return Vector2(cell % 220, cell / 220) if grid.valid(cell) else Vector2(-1, -1)


func cell_at_screen(screen: Vector2) -> int:
	var hit: Variant = ground_at_screen(screen)
	return grid.pick(Vector2(hit.x, hit.z)) if hit is Vector3 else -1


func ground_at_screen(screen: Vector2) -> Variant:
	var origin: Vector3 = map.camera.project_ray_origin(screen)
	var direction: Vector3 = map.camera.project_ray_normal(screen)
	var lower := Vector3(-5, -20, -5)
	var upper := Vector3(2053, maximum_surface_height, 2053)
	var near_t := 0.0
	var far_t: float = map.camera.far
	for axis in range(3):
		if absf(direction[axis]) < 0.000001:
			if origin[axis] < lower[axis] or origin[axis] > upper[axis]:
				return null
			continue
		var a: float = (lower[axis] - origin[axis]) / direction[axis]
		var b: float = (upper[axis] - origin[axis]) / direction[axis]
		near_t = maxf(near_t, minf(a, b))
		far_t = minf(far_t, maxf(a, b))
	if near_t > far_t:
		return null
	var previous := near_t
	var t := near_t
	while t <= far_t:
		var point := origin + direction * t
		var surface := maxf(map.height_at(point.x, point.z), map.WATER_LEVEL)
		if point.y <= surface:
			var left := previous
			var right := t
			for iteration in range(14):
				var middle := (left + right) * 0.5
				var probe := origin + direction * middle
				if probe.y > maxf(map.height_at(probe.x, probe.z), map.WATER_LEVEL):
					left = middle
				else:
					right = middle
			return origin + direction * right
		previous = t
		t += 1.5
	return null


func select_screen(screen: Vector2, preview := false) -> void:
	if not enabled:
		return
	var cell := cell_at_screen(screen)
	if preview and grid.valid(selected_cell) and grid.valid(cell):
		var bounds := {"min_column": 0, "max_column": 219, "min_row": 0, "max_row": 219, "blocked": []}
		Fortifications.attach(GameState.war, bounds)
		path = grid.find_path(selected_cell, cell, Fortifications.blocked_for(GameState.war, bounds, str(GameState.war.state[StateKeys.PLAYER_FACTION])))
		path_message = "路径预览：%d 格" % path.size() if not path.is_empty() else "两格之间无地面通路"
		_build_path_mesh()
	else:
		selected_cell = cell
		path.clear()
		path_message = ""
		path_mesh.mesh = null
		for material in materials:
			material.set_shader_parameter("hex_selected", _shader_cell(cell))
	_refresh_panel()
	cell_selected.emit(cell, preview)


func clear_selection() -> void:
	selected_cell = -1
	path.clear()
	path_message = ""
	if path_mesh != null:
		path_mesh.mesh = null
	for material in materials:
		material.set_shader_parameter("hex_selected", Vector2(-1,-1))
	_refresh_panel()


func toggle() -> void:
	enabled = not enabled
	for material in materials:
		material.set_shader_parameter("hex_grid_enabled", enabled)
	path_mesh.visible = enabled
	panel.visible = false


func _build_path_mesh() -> void:
	if path.size() < 2:
		path_mesh.mesh = null
		return
	var vertices := PackedVector3Array()
	for index in range(1, path.size()):
		var a: Vector2 = grid.center(path[index-1])
		var b: Vector2 = grid.center(path[index])
		for segment in range(8):
			for fraction in [float(segment)/8, float(segment+1)/8]:
				var point := a.lerp(b, fraction)
				vertices.append(Vector3(point.x, maxf(map.height_at(point.x,point.y), map.WATER_LEVEL) + 0.16, point.y))
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color("ffd064")
	mesh.surface_set_material(0, material)
	path_mesh.mesh = mesh


func _refresh_panel() -> void:
	if label == null:
		return
	var cell := hovered_cell if hovered_cell >= 0 else selected_cell
	var hint := "点击选格  Shift 点击预览路径  G 格线"
	if not grid.valid(cell):
		label.text = "三维六角格  48,400 格\n" + hint
		return
	var info: Dictionary = grid.info(cell)
	var bounds := {"min_column": 0, "max_column": 219, "min_row": 0, "max_row": 219, "blocked": []}
	Fortifications.attach(GameState.war, bounds)
	info["walkable"] = info["walkable"] and not Fortifications.blocked_for(GameState.war, bounds, str(GameState.war.state[StateKeys.PLAYER_FACTION])).has(cell)
	var city_id: String = grid.controller(cell)
	var city_name := "未归属城市"
	for city in map.city_data:
		if str(city["id"]) == city_id:
			city_name = str(city["name"])
	var owner := str(GameState.city_state(city_id).get("faction", ""))
	var faction := str(GameState.scenario.get("factions", {}).get(owner, {}).get("name", "无主"))
	label.text = "格 %d  列 %d / 行 %d\n地形 %d  区域 %d  %s\n%s  %s\n%s" % [cell,info["column"],info["row"],info["terrain"],info["region"],"可通行" if info["walkable"] else "不可通行",city_name,faction,path_message if not path_message.is_empty() else hint]
