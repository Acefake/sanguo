extends SceneTree
func _initialize() -> void: call_deferred("run")
func run() -> void:
	var store = root.get_node("GameState")
	store.persist_enabled = false
	store.agent.enabled = false
	assert(ProjectSettings.get_setting("application/run/main_scene") == "res://scenes/battle_start.tscn")
	change_scene_to_file("res://scenes/battle_start.tscn")
	await process_frame
	await process_frame
	assert(not store.battle_test and store.battle_picker == null)
	assert(current_scene.faction_choice.item_count == store.scenario["factions"].size())
	store.open_battle_scenarios(false)
	var picker = store.battle_picker
	assert(current_scene.name == "BattleStart" and not store.battle_test)
	assert(picker.surface.visible and not picker.startup_mode)
	assert(picker.return_button.visible)
	assert(picker.launch.text == "开始 / 重置此场景")
	for spec in preload("res://scripts/war/battle_scenarios.gd").definitions():
		var id: String = spec["id"]
		picker.buttons[id].pressed.emit()
		assert(picker.selected == id)
	picker.buttons["guandu_clash"].pressed.emit()
	picker.seed.value = 42
	await process_frame
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("res://docs/validation/battle-start.png")
	picker.launch.pressed.emit()
	await process_frame
	await process_frame
	assert(store.battle_test)
	assert(store.war.state["battlefield"]["scenario_id"] == "guandu_clash")
	assert(store.war.state["battlefield"]["seed"] == 42)
	assert(not picker.surface.visible)
	assert(current_scene.scene_file_path == "res://scenes/rtk14_world_3d.tscn")
	while not current_scene.loaded: await process_frame
	current_scene.queue_free()
	await process_frame
	await process_frame
	store.restore_battle_test()
	change_scene_to_file("res://scenes/battle_start.tscn")
	await process_frame
	await process_frame
	var menu = current_scene
	for index in range(menu.faction_choice.item_count):
		if menu.faction_choice.get_item_metadata(index) == "cao_cao": menu.faction_choice.select(index)
	store.year = 205; store.month = 1; store.day = 12
	store.war.state["tick"] = 99
	store.chronicles.append("previous campaign")
	for button in menu.find_children("*", "Button", true, false):
		if button.text == "以所选势力开始新战役": button.pressed.emit(); break
	await process_frame
	await process_frame
	assert(current_scene.scene_file_path == "res://scenes/rtk14_world_3d.tscn")
	while not current_scene.loaded: await process_frame
	assert(not store.battle_test and store.war.state["campaign_started"] and store.war.state["player_faction"] == "cao_cao")
	assert(store.year == 191 and store.month == 9 and store.day == 1 and store.war.state["tick"] == 0 and store.action_points == 3)
	assert(store.chronicles.is_empty() and not store.war.state.has("battlefield"))
	store.war.state["tick"] = 7; store.day = 8
	store.chronicles.append("campaign preserved")
	change_scene_to_file("res://scenes/battle_start.tscn")
	await process_frame
	await process_frame
	for button in current_scene.find_children("*", "Button", true, false):
		if button.text == "继续当前战役": button.pressed.emit(); break
	await process_frame
	await process_frame
	while not current_scene.loaded: await process_frame
	assert(not store.battle_test and store.war.state["player_faction"] == "cao_cao" and store.war.state["tick"] == 7 and store.day == 8)
	assert(store.chronicles.has("campaign preserved"))
	current_scene.queue_free()
	await process_frame
	await process_frame
	print("BATTLE_START_OK: 21 factions, new campaign resets, continue preserves, eight isolated scenarios")
	quit()
