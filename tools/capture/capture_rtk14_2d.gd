extends SceneTree


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	change_scene_to_file("res://scenes/map_slice.tscn")
	await process_frame
	await process_frame
	var map = current_scene
	assert(map.places.size() == 46, "RTK14 city count")
	assert(map.map_size == Vector2(2048, 2048), "Shared world extent")
	var cities: Array = JSON.parse_string(FileAccess.get_file_as_string("res://assets/rtk14/cities_map.json"))
	for city in cities:
		assert(map._place_position(city["id"]).is_equal_approx(Vector2(city["x"], city["z"])), "City registration")
	map._select_at(map._place_position("luoyang"))
	assert(map.selected_id == "luoyang", "City selection")
	assert(map.detail_panel.visible, "City details")
	map._clear_selection()
	map._reset_view()
	var fit: float = map.camera.zoom.x
	map._zoom_at(root.size * 0.5, 1.14)
	assert(is_equal_approx(map.camera.zoom.x, fit * 1.14), "Overview zoom must not jump to legacy minimum")
	map._reset_view()
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("res://tests/rtk14-2d-overview.png")
	print("RTK14_2D_OK cities=46 selection=ok coordinates=ok zoom=ok")
	quit()
