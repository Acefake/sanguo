extends SceneTree
const Siege = preload("res://scripts/war/presentation/siege_visual.gd")
var output := "res://docs/validation/troop-siege-revision-2026-10-07/"
func _initialize() -> void: call_deferred("run")
func save(name: String) -> Image:
	for frame in range(3): await process_frame
	await RenderingServer.frame_post_draw
	var result := root.get_texture().get_image()
	result.save_png(output+name+".png")
	return result
func run() -> void:
	root.size = Vector2i(1600,900)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output))
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
	for canvas in scene.find_children("*","CanvasLayer",true,false): canvas.visible = false
	world.layer.visible = true
	for kind in ["cavalry","archers"]:
		world.refresh()
		world.presenting = false
		for id in world.formations: world.formations[id].position = world.destinations[id]
		var army = store.war.active_armies("yuan_shao").filter(func(a): return a["units"][kind] > 0)[0]
		scene.camera_target = world.destinations[army.id]
		scene.target_goal = scene.camera_target
		scene.distance = 18
		scene.distance_goal = 18
		scene.pitch = deg_to_rad(43)
		scene._update_camera()
		world._process(0)
		world.advantage_panel.visible = false
		await save(kind+"-formation")
		if kind == "cavalry":
			var riders = world.formations[army.id].get_node("Mounted/Cavalry")
			world._set_pose(riders,9,12,6.0)
			for i in range(12):
				riders.material_override.set_shader_parameter("animation_clock",float(i)/6.0)
				await save("cavalry-attack-%02d" % i)
		if kind == "archers":
			var bows = world.formations[army.id].get_node("Archers")
			world._set_pose(bows,9,12,6.5)
			for i in range(12):
				bows.material_override.set_shader_parameter("animation_clock",float(i)/6.5)
				world.combat_effects.begin_frame()
				world.combat_effects.show_archer_volley(army.id,world.formations[army.id],world.formations[army.id].global_position+world.formations[army.id].basis.z*12.0,float(i)/6.5)
				world.combat_effects.end_frame()
				await save("archer-attack-%02d" % i)
			for distance in [65,130]:
				scene.distance = distance
				scene.distance_goal = distance
				scene._update_camera()
				var target: Vector3 = world.formations[army.id].global_position
				var wall := Vector3.ZERO
				var nearest := INF
				for site in world.Fortifications.sites(store).values():
					var candidate: Vector3 = world._city_wall(site,target)+Vector3.UP*0.65
					if candidate.distance_squared_to(target) < nearest:
						wall = candidate
						nearest = candidate.distance_squared_to(target)
				world.combat_effects.begin_frame()
				world.combat_effects.end_frame()
				await save("city-%d-baseline" % distance)
				for i in range(12):
					world.combat_effects.begin_frame()
					world.combat_effects.show_city_volley("far-check",wall,target,0.28+float(i)/12.0)
					world.combat_effects.end_frame()
					await save("city-%d-%02d" % [distance,i])
					if i == 6:
						var arrow = world.combat_effects.contacts["city:far-check"]["arrows"][0]
						print("CITY_ARROW_SCREEN ",distance," position=",scene.camera.unproject_position(arrow.global_position)," scale=",arrow.scale," visible=",arrow.visible)
	store.prepare_battle_test(true,"siege_assault",42)
	store.time_paused = true
	world.refresh()
	world.presenting = false
	for id in world.formations: world.formations[id].position = world.destinations[id]
	var army = store.war.active_armies("yuan_shao").filter(func(a): return int(a.get("siege_engines",0)) > 0)[0]
	scene.camera_target = world.destinations[army.id]+Vector3(0,0,2)
	scene.target_goal = scene.camera_target
	scene.distance = 24
	scene.distance_goal = 24
	scene.pitch = deg_to_rad(38)
	scene._update_camera()
	world._process(0)
	world.advantage_panel.visible = false
	var equipment = world.formations[army.id].get_node("SiegeEngines")
	for i in range(12):
		Siege.animate(equipment,float(i)/6,true,false)
		world.combat_effects.begin_frame()
		world.combat_effects.show_siege_projectiles(army.id,equipment,equipment.global_position+Vector3(0,0,14),float(i)/6.0)
		world.combat_effects.end_frame()
		await save("siege-%02d" % i)
	for day in range(50):
		await store.war.step()
		if store.war.active_armies("yuan_shao").any(func(a): return a.has("tactical") and world.Fortifications.distance_to_wall(store.war.state["battlefield"],"xiaopei",int(a["tactical"]["cell"])) == 1): break
	world.refresh()
	world.presenting = false
	for id in world.formations: world.formations[id].position = world.destinations[id]
	var site: Dictionary = world.Fortifications.for_city(store,"xiaopei")
	scene.camera_target = scene.city_nodes[site["render_id"]].global_position
	scene.target_goal = scene.camera_target
	scene.distance = 48
	scene.distance_goal = 48
	scene.pitch = deg_to_rad(48)
	scene._update_camera()
	world._process(0)
	world.advantage_panel.visible = false
	if not scene.hex_world.enabled: scene.hex_world.toggle()
	await save("city-wall-contact")
	print("CITY_WALL_CONTACT_CAPTURE tick=",store.war.state["tick"]," siege=",store.war.state.get("sieges",{}).get("xiaopei",{}).get("phase","approach"))
	print("TROOP_SIEGE_REVISION_CAPTURE_OK cavalry riders, blue archers, native siege cycles")
	quit()
