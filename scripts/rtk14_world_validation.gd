extends SceneTree
func _initialize() -> void:
	call_deferred("validate")
func validate() -> void:
	var world = load("res://scenes/rtk14_world_3d.tscn").instantiate()
	root.add_child(world)
	while not world.loaded:
		await process_frame
	assert(world.heights.size() == 2049 * 2049)
	assert(world.chunk_count == 64)
	assert(world.static_source_count == 1120)
	var source_visibility: Dictionary = world.landscape_root.get_meta("source_visibility")
	assert(source_visibility["stage_object"] == "6eff205a")
	assert(source_visibility["visibility_object"] == "63f9f0ba")
	assert(source_visibility["visible_instances"].size() == 105)
	assert(world.static_instance_count == 105)
	# All 1120 source records remain intact; the current stage lists 105 houses.
	assert(world.static_filtered_count == 0)
	assert(world.city_nodes.size() == 46)
	assert(world.has_node("FullMapRiversAndLakes"))
	var village_count := 0
	var source_covered: Dictionary = {}
	for entry in world._read_json(world.ASSET_DIR + "world_layout.json", []):
		if entry["kind"] == "village":
			village_count += 1
			source_covered[entry["city"]] = true
	assert(world.get_node("AllCityHinterlands").get_child_count() == village_count)
	var covered: Dictionary = {}
	for detail in world.get_node("AllCityHinterlands").get_children():
		covered[detail.get_meta("city_id")] = true
	assert(covered.size() == source_covered.size())
	assert(world.gate_nodes.size() == 10)
	var base_file := FileAccess.open(world.ASSET_DIR + "world_preview_height.r32", FileAccess.READ)
	var base_height := base_file.get_buffer(base_file.get_length()).to_float32_array()
	assert(base_height == world.source_heights)
	assert(world.landscape_ground_adjusted_count == 0)
	for gate in world.gate_nodes.values():
		var wall_bounds: AABB = gate.get_meta("model_bounds")
		assert(absf(wall_bounds.size.x - float(gate.get_meta("source_footprint_width"))) < 0.01)
		assert(gate.get_meta("foundation_mode") == "rotated_wall_footprint_fill_only")
		# Regression: the old 40m circular foundation excavated the mountain.
		# Check the whole former excavation area against the saved terrain.
		var inverse_basis: Basis = gate.basis.inverse()
		for z in range(int(gate.position.z) - 22, int(gate.position.z) + 23):
			for x in range(int(gate.position.x) - 22, int(gate.position.x) + 23):
				var point := Vector2(x, z)
				var near_city := false
				for city in world.city_data:
					if point.distance_to(Vector2(city["x"], city["z"])) < 32:
						near_city = true
				if near_city:
					continue
				var index: int = z * world.HEIGHT_SIZE + x
				assert(world.heights[index] >= base_height[index] - 0.001)
				var local := inverse_basis * Vector3(x - gate.position.x, 0, z - gate.position.z)
				var outside := maxf(maxf(wall_bounds.position.x - local.x, local.x - wall_bounds.end.x),
					maxf(wall_bounds.position.z - local.z, local.z - wall_bounds.end.z))
				if outside > 3.01:
					assert(absf(world.heights[index] - base_height[index]) < 0.001)
		assert(gate.get_meta("source_cells").size() >= 3)
		var expected_gate := Vector2.ZERO
		for cell_id in gate.get_meta("source_cells"):
			var column := int(cell_id) % 220
			var row := int(cell_id) / 220
			expected_gate += Vector2(float(world.grid_transform[2]) + column * float(world.grid_transform[0]),
				float(world.grid_transform[3]) + (row + (column % 2) * 0.5) * float(world.grid_transform[1]))
		expected_gate /= gate.get_meta("source_cells").size()
		assert(expected_gate.distance_to(Vector2(gate.position.x, gate.position.z)) < 0.001)
	var terrain_material: ShaderMaterial = world.terrain_root.get_child(0).material_override
	var native_color: Texture2D = terrain_material.get_shader_parameter("world_albedo")
	var native_normal: Texture2D = terrain_material.get_shader_parameter("world_normal_texture")
	assert(native_color.get_size() == Vector2(4096, 4096))
	assert(native_normal.get_size() == Vector2(4096, 4096))
	assert(native_color.resource_path.ends_with("terrain/source_albedo.png"))
	assert(native_normal.resource_path.ends_with("terrain/source_normal.png"))
	for role in ["terrain_albedo", "terrain_normal", "terrain_parameters"]:
		var array: Texture2DArray = terrain_material.get_shader_parameter(role)
		assert(array.get_layers() == 19 and array.has_mipmaps())
		assert(array.get_format() == Image.FORMAT_DXT5)
		assert(array.get_width() == 1024 and array.get_height() == 1024)
	var control: Texture2D = terrain_material.get_shader_parameter("land_control")
	assert(control.get_size() == Vector2(2049, 2049))
	assert(control.get_image().get_format() == Image.FORMAT_RGBA8)
	var palette: PackedVector4Array = terrain_material.get_shader_parameter("palette")
	assert(palette.size() == 18)
	assert(palette[6] == Vector4(8, 20, 20, 0.7))
	assert(palette[17] == Vector4(7, 60, 60, 0))
	assert(terrain_material.get_shader_parameter("near_far_blending") == Vector2(600, 750))
	var planting: Dictionary = world._read_json(world.ASSET_DIR + "autumn_vegetation.json", {})
	assert(world.vegetation_count > int(planting["trees"]) * 0.98)
	assert(world.vegetation_count <= int(planting["trees"]))
	assert(world.ground_cover_count > int(planting["ground_cover"]) * 0.98)
	assert(world.ground_cover_count <= int(planting["ground_cover"]))
	assert(world.map_environment.ssao_enabled and not world.map_environment.ssil_enabled)
	for batch in world.landscape_root.get_children():
		var render_mesh: Mesh = batch.multimesh.mesh
		var source_mesh: Mesh = world._model_meshes(batch.name)[0]["mesh"]
		if render_mesh.surface_get_material(0) is ShaderMaterial:
			assert(render_mesh.get_surface_count() == source_mesh.get_surface_count())
			for surface in range(render_mesh.get_surface_count()):
				assert(render_mesh.surface_get_arrays(surface)[Mesh.ARRAY_VERTEX] == source_mesh.surface_get_arrays(surface)[Mesh.ARRAY_VERTEX])
				assert(render_mesh.surface_get_arrays(surface)[Mesh.ARRAY_INDEX] == source_mesh.surface_get_arrays(surface)[Mesh.ARRAY_INDEX])
				var stone := render_mesh.surface_get_material(surface) as ShaderMaterial
				assert(stone.get_shader_parameter("source_albedo") == source_mesh.surface_get_material(surface).albedo_texture)
				assert(stone.get_shader_parameter("has_parameters"))
				assert(stone.get_shader_parameter("source_parameters") != null)
				var arrays: Array = render_mesh.surface_get_arrays(surface)
				assert(not arrays[Mesh.ARRAY_TANGENT].is_empty())
				assert(arrays[Mesh.ARRAY_COLOR].size() == arrays[Mesh.ARRAY_VERTEX].size())
				for color: Color in arrays[Mesh.ARRAY_COLOR]:
					assert(color.a == 0.0 or color.a == 1.0)
		for pose: Transform3D in batch.get_meta("source_poses"):
			assert(absf(pose.basis.x.normalized().dot(pose.basis.y.normalized())) < 0.0001)
			assert(absf(pose.basis.x.normalized().dot(pose.basis.z.normalized())) < 0.0001)
	var decoded_layers: Dictionary = {}
	var expected_layer_count := 0
	for mesh: ArrayMesh in world.foliage_mesh_library.values():
		assert(mesh.get_surface_count() == 1)
		var arrays := mesh.surface_get_arrays(0)
		assert(arrays[Mesh.ARRAY_VERTEX].size() == mesh.get_meta("source_vertex_count"))
		assert(arrays[Mesh.ARRAY_INDEX].size() == mesh.get_meta("source_index_count"))
		var material := mesh.surface_get_material(0) as ShaderMaterial
		var layer_count: float = material.get_shader_parameter("layer_count")
		expected_layer_count = maxi(expected_layer_count, int(layer_count))
		for coordinate: Vector2 in arrays[Mesh.ARRAY_TEX_UV2]:
			assert(coordinate.x >= 0.0 and coordinate.x <= 1.0)
			decoded_layers[int(round(coordinate.x * (layer_count - 1)))] = true
	assert(decoded_layers.size() == expected_layer_count)
	world._set_map_quality(1)
	assert(world.map_environment.ssil_enabled and world.get_viewport().scaling_3d_scale == 1.0)
	world._set_map_quality(0)
	for city in world.city_data:
		var expected := Vector2.ZERO
		for cell_id in city["cells"]:
			var column := int(cell_id) % 220
			var row := int(cell_id) / 220
			expected += Vector2(float(world.grid_transform[2]) + column * float(world.grid_transform[0]),
				float(world.grid_transform[3]) + (row + (column % 2) * 0.5) * float(world.grid_transform[1]))
		expected /= city["cells"].size()
		assert(expected.distance_to(Vector2(city["x"], city["z"])) < 0.001)
		var node = world.city_nodes[city["id"]]
		assert(is_equal_approx(node.position.x, float(city["x"])))
		assert(is_equal_approx(node.position.z, float(city["z"])))
		assert(node.get_child(0).scale == Vector3.ONE)
		assert(city["cells"].size() == 7)
	var original_mesh = world._model_meshes("cb1338e2")[0]["mesh"]
	assert(original_mesh.surface_get_material(0).albedo_texture != null)
	assert(not original_mesh.surface_get_arrays(0)[Mesh.ARRAY_TEX_UV].is_empty())
	assert(world.vegetation_count > 1000)
	assert(world.ground_cover_count > 1000)
	assert(world.vegetation_batches.size() > 100)
	assert(world.overview_vegetation_batches.size() == planting["model_ids"].size())
	var overview_count := 0
	for batch in world.overview_vegetation_batches:
		overview_count += batch.multimesh.instance_count
	assert(overview_count == world.vegetation_count + world.ground_cover_count)
	assert(original_mesh.surface_get_material(0).normal_texture != null)
	var city_selector := world.find_child("CitySelector", true, false) as OptionButton
	assert(city_selector != null and city_selector.item_count == 47)
	world.focus_city("luoyang", true)
	assert(world.selected_city == "luoyang")
	assert(world.selected_ring.visible)
	# 城池标记随城池建立；点选城池弹出指令层。
	assert(world.city_badges.size() == world.city_nodes.size())
	assert(world.city_popup.visible and world.city_badges["luoyang"].city_name == "洛阳")
	await process_frame
	assert(world.city_badges["luoyang"].visible == world.labels_enabled)
	var labels_before: bool = world.labels_enabled
	world._toggle_labels()
	assert(world.labels_enabled != labels_before)
	assert(world.labels_button.text == ("城名：开" if world.labels_enabled else "城名：关"))
	await process_frame
	if not world.labels_enabled:
		for badge in world.city_badges.values():
			assert(not badge.visible)
	world._toggle_labels()
	assert(world.labels_enabled == labels_before)
	world._clear_selection()
	assert(not world.city_popup.visible && world.city_popup != null)
	world._toggle_vegetation()
	assert(not world.vegetation_root.visible)
	world._toggle_vegetation()
	world._toggle_cities()
	assert(not world.cities_root.visible and world.selected_city.is_empty())
	world._toggle_cities()
	var wheel := InputEventMouseButton.new()
	wheel.button_index = MOUSE_BUTTON_WHEEL_UP
	wheel.pressed = true
	for i in range(100): world._unhandled_input(wheel)
	assert(world.distance_goal == 38.0)
	wheel.button_index = MOUSE_BUTTON_WHEEL_DOWN
	for i in range(100): world._unhandled_input(wheel)
	assert(world.distance_goal == 3000.0)
	world._show_overview(true)
	assert(world.camera_target.x == 1024)
	assert(world.map_environment.fog_density < 0.00003)
	world._focus_forest(true)
	assert(world.selected_city.is_empty() and world.distance_goal == 38.0)
	world._update_vegetation_lod()
	assert(world.map_sun.directional_shadow_max_distance >= world.distance * 1.25)
	for batch in world.vegetation_batches:
		assert(batch.multimesh.visible_instance_count == -1)
	world.distance_goal = 3000.0
	world.distance = 3000.0
	world._update_camera()
	world._update_vegetation_lod()
	assert(world.vegetation_overview_root.visible)
	for batch in world.vegetation_batches:
		assert(batch.multimesh.visible_instance_count == -1)
		assert(not batch.visible)
	world.focus_gate("gate_131", true)
	world._update_vegetation_lod()
	assert(not world.vegetation_overview_root.visible)
	assert(world.distance_goal == 65.0)
	print("WORLD3D_VALIDATION_OK chunks=", world.chunk_count, " source_placements=", world.static_source_count, " visible_placements=", world.static_instance_count, " city_rocks_filtered=", world.static_filtered_count, " cities=", world.city_nodes.size(), " trees=", world.vegetation_count, " ground_cover=", world.ground_cover_count)
	quit()
