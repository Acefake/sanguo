extends SceneTree

func _initialize() -> void:
	call_deferred("capture")

func capture() -> void:
	root.size = Vector2i(1260,710)
	var store = root.get_node("GameState")
	store.persist_enabled = false
	store.agent.enabled = false
	store.prepare_battle_test(true, "plains_clash", 42)
	store.time_paused = true
	var scene = load("res://scenes/rtk14_world_3d.tscn").instantiate()
	root.add_child(scene)
	while not scene.loaded: await process_frame
	var world = scene.army_world
	var overlay = world.duel_presentation
	var left: Dictionary = {}
	var right: Dictionary = {}
	for officer in store.war.roster.officers.values():
		if officer.get("name", "") == "袁谭": left = officer
		if officer.get("name", "") == "黄忠": right = officer
	assert(not left.is_empty() and not right.is_empty())
	scene.set_process(false)
	scene.camera_target = world.destinations.values()[0]
	scene.target_goal = scene.camera_target
	scene.distance = 45
	scene.pitch = deg_to_rad(48)
	scene._update_camera()
	var output := "res://docs/validation/duel-ui-2026-10-10/"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output))
	for fate in ["captured", "dead"]:
		for winner in [1, 0]:
			var hp := [0.0,64.0] if winner == 1 else [64.0,0.0]
			var record := {"duel_id":"fate-mark-"+fate+str(winner), "winner":winner, "result":"overwhelming", "initial_hp":[115.0,127.0], "max_hp":[115.0,127.0], "final_hp":hp, "fate":{"status":fate}, "rounds":[{"hp_a":hp[0],"hp_b":hp[1],"damage_a":115.0-hp[0],"damage_b":127.0-hp[1]}]}
			overlay.hide()
			overlay.demo = true
			overlay.present_record(record, left, right, world._portrait("袁谭"), world._portrait("黄忠"))
			overlay.set_process(false)
			if fate == "captured" and winner == 1:
				for sample in ["entry", "impact"]:
					overlay.elapsed = 0.5 if sample == "entry" else float(overlay.card.timeline[0]["at"]) + 0.35
					overlay._update_stage()
					await process_frame
					await RenderingServer.frame_post_draw
					root.get_texture().get_image().save_png(output + "playback-" + sample + ".png")
			overlay.elapsed = overlay.combat_end_at + 0.5
			overlay._update_stage()
			await process_frame
			await RenderingServer.frame_post_draw
			var path: String = output + fate + ("-left" if winner == 1 else "-right") + ".png"
			root.get_texture().get_image().save_png(path)
			print("DUEL_FATE_MARK_CAPTURE ", path)
	print("DUEL_FATE_MARK_CAPTURE_OK captured and dead, both portrait positions")
	quit()
