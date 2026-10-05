extends SceneTree


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	change_scene_to_file("res://scenes/rtk14_world_3d.tscn")
	await process_frame
	while current_scene == null:
		await process_frame
	var map = current_scene
	while not map.loaded:
		await create_timer(0.1).timeout
	var center: Vector3 = map.city_nodes["luoyang"].position + Vector3(65,0,45)
	center.y = map.height_at(center.x,center.z)
	map.camera_target = center
	map.target_goal = center
	map.distance = 140
	map.distance_goal = 140
	map.pitch = deg_to_rad(57)
	map.yaw = 0.25
	map._update_camera()
	map.hex_world.set_process(false)
	var screen: Vector2 = map.camera.unproject_position(center)
	map.hex_world.select_screen(screen)
	assert(map.hex_world.selected_cell >= 0)
	var selected: int = map.hex_world.selected_cell
	assert(map.hex_world.grid.pick(Vector2(center.x,center.z)) == selected)
	map.hex_world._set_hover(map.hex_world.grid.neighbors(selected)[0])
	assert(map.hex_world.materials.size() > 0)
	print("RTK14_HEX_3D_SCENE_OK selected=",selected," materials=",map.hex_world.materials.size())
	await create_timer(2.0).timeout
	await RenderingServer.frame_post_draw
	assert(root.get_texture().get_image().save_png("res://tests/rtk14-hex-3d.png") == OK)
	print("RTK14_HEX_3D_CAPTURE_OK")
	quit()
