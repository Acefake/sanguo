extends SceneTree

func _initialize() -> void: call_deferred("run")

func run() -> void:
	var store: Node = root.get_node("GameState")
	store.persist_enabled = false
	store.agent.enabled = false
	store.battle_test = false
	store._load_demo()
	store.war.start_campaign()
	var scene: Node = load("res://scenes/rtk14_world_3d.tscn").instantiate()
	root.add_child(scene)
	current_scene = scene
	for index in range(8): await process_frame
	var war = store.war
	var faction := str(war.state["player_faction"])
	var owned: Array = war.Operations.cities(war, faction)
	var city := str(owned[0])
	var candidate: String = war.Talent._local_candidate(war, city)
	war.Talent.reveal(war, faction, candidate, "capture-fixture")
	var ui: Node = _find_ui(scene)
	var started := Time.get_ticks_msec()
	while ui == null and Time.get_ticks_msec() - started < 120000:
		await process_frame
		ui = _find_ui(scene)
	if ui == null:
		push_error("找不到地图中的真实军情界面")
		quit(1)
		return
	ui.show_talents(city)
	for index in range(5): await process_frame
	await RenderingServer.frame_post_draw
	var output := ""
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--capture-dir="): output = argument.trim_prefix("--capture-dir=")
	if output == "": push_error("需要提供截图输出目录"); quit(1); return
	DirAccess.make_dir_recursive_absolute(output)
	var result: int = root.get_texture().get_image().save_png(output.path_join("character-talents.png"))
	ui.show_character_history(candidate, city)
	for index in range(5): await process_frame
	await RenderingServer.frame_post_draw
	result |= root.get_texture().get_image().save_png(output.path_join("character-history.png"))
	if result == OK: print("CHARACTER_VISUAL_CAPTURE_OK")
	quit(0 if result == OK else 1)

func _find_ui(node: Node) -> Node:
	if node.has_method("show_talents"): return node
	for child in node.get_children():
		var result := _find_ui(child)
		if result != null: return result
	return null
