extends SceneTree

const Fort = preload("res://scripts/war/city_fortifications.gd")
const Siege = preload("res://scripts/war/siege_visual.gd")
var output := "res://docs/validation/hex-combat-readability-2026-10-07/"
func _initialize() -> void: call_deferred("run")
func save(name: String) -> void:
	for i in range(3): await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(output+name+".png")
func run() -> void:
	root.size = Vector2i(1600,900)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output))
	var store = root.get_node("GameState")
	store.persist_enabled = false
	store.agent.enabled = false
	store.prepare_battle_test(true,"plains_clash",42)
	store.time_paused = true
	var shooter: Dictionary = store.war.active_armies("liu_bei").filter(func(a): return a["units"]["archers"] > a["units"]["infantry"])[0]
	var victim: Dictionary = store.war.active_armies("yuan_shao")[0]
	for army in store.war.active_armies():
		if army["id"] not in [shooter["id"],victim["id"]]: army["status"] = "ended"
	var grid = store.war.Tactical.grid()
	var source_cell: int = shooter["tactical"]["cell"]
	var target_cell: int = grid.index_at(source_cell%220,source_cell/220+2)
	assert(store.war.Tactical.can_enter(store.war,victim,target_cell))
	victim["tactical"]["cell"] = target_cell
	victim["units"] = {"infantry":5000,"cavalry":0,"archers":0}
	store.war._observe_all()
	var scene = load("res://scenes/rtk14_world_3d.tscn").instantiate()
	root.add_child(scene)
	while not scene.loaded: await process_frame
	# Let the map's deferred battle focus finish before fixing the test camera.
	for frame in range(4): await process_frame
	scene.set_process(false)
	var world = scene.army_world
	world.set_process(false)
	for canvas in scene.find_children("*","CanvasLayer",true,false): canvas.visible = false
	world.layer.visible = true
	if not scene.hex_world.enabled: scene.hex_world.toggle()
	world.presenting = false
	world.refresh()
	for id in world.formations:
		world.formations[id].position = world.destinations[id]
		world._fit_formation_to_hex(world.formations[id])
	var group: Node3D = world.formations[shooter["id"]]
	var target: Vector3 = world.formations[victim["id"]].global_position
	group.basis = Basis(Vector3.UP,world._yaw_between(group.global_position,target))
	world._fit_formation_to_hex(group)
	var bows = group.get_node("Archers")
	world._set_pose(bows,9,12,6.5)
	scene.camera_target = group.global_position.lerp(target,0.5)
	scene.target_goal = scene.camera_target
	scene.pitch = deg_to_rad(48)
	world._process(0)
	world.advantage_panel.visible = false
	for distance in [38,75]:
		scene.distance = distance
		scene.distance_goal = distance
		scene._update_camera()
		world._process(0)
		world.advantage_panel.visible = false
		var victim_group: Node3D = world.formations[victim["id"]]
		var victim_batch: MultiMeshInstance3D = victim_group.get_node("Soldiers")
		var foot: Vector3 = victim_batch.global_transform*victim_batch.multimesh.get_instance_transform(0).origin
		print("READABILITY_TARGET distance=",distance," root=",victim_group.global_position," foot=",foot," target=",target," screen_root=",scene.camera.unproject_position(victim_group.global_position)," screen_foot=",scene.camera.unproject_position(foot)," badge=",world.badges[victim["id"]].position)
		for i in range(24):
			var time := 0.7+float(i)/12.0
			bows.material_override.set_shader_parameter("animation_clock",time)
			world.combat_effects.begin_frame()
			world.combat_effects.show_archer_volley(shooter["id"],group,target,time,target_cell)
			world.combat_effects.end_frame()
			await save("arrows-%d-%02d"%[distance,i])
	store.prepare_battle_test(true,"siege_assault",42)
	store.time_paused = true
	var attacker: Dictionary = store.war.active_armies("yuan_shao").filter(func(a): return a.get("siege_engines",0) > 0)[0]
	for army in store.war.active_armies():
		if army["id"] != attacker["id"]: army["status"] = "ended"
	var site := Fort.for_city(store,"xiaopei")
	var nearest := -1
	var gap := INF
	for city_cell in site["cells"]:
		for candidate in grid.neighbors(int(city_cell)):
			if not store.war.Tactical.can_enter(store.war,attacker,candidate) or Fort.distance_to_wall(store.war.state["battlefield"],"xiaopei",candidate) != 1: continue
			var distance: float = grid.center(candidate).distance_to(grid.center(int(attacker["tactical"]["cell"])))
			if distance < gap: gap = distance; nearest = candidate
	assert(nearest >= 0)
	attacker["tactical"]["cell"] = nearest
	attacker["combat_tick"] = store.war.state["tick"]
	store.war.state["sieges"]["xiaopei"] = {"phase":"强攻","active_tick":store.war.state["tick"],"participants":[attacker["id"]]}
	world.refresh()
	for id in world.formations:
		world.formations[id].position = world.destinations[id]
		world._fit_formation_to_hex(world.formations[id])
	world.presenting = true
	var visual: Dictionary = world._combat_visual(attacker["id"])
	assert(not visual.is_empty())
	group = world.formations[attacker["id"]]
	target = visual["target"]
	group.basis = Basis(Vector3.UP,world._yaw_between(group.position,target))
	var equipment: Node3D = group.get_node("SiegeEngines")
	Siege.aim(equipment,target)
	world._fit_formation_to_hex(group)
	scene.camera_target = group.position.lerp(target,0.5)
	scene.target_goal = scene.camera_target
	scene.distance = 33
	scene.distance_goal = 33
	scene.pitch = deg_to_rad(43)
	scene._update_camera()
	world.presenting = false
	world._process(0)
	world.advantage_panel.visible = false
	for i in range(24):
		var time := float(i)/12.0
		Siege.animate(equipment,time,true,false)
		world.combat_effects.begin_frame()
		world.combat_effects.show_siege_projectiles(attacker["id"],equipment,target,time,visual["target_cell"])
		world.combat_effects.end_frame()
		await save("siege-%02d"%i)
	for distance in [38,75]:
		scene.distance = distance
		scene.distance_goal = distance
		scene._update_camera()
		for i in range(24):
			world.combat_effects.begin_frame()
			world.combat_effects.show_city_volley("readability",world._city_wall(site,group.position),group.position,0.28+float(i)/12.0,nearest)
			world.combat_effects.end_frame()
			await save("city-%d-%02d"%[distance,i])
	print("HEX_COMBAT_READABILITY_CAPTURE_OK near/far field arrows, fitted engines, wall aim, city arrows")
	quit()
