extends SceneTree
func _initialize() -> void: call_deferred("run")
func run() -> void:
	root.size = Vector2i(1600,900)
	var store = root.get_node("GameState")
	store.persist_enabled = false
	store.agent.enabled = false
	store.prepare_battle_test(true,"plains_clash",42)
	store.time_paused = true
	store.war.rules["duel"]["enabled"] = false
	var own: Dictionary = store.war.active_armies("liu_bei")[1]
	var enemies: Array = store.war.active_armies("yuan_shao").slice(0,3)
	for unit in store.war.active_armies(): unit["status"] = "ended"
	var anchor: int = own["tactical"]["cell"]
	var cells: Array = store.war.Tactical.neighbors(anchor)
	for i in range(3): enemies[i]["tactical"]["cell"] = cells[i*2]
	for unit in [own]+enemies:
		unit["status"] = "active"
		unit["returning"] = false
		unit["units"] = {"infantry":6000,"archers":0,"cavalry":0}
		unit["initial_strength"] = 6000
		unit["morale"] = 100.0
		unit["organization"] = 100.0
		unit["action"] = {"type":"hold"}
	store.war._observe_all()
	store.war.Tactical.resolve(store.war)
	store.war._observe_all()
	var scene = load("res://scenes/rtk14_world_3d.tscn").instantiate()
	root.add_child(scene)
	while not scene.loaded: await process_frame
	scene.set_process(false)
	var world = scene.army_world
	world.set_process(false)
	for canvas in scene.find_children("*","CanvasLayer",true,false): canvas.visible = false
	world.layer.visible = true
	for unit in [own]+enemies:
		var id: String = unit["id"]
		world.formations[id].position = world.destinations[id]
		world.badges[id].strength = 6000
		if unit != own:
			world.formations[id].position += (world.destinations[id]-world.destinations[own["id"]]).normalized()*12
	world.begin_day({})
	scene.camera_target = world.destinations[own["id"]]
	scene.target_goal = scene.camera_target
	scene.distance = 55
	scene.distance_goal = 55
	scene.pitch = deg_to_rad(48)
	scene._update_camera()
	store.time_paused = false
	store.time_scale = 1
	var output := "res://docs/validation/multi-contact-2026-10-08/"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output))
	var contact_frame := roundi(world.TACTICAL_MOVE_SECONDS/0.05)+6
	for frame in range(contact_frame+30):
		world._process(0.05)
		world.advantage_panel.visible = false
		await process_frame
		scene.camera_target = world.destinations[own["id"]]
		scene.distance = 55
		scene._update_camera()
		await RenderingServer.frame_post_draw
		if frame % 5 == 0: root.get_texture().get_image().save_png(output+"frame-%03d.png" % frame)
		if frame == contact_frame:
			assert(world._combat_fronts(own["id"]).size() == 3,"Three visible contacts have no attack animations")
		if frame == contact_frame+20:
			for enemy in enemies:
				assert(world.badges[enemy["id"]].strength < 6000,"Secondary damage missing on map")
			assert(world._combat_fronts(own["id"]).size() == 3,"Three contact animations missing")
	print("MULTI_CONTACT_MAP PASS")
	quit()
