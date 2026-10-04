extends SceneTree

var map: Node2D


func _initialize() -> void:
	call_deferred("_capture")


func _capture() -> void:
	var state := root.get_node("GameState")
	state.persist_enabled = false
	state._load_demo()
	map = load("res://scenes/map_slice.tscn").instantiate()
	root.add_child(map)
	await _save("res://assets/map/world-preview.png")
	map._toggle_map_mode()
	await _save("res://assets/map/world-terrain-preview.png")
	map._toggle_map_mode()
	map._toggle_neutral_style()
	await _save("res://assets/map/neutral-white-preview.png")
	map._toggle_neutral_style()
	map.selected_id = "beihai"
	map._update_route()
	map._refresh_ui()
	await _save("res://assets/map/world-detail-preview.png")
	map._clear_selection()
	map.camera.zoom = Vector2.ONE * 1.12
	map.camera.position = Vector2(1110, 515)
	map._clamp_camera()
	await _save("res://assets/map/world-zoom-preview.png")
	map.selected_id = "xiangyang"
	map.camera.zoom = Vector2.ONE * 1.65
	map.camera.position = map._place_position("xiangyang") + Vector2(0, -40)
	map._clamp_camera()
	map.queue_redraw()
	await _save("res://assets/map/world-selection-preview.png")
	map.queue_free()
	await process_frame
	quit(0)


func _save(path: String) -> void:
	await process_frame
	await process_frame
	await create_timer(0.15).timeout
	await RenderingServer.frame_post_draw
	var error := root.get_texture().get_image().save_png(path)
	if error != OK:
		push_error("无法保存地图截图：" + path)
		quit(error)
