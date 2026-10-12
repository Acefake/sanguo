extends SceneTree

func _initialize() -> void:
	call_deferred("measure")

func measure() -> void:
	var world = load("res://scenes/rtk14_world_3d.tscn").instantiate()
	root.add_child(world)
	while not world.loaded:
		await process_frame
	world.focus_city("luoyang", true)
	world._clear_selection()
	world.set_process("--live-process" in OS.get_cmdline_user_args())
	var result: Dictionary = {}
	RenderingServer.viewport_set_measure_render_time(root.get_viewport_rid(), true)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	for mode in ["flow", "no_static_rocks", "fine", "overview", "far_transition", "flow_repeat"]:
		if mode == "overview":
			world._show_overview(true)
		else:
			world.focus_city("luoyang", true)
			if mode == "far_transition":
				world.distance = 700.0
				world.distance_goal = 700.0
				world._update_camera()
		world._set_map_quality(1 if mode == "fine" else 0)
		world._update_vegetation_lod()
		world.vegetation_root.visible = mode != "no_vegetation"
		world.landscape_root.visible = mode != "no_static_rocks"
		for batch in world.vegetation_batches:
			batch.visible = mode not in ["overview", "far_transition"] and not (mode == "no_grass" and bool(batch.get_meta("ground_cover", false)))
			if mode == "no_tree_shadows":
				batch.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		for child in world.get_children():
			if child is DirectionalLight3D:
				child.shadow_enabled = mode != "no_shadows"
		for frame in range(12):
			await process_frame
		var samples: Array[float] = []
		var gpu_samples: Array[float] = []
		var cpu_samples: Array[float] = []
		var previous := Time.get_ticks_usec()
		for frame in range(45):
			await process_frame
			var now := Time.get_ticks_usec()
			samples.append(float(now - previous) / 1000.0)
			gpu_samples.append(RenderingServer.viewport_get_measured_render_time_gpu(root.get_viewport_rid()))
			cpu_samples.append(RenderingServer.viewport_get_measured_render_time_cpu(root.get_viewport_rid()))
			previous = now
		samples.sort()
		gpu_samples.sort()
		cpu_samples.sort()
		var median := samples[22]
		result[mode] = {"median_ms": median, "p95_ms": samples[42], "fps": 1000.0 / median,
			"gpu_ms": gpu_samples[22], "cpu_render_ms": cpu_samples[22],
			"shadow_primitives": root.get_render_info(Viewport.RENDER_INFO_TYPE_SHADOW, Viewport.RENDER_INFO_PRIMITIVES_IN_FRAME),
			"primitives": root.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE, Viewport.RENDER_INFO_PRIMITIVES_IN_FRAME),
			"draw_calls": root.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE, Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME)}
		print("PERF ", mode, " ", JSON.stringify(result[mode]))
		if mode == "far_transition":
			await RenderingServer.frame_post_draw
			root.get_texture().get_image().save_png("res://docs/validation/optimized-far-transition.png")
	var path := "res://docs/validation/performance-current.json"
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--report="):
			path = argument.trim_prefix("--report=")
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(result, "\t"))
	quit()
