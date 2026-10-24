extends SceneTree

func _initialize() -> void:
	call_deferred("capture")

func capture() -> void:
	root.size = Vector2i(1260, 710)
	var scene: Node = load("res://scenes/duel_preview.tscn").instantiate()
	root.add_child(scene)
	await process_frame
	while scene.presentation == null:
		await process_frame
	var overlay: CanvasLayer = scene.presentation
	overlay.set_process(false)
	var target := "res://docs/validation/gold-duel"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(target))
	print("GOLD_DUEL_RESULT ", overlay.active_record.get("winner", -1), " rounds=", overlay.active_record.get("rounds", []).size())
	for frame in range(264):
		overlay.elapsed = float(frame) / 24.0
		overlay._update_stage()
		await process_frame
		await RenderingServer.frame_post_draw
		var image := root.get_texture().get_image()
		image.resize(960, 540, Image.INTERPOLATE_LANCZOS)
		image.save_jpg(ProjectSettings.globalize_path(target + "/%03d.jpg" % frame), 0.88)
		if frame == 80: image.save_png(ProjectSettings.globalize_path(target + "/gold-effect.png"))
		if frame == 216: image.save_png(ProjectSettings.globalize_path(target + "/gold-result.png"))
	print("GOLD_DUEL_CAPTURE_OK")
	quit()
