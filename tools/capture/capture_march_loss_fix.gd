extends SceneTree
func _initialize() -> void: call_deferred("run")
func run() -> void:
	root.size = Vector2i(1600,900)
	var store = root.get_node("GameState")
	store.persist_enabled = false
	store.agent.enabled = false
	store.prepare_battle_test(true,"plains_clash",42)
	store.time_paused = true
	var pair: Array = [store.war.active_armies("liu_bei")[0],store.war.active_armies("yuan_shao")[0]]
	for army in store.war.active_armies():
		if army["id"] not in [pair[0]["id"],pair[1]["id"]]: army["status"] = "ended"
	var cell: int = pair[0]["tactical"]["cell"]
	pair[1]["tactical"]["cell"] = cell+1
	for i in range(2):
		pair[i]["units"] = {"infantry":5000 if i == 0 else 0,"cavalry":3000 if i == 1 else 0,"archers":0}
		pair[i]["tactical"]["attack_target"] = pair[1-i]["id"]
		pair[i]["tactical"]["phase"] = "交战"
		pair[i]["combat_tick"] = store.war.state["tick"]
		pair[i]["daily_loss_tick"] = store.war.state["tick"]
		pair[i]["daily_loss"] = 143+i*62
		pair[i]["tactical"]["move_path"] = []
	store.war._observe_all()
	var scene = load("res://scenes/rtk14_world_3d.tscn").instantiate()
	root.add_child(scene)
	while not scene.loaded: await process_frame
	for frame in range(4): await process_frame
	scene.set_process(false)
	var world = scene.army_world
	world.set_process(false)
	for canvas in scene.find_children("*","CanvasLayer",true,false): canvas.visible = false
	world.layer.visible = true
	world.presenting = false
	world.refresh()
	for army in pair:
		var id: String = army["id"]
		world.formations[id].position = world.destinations[id]
		world._fit_formation_to_hex(world.formations[id])
		world.formations[id].position.x += -12 if army == pair[0] else 12
	world.begin_day({})
	scene.camera_target = world.destinations[pair[0]["id"]].lerp(world.destinations[pair[1]["id"]],0.5)
	scene.target_goal = scene.camera_target
	scene.distance = 45
	scene.distance_goal = 45
	scene.pitch = deg_to_rad(48)
	scene._update_camera()
	store.time_paused = false
	store.time_scale = 1
	var output := "res://docs/validation/march-loss-2026-10-07/"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output))
	for frame in range(96):
		world._process(0.05)
		world.advantage_panel.visible = false
		await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(output+"frame-%03d.png"%frame)
		if frame == 20: assert(world.loss_floaters.is_empty(),"Early damage in real map")
		if frame == 85: assert(world.loss_floaters.size() > 0,"Damage missing after arrival in real map")
	print("MARCH_LOSS_CAPTURE PASS")
	quit()
