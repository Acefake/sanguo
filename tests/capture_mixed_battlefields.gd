extends SceneTree
var output := "res://docs/validation/mixed-battlefields-2026-10-06/"
func _initialize() -> void: call_deferred("run")
func run() -> void:
	root.size = Vector2i(1600,900)
	var store = root.get_node("GameState")
	store.persist_enabled = false
	store.agent.enabled = false
	store.prepare_battle_test(true,"plains_clash",42)
	var scene = load("res://scenes/rtk14_world_3d.tscn").instantiate()
	root.add_child(scene)
	while not scene.loaded: await process_frame
	for frame in range(4): await process_frame
	scene.set_process(false)
	var world = scene.army_world
	world.set_process(false)
	store.time_paused = true
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output))
	for canvas in scene.find_children("*","CanvasLayer",true,false): canvas.visible = false
	world.layer.visible = true
	world.advantage_panel.visible = false
	for id in ["plains_clash","siege_assault"]:
		store.prepare_battle_test(true,id,42)
		store.war.rules["duel"]["enabled"] = false
		store.time_paused = true
		world.refresh()
		world.presenting = false
		for army_id in world.formations: world.formations[army_id].position = world.destinations[army_id]
		world._focus_battle()
		scene.distance = 80
		scene.distance_goal = 80
		scene.pitch = deg_to_rad(45)
		scene._update_camera()
		world._process(0)
		world.advantage_panel.visible = false
		var seen := {}
		var equipment := 0
		for army in store.war.active_armies():
			seen[world.badges[army.id].troop_kind] = true
			var engines = world.formations[army.id].get_node("SiegeEngines")
			equipment += engines.get_child_count()
		assert(seen.size() == 3)
		if id == "siege_assault": assert(equipment == 4)
		world._update_chatter(true)
		for frame in range(5): await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(output+id+".png")
		print("MIXED_BATTLEFIELD_CAPTURE_OK ",id," native engines=",equipment)
		if id == "siege_assault":
			for army in store.war.active_armies():
				if int(army.get("siege_engines",0)) == 0: continue
				scene.camera_target = world.formations[army.id].position
				scene.target_goal = scene.camera_target
				scene.distance = 28
				scene.distance_goal = 28
				scene.pitch = deg_to_rad(32)
				scene._update_camera()
				world._process(0)
				world.advantage_panel.visible = false
				for frame in range(4): await process_frame
				await RenderingServer.frame_post_draw
				root.get_texture().get_image().save_png(output+"engines-close.png")
	store.open_battle_scenarios(true)
	assert(store.battle_picker.buttons.size() == 3)
	for id in store.battle_picker.buttons:
		store.battle_picker.buttons[id].pressed.emit()
		assert(store.battle_picker.selected == id)
	store.battle_picker.choose("siege_assault")
	for frame in range(4): await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(output+"selector.png")
	print("MIXED_BATTLEFIELD_SELECTOR_OK 3 choices")
	quit()
