extends SceneTree

var sandbox: Node
var interior: CanvasLayer


func _initialize() -> void:
	call_deferred("_capture")


func _capture() -> void:
	sandbox = load("res://scripts/game_state.gd").new()
	sandbox.persist_enabled = false
	sandbox._load_demo()
	interior = load("res://scenes/city_interior.tscn").instantiate()
	interior.store = sandbox
	root.add_child(interior)
	interior.open_city("xuchang", "许昌", "豫州")
	await _save("res://assets/city/han/building-icons-preview.png")
	interior._select_building("market")
	await _save("res://assets/city/han/market-click-preview.png")
	Input.warp_mouse(interior.action_list.get_child(4).get_child(0).global_position + Vector2(80, 12))
	await _save("res://assets/city/han/market-hover-preview.png")
	interior.action_list.get_child(4).get_child(0).mouse_exited.emit()
	interior._select_building("workshop")
	await _save("res://assets/city/han/game-preview.png")
	interior._enter_government()
	interior._hide_menu()
	await _save("res://assets/city/han/council-overview.png")
	interior._choose_council_category("civil")
	await _save("res://assets/city/han/council-preview.png")
	interior._prepare_action("recruit")
	await _save("res://assets/city/han/action-preview.png")
	interior._cancel_action()
	sandbox.action_points = 0
	interior._choose_council_category("military")
	interior._refresh()
	await _save("res://assets/city/han/disabled-preview.png")
	interior._show_report("city")
	await _save("res://assets/city/han/city-report-preview.png")
	interior.queue_free()
	sandbox.free()
	await process_frame
	quit(0)


func _save(path: String) -> void:
	await process_frame
	await process_frame
	await create_timer(0.15).timeout
	await RenderingServer.frame_post_draw
	var error := root.get_texture().get_image().save_png(path)
	if error != OK:
		push_error("无法保存截图：" + path)
		quit(error)
