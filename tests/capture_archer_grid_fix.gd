extends SceneTree
var output := "res://docs/validation/archer-grid-fix-2026-10-11/"
func _initialize() -> void: call_deferred("run")
func run() -> void:
	root.size = Vector2i(1600,900)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output))
	var store = root.get_node("GameState")
	store.persist_enabled = false
	store.agent.enabled = false
	store.prepare_battle_test(true,"plains_clash",42)
	store.time_paused = true
	var war = store.war
	var shooter: Dictionary = war.active_armies("liu_bei")[0]
	var victim: Dictionary = war.active_armies("yuan_shao")[0]
	for army in war.active_armies():
		if army["id"] not in [shooter["id"],victim["id"]]: army["status"] = "ended"
	shooter["units"] = {"infantry":0,"archers":6000,"cavalry":0}
	victim["units"] = {"infantry":6000,"archers":0,"cavalry":0}
	var grid = war.Tactical.grid()
	var source: int = shooter["tactical"]["cell"]
	var target_cell := -1
	for adjacent in grid.neighbors(source):
		for candidate in grid.neighbors(adjacent):
			if grid.distance(source,candidate) == 2 and war.Tactical.can_enter(war,victim,candidate) and war.Tactical.Fort.line_of_sight(war.state["battlefield"],source,candidate): target_cell = candidate; break
		if target_cell >= 0: break
	assert(target_cell >= 0)
	victim["tactical"]["cell"] = target_cell
	for army in [shooter,victim]:
		army["returning"] = false
		army["action"] = {"type":"hold"}
	war._observe_all()
	war.Tactical.resolve(war)
	assert(shooter["tactical"]["phase"] == "远射")
	var scene = load("res://scenes/rtk14_world_3d.tscn").instantiate()
	root.add_child(scene)
	while not scene.loaded: await process_frame
	for frame in range(4): await process_frame
	scene.set_process(false)
	var world = scene.army_world
	world.set_process(false)
	for canvas in scene.find_children("*","CanvasLayer",true,false): canvas.visible = false
	world.layer.visible = true
	if not scene.hex_world.enabled: scene.hex_world.toggle()
	world.refresh()
	var a: Vector3 = world.destinations[shooter["id"]]
	var b: Vector3 = world.destinations[victim["id"]]
	var direction := (b-a).normalized()
	var side := Vector3(-direction.z,0,direction.x)*1.4
	for id in world.formations:
		world.formations[id].position = world.destinations[id]+side
		world.motion_start[id] = world.formations[id].position
		world.motion_durations[id] = 50.0
	world.presenting = true
	world.presentation_duration = 60.0
	world.presentation_elapsed = 0.0
	world.next_chatter_at = 100000.0
	scene.camera_target = a.lerp(b,0.5)
	scene.target_goal = scene.camera_target
	scene.distance = 38
	scene.distance_goal = 38
	scene.pitch = deg_to_rad(48)
	scene._update_camera()
	store.time_paused = false
	store.time_scale = 1
	assert(not world._at_display_destination(shooter["id"]))
	assert(world._combat_visual(shooter["id"]).get("ranged",false))
	for frame in range(42):
		world._process(0.05)
		world.advantage_panel.visible = false
		await process_frame
		if frame in [10,23,36]:
			await RenderingServer.frame_post_draw
			root.get_texture().get_image().save_png(output+"ranged-%02d.png"%frame)
	assert(world.formations[shooter["id"]].get_node("Archers").get_meta("pose_start") == 9)
	print("ARCHER_GRID_SCENE_OK real resolve and process volley")
	quit()
