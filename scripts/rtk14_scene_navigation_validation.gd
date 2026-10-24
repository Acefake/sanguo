extends SceneTree
var finished := false

func _initialize() -> void:
	create_timer(90).timeout.connect(func() -> void:
		if not finished:
			push_error("Scene navigation validation timed out")
			quit(1))
	call_deferred("validate")

func wait_loaded(path: String) -> void:
	while current_scene == null or current_scene.scene_file_path != path or not current_scene.loaded:
		await process_frame

func click(text: String) -> void:
	for button in current_scene.find_children("*", "Button", true, false):
		if button.text == text:
			button.pressed.emit()
			return
	push_error("Missing navigation button: " + text)
	quit(1)

func validate() -> void:
	assert(ProjectSettings.get_setting("application/run/main_scene") == "res://scenes/map_slice.tscn")
	change_scene_to_file("res://scenes/rtk14_reference.tscn")
	await wait_loaded("res://scenes/rtk14_reference.tscn")
	click("完整大地图")
	await wait_loaded("res://scenes/rtk14_world_3d.tscn")
	assert(current_scene.city_nodes.size() == 46)
	change_scene_to_file("res://scenes/rtk14_reference.tscn")
	await wait_loaded("res://scenes/rtk14_reference.tscn")
	assert(current_scene.hero_model != null)
	finished = true
	print("REFERENCE_WORLD_NAVIGATION_OK")
	quit()
