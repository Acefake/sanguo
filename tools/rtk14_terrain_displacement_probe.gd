extends SceneTree

func _initialize() -> void:
	call_deferred("capture")

func capture() -> void:
	var world = load("res://scenes/rtk14_world_3d.tscn").instantiate()
	root.add_child(world)
	while not world.loaded:
		await process_frame
	var delta_file := FileAccess.open("res://docs/validation/native-tessellation-probe-delta.r32", FileAccess.READ)
	if delta_file == null or delta_file.get_length() != 2049 * 2049 * 4:
		push_error("Tessellation probe delta is missing or has an invalid size")
		quit(1)
		return
	var delta := delta_file.get_buffer(delta_file.get_length()).to_float32_array()
	var total := 0.0
	var peak := 0.0
	for index in range(world.heights.size()):
		world.heights[index] += delta[index]
		total += absf(delta[index])
		peak = maxf(peak, absf(delta[index]))
	world.terrain_root.visible = false
	world._build_terrain()
	world.focus_city("hanzhong", true)
	world._clear_selection()
	world.distance = 260.0
	world.distance_goal = 260.0
	world.pitch = deg_to_rad(58)
	world._set_map_quality(1)
	world._update_camera()
	if world.army_world != null:
		world.army_world.visible = false
	for layer in world.find_children("*", "CanvasLayer", true, false):
		layer.visible = false
	for frame in range(90):
		await process_frame
	await RenderingServer.frame_post_draw
	var path := "res://docs/validation/native-tessellation-probe.png"
	var error := root.get_texture().get_image().save_png(path)
	print("NATIVE_TESSELLATION_PROBE_CAPTURE_OK peak=", peak, " mean_abs=", total / world.heights.size())
	quit(error)
