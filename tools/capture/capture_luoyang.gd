extends SceneTree

func _initialize() -> void:
	call_deferred("capture")

func capture() -> void:
	root.size = Vector2i(2560, 1440)
	var scene := Node3D.new()
	scene.set_script(load("res://scripts/city/luoyang_scene.gd"))
	root.add_child(scene)
	await create_timer(3.0).timeout
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://assets/city/luoyang/preview-perspective.png")
	if "--angles" in OS.get_cmdline_user_args():
		for view in [Vector3(9, 18, 0), Vector3(9, 24, 0), Vector3(0, 20, 0)]:
			scene.set_view(view.x, view.y)
			await process_frame
			await RenderingServer.frame_post_draw
			root.get_texture().get_image().save_png("res://assets/city/luoyang/view-%d-%d.png" % [int(view.x), int(view.y)])
		scene.free()
		quit()
		return

	scene.queue_free()
	await process_frame
	root.size = Vector2i(1280, 720)
	var sandbox: Node = load("res://scripts/core/game_state.gd").new()
	sandbox.persist_enabled = false
	sandbox._load_demo()
	var interior: CanvasLayer = load("res://scenes/city_interior.tscn").instantiate()
	interior.store = sandbox
	root.add_child(interior)
	interior.open_city("luoyang", "洛阳", "司隶")
	var fresh := Image.load_from_file("res://assets/city/luoyang/preview-perspective.png")
	interior.root_ui.get_node("CityBackground").texture = ImageTexture.create_from_image(fresh)
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://assets/city/luoyang/city-preview.png")
	interior.queue_free()
	sandbox.free()
	await process_frame
	quit()

