extends SceneTree

func _initialize() -> void:
	call_deferred("capture")

func capture() -> void:
	root.size = Vector2i(1280, 946)
	var store = root.get_node("GameState")
	store.persist_enabled = false
	store.prepare_battle_test(true, "plains_clash", 42)
	store.time_paused = true
	var scene = load("res://scenes/rtk14_world_3d.tscn").instantiate()
	root.add_child(scene)
	while not scene.loaded: await process_frame
	var world = scene.army_world
	var overlay = world.duel_presentation
	var a: Dictionary = {}
	var b: Dictionary = {}
	for officer in store.war.roster.officers.values():
		if officer.get("name", "") == "袁谭": a = officer
		if officer.get("name", "") == "黄忠": b = officer
	assert(not a.is_empty() and not b.is_empty())
	var focus: Vector3 = world.destinations.values()[0]
	scene.set_process(false)
	scene.camera_target = focus
	scene.target_goal = focus
	scene.distance = 45
	scene.pitch = deg_to_rad(48)
	scene._update_camera()
	var record := {"duel_id":"ui-layout-preview", "winner":1, "result":"overwhelming", "initial_hp":[115.0,127.0], "max_hp":[115.0,127.0], "final_hp":[0.0,64.0], "fate":{"status":"captured"}, "rounds":[{"hp_a":0.0,"hp_b":64.0,"damage_a":115.0,"damage_b":63.0}]}
	var output := "res://docs/validation/duel-ui-2026-10-09/"
	for sample in ["combat", "right-winner", "left-winner"]:
		if sample == "left-winner":
			record["winner"] = 0
			record["rounds"][0].merge({"hp_a":64.0,"hp_b":0.0}, true)
		overlay.hide()
		overlay.present_record(record, a, b, world._portrait("袁谭"), world._portrait("黄忠"))
		overlay.demo = true
		overlay.set_process(false)
		overlay.elapsed = 0.8 if sample == "combat" else overlay.combat_seconds + 2.0
		overlay._update_stage()
		await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(output + sample + ".png")
	print("DUEL_UI_CAPTURE_OK real map, combat, both winner positions")
	quit()
