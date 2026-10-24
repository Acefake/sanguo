extends SceneTree

const World = preload("res://scripts/war/presentation/army_world_3d.gd")
var output := "res://docs/validation/reference-troops-2026-10-06/"
func _initialize() -> void: call_deferred("run")

func run() -> void:
	root.size = Vector2i(1600,900)
	var store = root.get_node("GameState")
	store.persist_enabled = false
	store.agent.enabled = false
	store.prepare_battle_test(true,"plains_clash",42)
	var war = store.war
	war.rules["duel"]["enabled"] = false
	var own: Array = war.active_armies("liu_bei")
	var infantry: Dictionary = own[1]
	var cavalry: Dictionary = own[2]
	for army in war.active_armies():
		if army.id not in [infantry.id,cavalry.id]: army.status = "ended"
	infantry.units = {"infantry":4000,"archers":0,"cavalry":0}
	infantry.initial_strength = 4000
	cavalry.units = {"infantry":0,"archers":0,"cavalry":4000}
	cavalry.initial_strength = 4000
	infantry.tactical.cell = war.Tactical.offset_cell(war.state.battlefield,-1,0)
	cavalry.tactical.cell = war.Tactical.offset_cell(war.state.battlefield,1,0)
	var scene = load("res://scenes/rtk14_world_3d.tscn").instantiate()
	root.add_child(scene)
	while not scene.loaded: await process_frame
	for frame in range(4): await process_frame
	scene.set_process(false)
	var world = scene.army_world
	world.set_process(false)
	var left: Node3D = world.formations[infantry.id]
	var right: Node3D = world.formations[cavalry.id]
	left.basis = Basis.IDENTITY
	right.basis = Basis.IDENTITY
	var point: Vector3 = left.position.lerp(right.position,.5)
	scene.camera_target = point
	scene.target_goal = point
	scene.distance = 23
	scene.distance_goal = 23
	scene.pitch = deg_to_rad(35)
	scene.yaw = 0
	scene._update_camera()
	for canvas in scene.find_children("*","CanvasLayer",true,false): canvas.visible = false
	world.layer.visible = true
	world.advantage_panel.visible = false
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output))
	store.time_paused = true
	var foot: MultiMeshInstance3D = left.get_node("Soldiers")
	var mounted: MultiMeshInstance3D = right.get_node("Mounted/Cavalry")
	world.animation_time = 0.0
	world._apply_troop_detail(left)
	world._apply_troop_detail(right)
	assert(foot.multimesh.visible_instance_count == World.density_counts("infantry")[0] and mounted.multimesh.visible_instance_count == World.density_counts("cavalry")[0])
	for i in range(80):
		world.animation_time = i*.05
		world._set_pose(foot,9,12,6.5)
		world._set_pose(mounted,9,12,6.0)
		world._process(0)
		for frame in range(2): await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(output+"%02d.png"%i)
	print("REFERENCE_TROOPS_CAPTURE_OK: fixed 64 infantry and 36 mounted native meshes, recovered attack motion, torso badges")
	quit()
