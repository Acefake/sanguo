extends SceneTree

func _initialize() -> void:
	call_deferred("capture")

func capture() -> void:
	var world = load("res://scenes/rtk14_world_3d.tscn").instantiate()
	root.add_child(world)
	while not world.loaded:
		await process_frame
	world.focus_city("hanzhong", true)
	world._clear_selection()
	world.distance = 260.0
	world.distance_goal = 260.0
	world.pitch = deg_to_rad(58)
	world._set_map_quality(1)
	world._update_camera()
	for child in world.find_children("*", "CanvasLayer", true, false):
		child.visible = false
	if "--linear" in OS.get_cmdline_user_args():
		var material: ShaderMaterial = world.terrain_root.get_child(0).material_override
		material.shader = load("res://shaders/rtk14_terrain_linear_probe.gdshader")
	for frame in range(90):
		await process_frame
	await RenderingServer.frame_post_draw
	var name := "linear" if "--linear" in OS.get_cmdline_user_args() else "srgb"
	var path := "res://docs/validation/terrain-color-%s.png" % name
	var error := root.get_texture().get_image().save_png(path)
	if error != OK:
		push_error("Terrain color probe capture failed")
	print("TERRAIN_COLOR_PROBE_OK ", name)
	quit(error)
