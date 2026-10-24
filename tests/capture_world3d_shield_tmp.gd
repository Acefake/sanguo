extends SceneTree


func _initialize() -> void:
	call_deferred("_cap")


func _cap() -> void:
	var world = load("res://scenes/rtk14_world_3d.tscn").instantiate()
	root.add_child(world)
	while not world.loaded:
		await process_frame
	# 全图：盾形旗帜与城名
	world._show_overview(true)
	await _wait(0.6)
	await _save("res://assets/rtk14/world3d-shields-preview.png")
	# 点选城池：弹出层
	world.focus_city("luoyang", true)
	await _wait(0.8)
	await _save("res://assets/rtk14/world3d-popup-preview.png")
	world.queue_free()
	await process_frame
	quit(0)


func _wait(seconds: float) -> void:
	var frames := maxi(int(seconds * 60.0), 2)
	for i in range(frames):
		await process_frame


func _save(path: String) -> void:
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	var error := root.get_texture().get_image().save_png(path)
	if error != OK:
		push_error("save failed: " + path)
		quit(1)
