extends SceneTree

func _initialize() -> void:
	call_deferred("capture")

func capture() -> void:
	root.size = Vector2i(1260, 710)
	var scene: Node = load("res://scenes/mounted_duel_preview.tscn").instantiate()
	root.add_child(scene)
	await process_frame
	var overlay: CanvasLayer = scene.presentation
	overlay.set_process(false)
	print("MOUNTED_DUEL_RESULT rounds=", overlay.round_data.size(), " winner=", overlay.active_record.get("winner", -1))
	var target := "res://docs/validation/mounted-duel"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(target))
	var frame_rate := 24.0
	var frames := int(ceil((overlay.ROUND_SECONDS * overlay.round_data.size() + 2.6) * frame_rate))
	for frame in range(frames):
		overlay.elapsed = float(frame) / frame_rate
		overlay._update_stage()
		await process_frame
		await RenderingServer.frame_post_draw
		var image := root.get_texture().get_image()
		image.resize(960, 540, Image.INTERPOLATE_LANCZOS)
		image.save_jpg(ProjectSettings.globalize_path(target + "/%03d.jpg" % frame), 0.86)
		if frame % 25 == 0: print("MOUNTED_DUEL_FRAME ", frame, "/", frames)
	print("MOUNTED_DUEL_CAPTURE_OK: stationary mounted duel from contest algorithm; frames=", frames)
	quit()
