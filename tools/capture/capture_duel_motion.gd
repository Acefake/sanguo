extends SceneTree
func _initialize() -> void:
	call_deferred("capture")
func capture() -> void:
	root.size = Vector2i(1260, 710)
	var scene = load("res://scenes/duel_preview.tscn").instantiate()
	root.add_child(scene)
	while scene.presentation == null:
		await process_frame
	var overlay = scene.presentation
	overlay.set_process(false)
	var target := "res://docs/validation/gold-duel/motion"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(target))
	var frames := int(ceil((overlay.combat_seconds + 6) * 12))
	for frame in range(frames):
		overlay.elapsed = float(frame) / 12.0
		overlay._update_stage()
		await process_frame
		await RenderingServer.frame_post_draw
		var image := root.get_texture().get_image()
		image.resize(960, 540, Image.INTERPOLATE_LANCZOS)
		image.save_jpg(ProjectSettings.globalize_path(target + "/%04d.jpg" % frame), 0.9)
	print("DUEL_MOTION_OK frames=",frames)
	quit()
