extends SceneTree
const World = preload("res://scripts/war/army_world_3d.gd")
func _initialize(): call_deferred("run")
func expected_count(world, army_id: String, kind: String) -> int:
	var group: Node3D = world.formations[army_id]
	var level: int = int(group.get_meta("detail_level",0))
	var army: Dictionary = world.store.war.state["armies"].get(army_id,{})
	var ratio := 1.0
	if float(army.get("initial_strength",0)) > 0.0:
		ratio = clampf(float(world.store.war.Combat.strength(army)) / float(army["initial_strength"]),0.0,1.0)
	return World.density_for_strength(int(World.density_counts(kind)[level]),ratio)
func run():
	root.size = Vector2i(1280,720)
	var store = root.get_node("GameState")
	store.persist_enabled = false
	store.prepare_battle_test(true,"plains_clash",42)
	var war = store.war
	var armies: Array = war.active_armies("liu_bei")
	var bow: Dictionary = armies[1]
	var cavalry: Dictionary = armies[2]
	bow.units = {"infantry":0,"archers":2000,"cavalry":0}
	cavalry.units = {"infantry":0,"archers":0,"cavalry":2000}
	bow.initial_strength = 2000
	cavalry.initial_strength = 2000
	var enemy: Dictionary = war.active_armies("yuan_shao")[1]
	bow.tactical.cell = war.Tactical.offset_cell(war.state.battlefield,0,0)
	cavalry.tactical.cell = war.Tactical.offset_cell(war.state.battlefield,2,0)
	enemy.tactical.cell = war.Tactical.offset_cell(war.state.battlefield,0,2)
	bow.combat_tick = war.state.tick
	bow.tactical.attack_target = enemy.id
	bow.tactical.phase = "远射"
	bow.formation_locked = false
	var scene = load("res://scenes/rtk14_world_3d.tscn").instantiate()
	root.add_child(scene)
	while not scene.loaded: await process_frame
	for frame in range(4): await process_frame
	var world = scene.army_world
	world._apply_troop_detail(world.formations[bow.id])
	world._apply_troop_detail(world.formations[cavalry.id])
	assert(world.formations[bow.id].get_node("Archers").multimesh.visible_instance_count == expected_count(world,bow.id,"archers"))
	assert(world.formations[cavalry.id].get_node("Mounted/Cavalry").multimesh.visible_instance_count == expected_count(world,cavalry.id,"cavalry"))
	var bow_full: int = world.formations[bow.id].get_node("Archers").multimesh.visible_instance_count
	var horse_full: int = world.formations[cavalry.id].get_node("Mounted/Cavalry").multimesh.visible_instance_count
	bow.units.archers = 10
	cavalry.units.cavalry = 10
	world.refresh()
	world._apply_troop_detail(world.formations[bow.id])
	world._apply_troop_detail(world.formations[cavalry.id])
	assert(world.formations[bow.id].get_node("Archers").multimesh.visible_instance_count < bow_full,"Casualties did not thin the archer formation")
	assert(world.formations[bow.id].get_node("Archers").multimesh.visible_instance_count > 0,"Thinned archer formation vanished")
	assert(world.formations[cavalry.id].get_node("Mounted/Cavalry").multimesh.visible_instance_count < horse_full,"Casualties did not thin the cavalry formation")
	assert(war.Combat.strength(bow) == 10 and war.Combat.strength(cavalry) == 10,"Display thinning changed the real strength")
	bow.units.archers = 2000
	cavalry.units.cavalry = 2000
	world.refresh()
	world._apply_troop_detail(world.formations[bow.id])
	world._apply_troop_detail(world.formations[cavalry.id])
	var center: Vector3 = world.formations[bow.id].position.lerp(world.formations[cavalry.id].position,.5)
	scene.camera_target = center; scene.target_goal = center
	scene.distance = 32; scene.distance_goal = 32
	scene.pitch = deg_to_rad(42)
	scene._update_camera()
	world.presenting = true
	world.presentation_elapsed = 0
	store.time_paused = false
	world.animation_time = .95
	for frame in range(3): await process_frame
	store.time_paused = true
	var group: Node3D = world.formations[bow.id]
	assert(group.get_node("Archers").multimesh.visible_instance_count > 0)
	assert(group.get_node("Soldiers").multimesh.visible_instance_count == 0)
	assert(world.formations[cavalry.id].get_node("Mounted/Cavalry").multimesh.visible_instance_count == horse_full)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://docs/validation/troop-types"))
	for frame in range(4):
		world.animation_time = .8 + frame*.15
		world._process(0)
		await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("res://docs/validation/troop-types/map-%02d.png"%frame)
	scene.queue_free()
	await process_frame
	store.restore_battle_test()
	print("TROOP_TYPES_RENDER_OK")
	quit()
