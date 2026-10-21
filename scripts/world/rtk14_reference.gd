extends "res://scripts/world/rtk14_world_3d.gd"

const DETAILS = preload("res://scripts/world/rtk14_details.gd")
const LOCAL_MIN := -70.0
const LOCAL_SIZE := 260.0
const CITY_POINT := Vector2(70, 56)
var photo_ui: CanvasLayer
var local_splat: Image
var hero_model: Node3D
var farm_count := 0
var settlement_count := 0

func _build_environment() -> void:
	super._build_environment()
	for child in get_children():
		if child is WorldEnvironment:
			child.environment.ssao_enabled = true
			child.environment.ssao_radius = 1.1
			child.environment.ssao_intensity = 1.25
			child.environment.ssil_enabled = true
			child.environment.ssil_radius = 3.0
			child.environment.ssil_intensity = 0.30
		if child is DirectionalLight3D:
			child.directional_shadow_max_distance = 180

func _ready() -> void:
	_build_environment()
	_build_camera()
	_build_reference_ui()
	model_library = _read_json(ASSET_DIR + "models.json", {})
	local_splat = (load(ASSET_DIR + "reference_splat.png") as Texture2D).get_image()
	_build_local_terrain()
	_build_local_water()
	_build_reference_city()
	_build_reference_settlements()
	_build_reference_farms()
	_build_reference_forest()
	loaded = true
	_reset_reference(true)
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--capture="):
			screenshot_path = argument.trim_prefix("--capture=")
		if argument == "--photo":
			photo_ui.visible = false
	if not screenshot_path.is_empty():
		_capture_preview()

func height_at(x: float, z: float) -> float:
	var shore := 24.0 + 2.1 * sin(x * 0.055) + 1.2 * sin(x * 0.16)
	var river_distance := maxf(shore - 36.0 - z, z - shore - 8.0)
	var h := 6.4 + sin(x * 0.066) * 0.7 + sin(z * 0.081 + x * 0.018) * 0.65
	h += sin(x * 0.15 + z * 0.11) * 0.13
	h = lerpf(-2.0, h, smoothstep(0.0, 7.0, river_distance))
	var cliff_x := 120.0 - maxf(z - 65.0, 0.0) * 0.24 + 2.0 * sin(z * 0.17)
	if z > 57.0:
		h = lerpf(h, -3.8, smoothstep(cliff_x - 4.0, cliff_x + 2.0, x) * smoothstep(57.0, 65.0, z))
	var city_distance := maxf(absf(x - CITY_POINT.x) - 14.5, absf(z - CITY_POINT.y) - 10.5)
	h = lerpf(7.0, h, smoothstep(0, 5.0, city_distance))
	return h

func _build_local_terrain() -> void:
	terrain_root = Node3D.new()
	terrain_root.name = "ReferencePlateauAndRiverBanks"
	add_child(terrain_root)
	# 地形材质改用共享的原生贴图版本；局部场景按世界 1:1 比例取样左缘区域。
	var material := _terrain_material(Vector4(LOCAL_MIN, LOCAL_MIN, WORLD_SIZE, WORLD_SIZE))
	var side := 261
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	for row in range(side):
		for col in range(side):
			var x := LOCAL_MIN + col
			var z := LOCAL_MIN + row
			vertices.append(Vector3(x, height_at(x, z), z))
			normals.append(_normal_at(x, z))
			uvs.append(Vector2(x, z) / 11.0)
	for row in range(side - 1):
		for col in range(side - 1):
			var a := row * side + col
			indices.append_array(PackedInt32Array([a, a + 1, a + side, a + 1, a + side + 1, a + side]))
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.material_override = material
	terrain_root.add_child(node)
	chunk_count = 1

func _build_local_water() -> void:
	var node := MeshInstance3D.new()
	node.name = "MuddyRiverAndCoastalWater"
	var plane := PlaneMesh.new()
	plane.size = Vector2(LOCAL_SIZE + 100, LOCAL_SIZE + 100)
	node.mesh = plane
	node.position = Vector3(60, WATER_LEVEL, 60)
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/rtk14_water.gdshader")
	mat.set_shader_parameter("shore_texture", load(ASSET_DIR + "reference_shore.png"))
	mat.set_shader_parameter("has_shore", true)
	node.material_override = mat
	add_child(node)

