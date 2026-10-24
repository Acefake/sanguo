extends SceneTree
func _initialize() -> void: call_deferred("run")
func run() -> void:
	root.size = Vector2i(1600,900)
	var store = root.get_node("GameState")
	store.persist_enabled = false
	store.agent.enabled = false
	store.prepare_battle_test(true,"plains_clash",42)
	store.time_paused = true
	var army: Dictionary = store.war.active_armies("liu_bei")[1]
	for unit in store.war.active_armies():
		if unit != army: unit["status"] = "ended"
	var grid = store.war.Tactical.grid()
	var a: int = army["tactical"]["cell"]
	var b: int = grid.neighbors(a)[0]
	var direction: Vector2 = (grid.center(b)-grid.center(a)).normalized()
	var c: int = Array(grid.neighbors(b)).filter(func(cell):
		var alignment := direction.dot((grid.center(cell)-grid.center(b)).normalized())
		return alignment > 0.2 and alignment < 0.9)[0]
	var d: int = Array(grid.neighbors(c)).filter(func(cell): return cell != b and grid.distance(cell,b) == 2)[0]
	army["combat_tick"] = -1
	army["tactical"]["move_path"] = [a,b]
	army["tactical"]["cell"] = b
	army["tactical"]["previous_goal"] = c
	store.war._observe_all()
	var scene = load("res://scenes/rtk14_world_3d.tscn").instantiate()
	root.add_child(scene)
	while not scene.loaded: await process_frame
	scene.set_process(false)
	var world = scene.army_world
	world.set_process(false)
	for canvas in scene.find_children("*","CanvasLayer",true,false): canvas.visible = false
	world.layer.visible = true
	var id: String = army["id"]
	world.formations[id].position = world._battle_point(a)
	world.begin_day({})
	var output := "res://docs/validation/continuous-march-2026-10-08/"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output))
	store.time_paused = false
	store.time_scale = 1
	var previous: Vector3 = world.formations[id].position
	var heading := Vector3.ZERO
	var day_frames := roundi(world.TACTICAL_MOVE_SECONDS/0.05)
	for frame in range(day_frames*3):
		if frame in [day_frames,day_frames*2]:
			var from: int = b if frame == day_frames else c
			var to: int = c if frame == day_frames else d
			army["tactical"]["move_path"] = [from,to]
			army["tactical"]["cell"] = to
			army["tactical"]["previous_goal"] = d
			store.war.state["tick"] += 1
			world.begin_day({})
		world._process(0.05)
		var point: Vector3 = world.formations[id].position
		var travel := (point-previous)*Vector3(1,0,1)
		assert(travel.length() > 0.001,"March pauses at a hex or day boundary")
		if frame in [day_frames,day_frames*2]: assert(heading.dot(travel.normalized()) > 0.9,"March heading snaps at day boundary")
		previous = point
		heading = travel.normalized()
		world.advantage_panel.visible = false
		await process_frame
		scene.camera_target = world._battle_point(b)
		scene.distance = 40
		scene.pitch = deg_to_rad(48)
		scene._update_camera()
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(output+"frame-%03d.png" % frame)
	print("CONTINUOUS_MARCH_MAP PASS")
	quit()
