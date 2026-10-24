extends SceneTree

func _initialize() -> void:
	call_deferred("validate")

func validate() -> void:
	var scene = load("res://scenes/rtk14_reference.tscn").instantiate()
	root.add_child(scene)
	while not scene.loaded:
		await process_frame
	assert(scene.city_nodes.size() == 1)
	assert(scene.hero_model.get_child_count() == 5)
	var source_mesh: Mesh = scene._model_meshes("85fe8b84")[0]["mesh"]
	assert(source_mesh.get_surface_count() == 14)
	assert(source_mesh.surface_get_arrays(0)[Mesh.ARRAY_INDEX].size() == 6)
	assert(scene.vegetation_count > 1500)
	assert(scene.ground_cover_count > 1500)
	assert(scene.farm_count == 3 and scene.settlement_count == 4)
	for batch in scene.vegetation_batches:
		if bool(batch.get_meta("ground_cover", false)):
			continue
		var centres: PackedVector3Array = batch.get_meta("placement_centres")
		assert(centres.size() == batch.multimesh.instance_count)
		for point in centres:
			assert(scene._mask_at(point.x, point.z).r <= 0.17)
			assert(scene.height_at(point.x, point.z) > scene.WATER_LEVEL)
	var wheel := InputEventMouseButton.new()
	wheel.button_index = MOUSE_BUTTON_WHEEL_UP
	wheel.pressed = true
	for i in range(100): scene._unhandled_input(wheel)
	assert(scene.distance_goal == 38)
	wheel.button_index = MOUSE_BUTTON_WHEEL_DOWN
	for i in range(100): scene._unhandled_input(wheel)
	assert(scene.distance_goal == 200)
	var key := InputEventKey.new()
	key.pressed = true
	key.keycode = KEY_TAB
	scene._unhandled_input(key)
	assert(not scene.photo_ui.visible)
	scene._unhandled_input(key)
	assert(scene.photo_ui.visible)
	key.keycode = KEY_R
	scene._unhandled_input(key)
	assert(scene.distance_goal == 85 and scene.target_goal.x == 65)
	scene.focus_city("reference", true)
	assert(scene.distance_goal == 42)
	scene._reset_reference(true)
	print("REFERENCE_SCENE_VALIDATION_OK trees=",scene.vegetation_count," ground_cover=",scene.ground_cover_count," city_surfaces=",source_mesh.get_surface_count())
	quit()