func _place_model(id: String, point: Vector2, size := 1.0, angle := 0.0) -> Node3D:
	var holder := Node3D.new()
	holder.position = Vector3(point.x, height_at(point.x, point.y), point.y)
	holder.rotation.y = angle
	holder.scale = Vector3.ONE * size
	add_child(holder)
	var packed: PackedScene = load(str(model_library[id]["path"]))
	holder.add_child(packed.instantiate())
	return holder

func _build_reference_city() -> void:
	cities_root = Node3D.new()
	cities_root.name = "CompleteSquareCity"
	add_child(cities_root)
	hero_model = _place_model("85fe8b84", CITY_POINT, 1.15)
	hero_model.reparent(cities_root)
	hero_model.position.y = 7.47
	DETAILS.add_city_banners(hero_model)
	city_nodes["reference"] = hero_model
	city_pick_positions["reference"] = hero_model.position + Vector3(0, 2, 0)

func _build_reference_settlements() -> void:
	for point in [Vector2(50, 41), Vector2(10, 46), Vector2(129, 48)]:
		var node := _place_model("5816f8ce", point, 0.8)
		node.position.y += 0.10
		DETAILS.add_banner(node, Vector3(1.6, 1.2, 0), 1.0)
		settlement_count += 1
	var port := _place_model("571f6002", Vector2(88, 35), 0.9)
	port.position.y = 2.35
	DETAILS.add_banner(port, Vector3(0, 1.7, 0), 1.0)
	settlement_count += 1

func _build_reference_farms() -> void:
	var soil := StandardMaterial3D.new()
	soil.albedo_color = Color("746744")
	soil.albedo_texture = load(ASSET_DIR + "textures/5fa8dd9d.png")
	soil.uv1_scale = Vector3(1.5, 1.5, 1)
	var crop := StandardMaterial3D.new()
	crop.albedo_color = Color("91a563")
	var straw := StandardMaterial3D.new()
	straw.albedo_color = Color("988261")
	for origin in [Vector2(101, 69), Vector2(124, 53), Vector2(28, 34)]:
		var field := Node3D.new()
		field.name = "TerracedFarm"
		field.position = Vector3(origin.x, height_at(origin.x, origin.y) + 0.045, origin.y)
		field.rotation.y = -0.12
		add_child(field)
		var bed := MeshInstance3D.new()
		var plane := PlaneMesh.new()
		plane.size = Vector2(6, 7)
		bed.mesh = plane
		bed.material_override = soil
		field.add_child(bed)
		for row in range(8):
			var ridge := MeshInstance3D.new()
			var box := BoxMesh.new()
			box.size = Vector3(5.8, 0.13, 0.27)
			ridge.mesh = box
			ridge.position = Vector3(0, 0.07, -3 + row * 0.85)
			ridge.material_override = crop if row % 3 != 0 else straw
			field.add_child(ridge)
		farm_count += 1

func _mask_at(x: float, z: float) -> Color:
	var px := clampi(int((x - LOCAL_MIN) / LOCAL_SIZE * (local_splat.get_width() - 1)), 0, local_splat.get_width() - 1)
	var pz := clampi(int((z - LOCAL_MIN) / LOCAL_SIZE * (local_splat.get_height() - 1)), 0, local_splat.get_height() - 1)
	return local_splat.get_pixel(px, pz)

