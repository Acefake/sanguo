extends SceneTree
const Tactical = preload("res://scripts/war/tactical_battlefield.gd")
var output := "res://docs/validation/textures-and-pressure-2026-10-06/"
var scene
var world
var store
func _initialize() -> void: call_deferred("run")
func capture(name: String, distance: float, center: Vector3) -> void:
	world.refresh()
	world.presenting = false
	for id in world.formations: world.formations[id].position = world.destinations[id]
	scene.camera_target = center
	scene.target_goal = center
	scene.distance = distance
	scene.distance_goal = distance
	scene.pitch = deg_to_rad(38)
	scene._update_camera()
	world._process(0)
	world.advantage_panel.visible = false
	for frame in range(5): await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(output+name+".png")
func run() -> void:
	root.size = Vector2i(1600,900)
	store = root.get_node("GameState")
	store.persist_enabled = false
	store.agent.enabled = false
	store.prepare_battle_test(true,"siege_assault",42)
	scene = load("res://scenes/rtk14_world_3d.tscn").instantiate()
	root.add_child(scene)
	while not scene.loaded: await process_frame
	# Let the deferred initial battlefield focus finish before setting close cameras.
	for frame in range(4): await process_frame
	scene.set_process(false)
	world = scene.army_world
	world.set_process(false)
	store.time_paused = true
	for canvas in scene.find_children("*","CanvasLayer",true,false): canvas.visible = false
	world.layer.visible = true
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output))
	world.refresh()
	for unit in store.war.active_armies():
		if int(unit.get("siege_engines",0)) == 0: continue
		var parts = world.formations[unit.id].get_node("SiegeEngines").find_children("*","MeshInstance3D",true,false)
		var materials := 0
		for part in parts:
			assert(part.material_override == null,"Tower texture overridden")
			for surface in range(part.mesh.get_surface_count()):
				var material = part.get_active_material(surface)
				assert(material.albedo_texture != null and material.normal_texture != null,"Native tower texture missing")
				materials += 1
		assert(materials >= 12)
		await capture("infantry-and-towers",16,world.destinations[unit.id])
	store.prepare_battle_test(true,"plains_clash",42)
	store.time_paused = true
	var war = store.war
	war.rules["duel"]["enabled"] = false
	var corps: Dictionary = war.state["corps"][war.active_armies("liu_bei")[0]["corps_id"]]
	var own: Dictionary = war.state["armies"][corps["root_id"]]
	var enemy: Dictionary = war.active_armies("yuan_shao").filter(func(a): return a["units"]["archers"] > 0)[0]
	for unit in war.active_armies():
		if unit.id not in [own.id,enemy.id]: unit["status"] = "ended"
	var board: Dictionary = war.state["battlefield"]
	own["units"] = {"infantry":2000,"archers":0,"cavalry":0}
	enemy["units"] = {"infantry":0,"archers":1000,"cavalry":0}
	own["tactical"]["cell"] = Tactical.offset_cell(board,0,-2)
	enemy["tactical"]["cell"] = Tactical.offset_cell(board,0,0)
	own["action"] = {"type":"hold"}
	enemy["action"] = {"type":"engage","enemy":own.id}
	war._observe_all()
	war._resolve_contacts({})
	world.refresh()
	var center: Vector3 = (world.destinations[own.id]+world.destinations[enemy.id])*0.5
	await capture("under-fire-two-hexes",40,center)
	for formation in war.state["corps"].values(): formation["last_plan"] = 999
	await war.step()
	assert(Tactical.distance(own,enemy) == 1 and own["action"]["type"] == "engage")
	world.refresh()
	center = (world.destinations[own.id]+world.destinations[enemy.id])*0.5
	await capture("advance-and-counterattack",40,center)
	print("TEXTURES_AND_PRESSURE_RENDER_OK native tower materials, two-hex fire -> one-hex counterattack")
	quit()
