extends SceneTree

const World = preload("res://scripts/war/army_world_3d.gd")
var output := "res://docs/validation/formation-detail-2026-10-09/"

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
	enemy["tactical"]["cell"] = Array(grid.neighbors(cell)).filter(func(c): return grid.walkable(c))[0]
	for army in [own,enemy]:
		army["status"] = "active"
		army["returning"] = false
		army["units"] = {"infantry":6000,"archers":0,"cavalry":0}
		army["initial_strength"] = 6000
		army["action"] = {"type":"hold"}
	store.war._observe_all()
	var scene = load("res://scenes/rtk14_world_3d.tscn").instantiate()
	root.add_child(scene)
	while not scene.loaded: await process_frame
	for frame in range(4): await process_frame
	scene.set_process(false)
	if not scene.hex_world.enabled: scene.hex_world.toggle()
	var world = scene.army_world
	world.set_process(false)
	for canvas in scene.find_children("*","CanvasLayer",true,false): canvas.visible = false
	world.layer.visible = true
	world.presenting = false
	world.refresh()
	for id in world.formations: world.formations[id].position = world.destinations[id]
	var group: Node3D = world.formations[own["id"]]
	var target: Vector3 = world.formations[enemy["id"]].global_position
	group.rotation.y = world._yaw_between(group.global_position,target)
	scene.camera_target = group.global_position.lerp(target,0.5)
	scene.target_goal = scene.camera_target
	scene.distance = 26
	scene.distance_goal = 26
	scene.yaw = deg_to_rad(90)
	scene.pitch = deg_to_rad(48)
	scene._update_camera()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output))
	var results := {}
	for kind in ["infantry","archers","cavalry"]:
		for army in [own,enemy]:
			army["units"] = {"infantry":0,"archers":0,"cavalry":0}
			army["units"][kind] = 6000
		world.refresh()
		var batch: MultiMeshInstance3D = group.get_node("Mounted/Cavalry" if kind == "cavalry" else "Archers" if kind == "archers" else "Soldiers")
		for mode in ["idle","march","combat"]:
			world._process(0)
			world.advantage_panel.visible = false
			for id in world.formations:
				var unit: Node3D = world.formations[id]
				unit.set_meta("combat_pose",mode == "combat")
				world._fit_formation_to_hex(unit,mode == "march")
				var troop: MultiMeshInstance3D = unit.get_node("Mounted/Cavalry" if kind == "cavalry" else "Archers" if kind == "archers" else "Soldiers")
				world._set_pose(troop,9 if mode == "combat" else 1 if mode == "march" else 21,12 if mode == "combat" else 8,6.5 if mode == "combat" else 4.5,true)
				troop.material_override.set_shader_parameter("animation_clock",1.2)
			assert(batch.multimesh.visible_instance_count == World.density_counts(kind)[0])
			for frame in range(3): await process_frame
			await RenderingServer.frame_post_draw
			root.get_texture().get_image().save_png(output+kind+"-"+mode+".png")
		group.set_meta("combat_pose",false)
		world._fit_formation_to_hex(group)
		var scale_before: float = group.get_meta("formation_scale")
		var camera_before: Vector3 = scene.camera.global_position
		for distance in [160.0,320.0]:
			scene.camera.global_position = group.global_position+Vector3(0,distance,0)
			world._apply_troop_detail(group)
			world._apply_troop_detail(group)
			world._fit_formation_to_hex(group)
			var expected_count: int = World.density_counts(kind)[1 if distance < 200 else 2]
			assert(batch.multimesh.visible_instance_count == expected_count)
			assert(is_equal_approx(scale_before,float(group.get_meta("formation_scale"))),"LOD resized the formation")
		scene.camera.global_position = camera_before
		world._apply_troop_detail(group)
		world._apply_troop_detail(group)
		world._fit_formation_to_hex(group)
		var updates_before: int = group.get_meta("fit_updates")
		var start := Time.get_ticks_usec()
		for i in range(200): world._fit_formation_to_hex(group)
		var cached_usec := Time.get_ticks_usec()-start
		assert(int(group.get_meta("fit_updates")) == updates_before,"Stationary formation did not reuse fitted transforms")
		start = Time.get_ticks_usec()
		for i in range(200):
			group.remove_meta("fit_signature")
			world._fit_formation_to_hex(group)
		results[kind] = {"cached_200_usec":cached_usec,"forced_200_usec":Time.get_ticks_usec()-start,"near_count":batch.multimesh.visible_instance_count,"scale":scale_before}
	for army in [own,enemy]: army["units"] = {"infantry":6000,"archers":0,"cavalry":0}
	store.war.Tactical.resolve(store.war)
	world.refresh()
	world.begin_day({})
	store.time_paused = false
	store.time_scale = 1
	var cpu_samples: Array = []
	var frame_samples: Array = []
	var previous_frame := Time.get_ticks_usec()
	for frame in range(90):
		var start := Time.get_ticks_usec()
		world._process(1.0/30.0)
		cpu_samples.append(Time.get_ticks_usec()-start)
		world.advantage_panel.visible = false
		await process_frame
		await RenderingServer.frame_post_draw
		var now := Time.get_ticks_usec()
		if frame > 5: frame_samples.append(now-previous_frame)
		if frame in [30,60,89]: root.get_texture().get_image().save_png(output+"contact-%02d.png"%frame)
		previous_frame = Time.get_ticks_usec()
	cpu_samples.sort()
	frame_samples.sort()
	results["map_contact"] = {"cpu_median_usec":cpu_samples[45],"cpu_p95_usec":cpu_samples[85],"frame_median_usec":frame_samples[frame_samples.size()/2],"frame_p95_usec":frame_samples[int(frame_samples.size()*0.95)],"armies":world.formations.size()}
	FileAccess.open(output+"result.json",FileAccess.WRITE).store_string(JSON.stringify(results,"\t"))
	print("FORMATION_DETAIL_OK ",results)
	quit()
