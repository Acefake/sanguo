extends "res://scripts/world/rtk14_world_3d/frame.gd"
## 3D 大地图场景（scenes/rtk14_world_3d.tscn 的根节点）。
##
## 本文件只留节点生命周期与协调：_ready 按顺序调用各构建步骤、挂上军队与六角格表现层、处理启动参数，
## 以及状态栏刷新和截图预览。实现分在 rtk14_world_3d/ 下四层（state → input → builder → frame），
## 本脚本继承最上层，rtk14_reference.gd 等子类的覆写与 super 调用不受影响。

func _ready() -> void:
	_build_environment()
	_set_map_quality(0)
	_build_camera()
	_build_ui()
	status.text = "正在读取地形与模型…"
	await get_tree().process_frame
	var terrain_path := "world_preview_height.r32" if FileAccess.file_exists(ASSET_DIR + "world_preview_height.r32") else "heightmap.r32"
	var file := FileAccess.open(ASSET_DIR + terrain_path, FileAccess.READ)
	if file == null:
		status.text = "地图高度文件缺失"
		push_error("Cannot open original heightmap")
		return
	heights = file.get_buffer(file.get_length()).to_float32_array()
	var source_file := FileAccess.open(ASSET_DIR + "heightmap.r32", FileAccess.READ)
	source_heights = source_file.get_buffer(source_file.get_length()).to_float32_array()
	var grid_file := FileAccess.open(ASSET_DIR + "map_grid.bin", FileAccess.READ)
	if grid_file != null:
		grid_file.get_32()
		map_cells = grid_file.get_buffer(grid_file.get_length() - 4).to_int32_array()
	if heights.size() != HEIGHT_SIZE * HEIGHT_SIZE:
		push_error("Invalid heightmap dimensions")
		return
	model_library = _read_json(ASSET_DIR + "models.json", {})
	city_data = _read_json(ASSET_DIR + "cities_map.json", [])
	grid_transform = _read_json(ASSET_DIR + "grid_transform.json", {})["parameters"]
	_prepare_city_sites()
	_build_gates()
	_build_terrain()
	_build_water()
	_build_landscape()
	_build_cities()
	_build_campaign_city_markers()
	_build_world_districts()
	await _build_vegetation()
	_build_selection_ring()
	hex_world = preload("res://scripts/world/rtk14_hex_world_3d.gd").new()
	hex_world.map = self
	add_child(hex_world)
	loaded = true
	army_world = preload("res://scripts/war/presentation/army_world_3d.gd").new()
	army_world.map = self
	add_child(army_world)
	_refresh_status()
	focus_city("luoyang", true)
	_clear_selection()
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--capture="):
			screenshot_path = argument.trim_prefix("--capture=")
		if argument == "--overview":
			_show_overview(true)
		if argument == "--city-closeup":
			focus_city("luoyang", true)
			distance = 85.0
			distance_goal = distance
			pitch = deg_to_rad(46)
			_update_camera()
		if argument == "--forest-closeup":
			_focus_forest(true)
		if argument.begins_with("--region="):
			focus_city(argument.trim_prefix("--region="), true)
			_clear_selection()
		if argument.begins_with("--gate="):
			focus_gate(argument.trim_prefix("--gate="), true)
		if argument.begins_with("--distance="):
			distance = clampf(float(argument.trim_prefix("--distance=")), 38.0, 3000.0)
			distance_goal = distance
			_update_camera()
		if argument.begins_with("--pitch="):
			pitch = deg_to_rad(clampf(float(argument.trim_prefix("--pitch=")), 25.0, 78.0))
			_update_camera()
		if argument == "--quality=fine":
			_set_map_quality(1)
		if argument == "--photo":
			for child in find_children("*", "CanvasLayer", true, false):
				child.visible = false
	if not screenshot_path.is_empty():
		_capture_preview()

func _refresh_status() -> void:
	status.text = "城池 %d 座  树木 %d 株  地被 %d 处  原始全图地形与植被分布" % [city_nodes.size(), vegetation_count, ground_cover_count]

func _capture_preview() -> void:
	await get_tree().create_timer(2.0).timeout
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var error := image.save_png(screenshot_path)
	if error != OK:
		push_error("Screenshot failed: " + str(error))
	else:
		# This snapshot follows loading and shader compilation; steady frame rates
		# are measured separately by tools/validate/rtk14_performance_check.gd.
		print("WORLD3D_CAPTURE_OK ", screenshot_path)
	get_tree().quit()
