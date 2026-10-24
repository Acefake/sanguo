extends SceneTree

func _initialize() -> void:
	call_deferred("capture")

func capture() -> void:
	root.size = Vector2i(1260, 710)
	var scene: Node = load("res://scenes/mounted_duel_preview.tscn").instantiate()
	root.add_child(scene)
	await process_frame
	var popup = scene.presentation
	popup.set_process(false)
	popup.fighter_right.hide()
	popup.fighter_left.position = Vector3.ZERO
	var test_actor = popup.fighter_left
	popup.camera.size = 3.8
	popup.camera.look_at_from_position(Vector3(0, 2.6, 10), Vector3(0, 1.4, 0))
	for view in [["front", 0.0], ["side", PI / 2.0], ["rear", PI]]:
		popup.fighter_left.rotation.y = view[1]
		popup.fighter_left.pose(0, 0, 0)
		await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(ProjectSettings.globalize_path("res://docs/validation/mounted-duel/seating-%s.png" % view[0]))
	popup.fighter_left.rotation.y = PI / 2.0
	popup.fighter_left.pose(0.2, 0.03, 1.0, 1, 0.38)
	await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(ProjectSettings.globalize_path("res://docs/validation/mounted-duel/seating-strike.png"))
	test_actor.rotation.y = 0.0
	test_actor.pose(0.0, 0.0, 0.0)
	popup.camera.size = 0.65
	popup.camera.look_at_from_position(Vector3(2.2, 2.2, 2.2), test_actor.weapon.position)
	await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(ProjectSettings.globalize_path("res://docs/validation/mounted-duel/grip-detail.png"))
	test_actor.rider.hide()
	test_actor.horse.hide()
	test_actor.weapon.position = Vector3(0.0, 1.5, 0.0)
	test_actor.weapon.basis = Basis.IDENTITY
	popup.camera.size = 2.0
	popup.camera.look_at_from_position(Vector3(0, 5.0, 1.5), Vector3(0.4, 1.5, 0))
	await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(ProjectSettings.globalize_path("res://docs/validation/mounted-duel/weapon-inspect.png"))
	quit()