func _build_reference_forest() -> void:
	vegetation_root = Node3D.new()
	vegetation_root.name = "AutumnMixedForestAndGroundCover"
	add_child(vegetation_root)
	var tree_ids := ["c0008e34", "5d3d3f89", "6c07a9c7", "e0e163df", "c765c353"]
	var grass_ids := ["32779e6d", "5d20da2c", "4108f1af"]
	var groups: Dictionary = {}
	for id in tree_ids + grass_ids:
		groups[id] = []
	var rng := RandomNumberGenerator.new()
	rng.seed = 14142026
	for row in range(93):
		for col in range(103):
			var x := -34.0 + col * 2.05 + rng.randf_range(-0.65, 0.65)
			var z := -5.0 + row * 2.05 + rng.randf_range(-0.65, 0.65)
			var y := height_at(x, z)
			if y < WATER_LEVEL + 2.0 or _normal_at(x, z).y < 0.75:
				continue
			var mask := _mask_at(x, z)
			if mask.r > 0.17:
				continue
			var near_farm := false
			for farm in [Vector2(101, 69), Vector2(124, 53), Vector2(28, 34)]:
				if Vector2(x, z).distance_to(farm) < 6:
					near_farm = true
			if near_farm:
				continue
			var near_settlement := false
			for point in [Vector2(50, 41), Vector2(10, 46), Vector2(129, 48)]:
				if Vector2(x, z).distance_to(point) < 5.0:
					near_settlement = true
			if near_settlement:
				continue
			var patch := (sin(x * 0.20 + sin(z * 0.11)) * cos(z * 0.17) + 1.0) * 0.5
			if mask.g > rng.randf_range(0.10, 0.80) and patch > 0.10:
				var pick := rng.randf()
				var id: String = tree_ids[0] if pick < 0.48 else (tree_ids[1] if pick < 0.63 else (tree_ids[2] if pick < 0.81 else (tree_ids[3] if pick < 0.94 else tree_ids[4])))
				var size := rng.randf_range(0.29, 0.43)
				var basis := Basis(Vector3.UP, rng.randf_range(0, TAU)).scaled(Vector3.ONE * size)
				groups[id].append(Transform3D(basis, Vector3(x, y + size * 0.40, z)))
				vegetation_count += 1
			if rng.randf() < 0.09 + mask.g * 0.70:
				var id: String = grass_ids[rng.randi_range(0, 2)]
				var basis := Basis(Vector3.UP, rng.randf_range(0, TAU)).scaled(Vector3.ONE * rng.randf_range(0.25, 0.48))
				groups[id].append(Transform3D(basis, Vector3(x, y + 0.03, z)))
				ground_cover_count += 1
	for id in groups:
		_add_multimeshes(vegetation_root, id, groups[id])

func _update_vegetation_lod() -> void:
	for batch in vegetation_batches:
		batch.multimesh.visible_instance_count = -1

func _reset_reference(immediate := false) -> void:
	target_goal = Vector3(65, 7, 65)
	distance_goal = 85.0
	pitch = deg_to_rad(46)
	yaw = 0.045
	if immediate:
		camera_target = target_goal
		distance = distance_goal
		_update_camera()

func _show_overview(immediate := false) -> void:
	target_goal = Vector3(63, 6, 60)
	distance_goal = 160
	pitch = deg_to_rad(68)
	yaw = 0
	if immediate:
		camera_target = target_goal
		distance = distance_goal
		_update_camera()

func focus_city(_city_id: String, immediate := false) -> void:
	target_goal = hero_model.position
	distance_goal = 42.0
	if immediate:
		camera_target = target_goal
		distance = distance_goal
		_update_camera()

func _process(delta: float) -> void:
	target_goal.x = clampf(target_goal.x, -35, 155)
	target_goal.z = clampf(target_goal.z, 0, 160)
	distance_goal = clampf(distance_goal, 38, 200)
	super._process(delta)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_TAB:
			photo_ui.visible = not photo_ui.visible
			return
		if event.keycode in [KEY_R, KEY_HOME]:
			_reset_reference()
			return
	super._unhandled_input(event)
	distance_goal = clampf(distance_goal, 38, 200)

func _build_reference_ui() -> void:
	photo_ui = CanvasLayer.new()
	add_child(photo_ui)
	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	panel.offset_left = 18
	panel.offset_right = -18
	panel.offset_top = -52
	panel.offset_bottom = -16
	panel.add_theme_stylebox_override("panel", _panel_style())
	photo_ui.add_child(panel)
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 16)
	panel.add_child(bar)
	bar.add_child(_label("秋日城郊", 18, Color("f7eed4")))
	bar.add_child(_label("拖动平移  右键环绕  滚轮缩放  Tab 隐藏界面", 13, Color("d7dbca")))
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(spacer)
	bar.add_child(_button("参考视角  R", _reset_reference))
	bar.add_child(_button("查看城池", func() -> void: focus_city("reference")))
	bar.add_child(_button("完整大地图", func() -> void: get_tree().change_scene_to_file("res://scenes/rtk14_world_3d.tscn")))
