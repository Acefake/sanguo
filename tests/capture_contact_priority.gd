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
	var enemy: Dictionary = store.war.active_armies("yuan_shao")[1]
	for army in store.war.active_armies(): army["status"] = "ended"
	var grid = store.war.Tactical.grid()
	var cell: int = own["tactical"]["cell"]
	var target: int = Array(grid.neighbors(cell)).filter(func(c): return grid.walkable(c))[0]
	var starts: Array = Array(grid.neighbors(cell)).filter(func(c): return grid.walkable(c) and c != target)
	starts.sort_custom(func(a,b): return grid.center(a).distance_squared_to(grid.center(target)) > grid.center(b).distance_squared_to(grid.center(target)))
	var start: int = starts[0]
	for army in [own,enemy]:
		army["status"] = "active"
		army["returning"] = false
		army["units"] = {"infantry":6000,"archers":0,"cavalry":0}
		army["initial_strength"] = 6000
		army["morale"] = 100.0
		army["organization"] = 100.0
		army["action"] = {"type":"hold"}
		army["tactical"].erase("terrain_delay")
	own["tactical"]["cell"] = cell
	enemy["tactical"]["cell"] = target
	store.war._observe_all()
	store.war.Tactical.resolve(store.war)
	own["tactical"]["move_path"] = [start,cell]
	own["tactical"]["previous_goal"] = target
	enemy["tactical"]["move_path"] = [target]
	store.war._observe_all()
	var scene = load("res://scenes/rtk14_world_3d.tscn").instantiate()
	root.add_child(scene)
	while not scene.loaded: await process_frame
	scene.set_process(false)
	var world = scene.army_world
	world.set_process(false)
	for canvas in scene.find_children("*","CanvasLayer",true,false): canvas.visible = false
	world.layer.visible = true
	world.next_chatter_at = 100000.0
	world.formations[own["id"]].position = world._battle_point(start)
	world.formations[enemy["id"]].position = world._battle_point(target)
	for army in [own,enemy]: world.badges[army["id"]].strength = 6000
	world.begin_day({})
	store.time_paused = false
	store.time_scale = 1
	var output := "res://docs/validation/contact-priority-2026-10-08/"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output))
	var contact_at := -1.0
	var pinned := Vector3.ZERO
	var previous: Vector3 = world.formations[own["id"]].position
	var max_speed := 0.0
	for frame in range(120):
		world._process(0.05)
		world.advantage_panel.visible = false
		var group: Node3D = world.formations[own["id"]]
		var position: Vector3 = group.position
		max_speed = maxf(max_speed,((position-previous)*Vector3(1,0,1)).length()/0.05)
		previous = position
		if world.melee_positions.has(own["id"]):
			if contact_at < 0:
				contact_at = world.presentation_elapsed
				pinned = position
				assert(not world._at_display_destination(own["id"]),"Map attack waits for the cell center")
			assert(position.is_equal_approx(pinned),"Map contact still slides along the march route")
			for army in [own,enemy]: assert(world.formations[army["id"]].get_node("Soldiers").get_meta("pose_start") == 9,"Map contact lost its attack animation")
		await process_frame
		scene.camera_target = world._battle_point(cell).lerp(world._battle_point(target),0.5)
		scene.distance = 45
		scene.pitch = deg_to_rad(48)
		scene._update_camera()
		await RenderingServer.frame_post_draw
		if frame % 2 == 0: root.get_texture().get_image().save_png(output+"frame-%03d.png" % (frame/2))
	assert(contact_at > 0 and contact_at < world.TACTICAL_MOVE_SECONDS,"No early physical contact on map")
	assert(max_speed < 3.0,"Movement remains too fast at normal speed")
	var result := {"contact_at_seconds":contact_at,"movement_seconds":world.TACTICAL_MOVE_SECONDS,"maximum_speed":max_speed,"contact_distance_to_goal":((pinned-world.destinations[own["id"]])*Vector3(1,0,1)).length(),"own_strength":world.badges[own["id"]].strength,"enemy_strength":world.badges[enemy["id"]].strength}
	FileAccess.open(output+"result.json",FileAccess.WRITE).store_string(JSON.stringify(result,"\t"))
	print("CONTACT_PRIORITY_MAP PASS ",result)
	quit()
