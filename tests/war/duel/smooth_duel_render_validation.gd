extends SceneTree
const Duel = preload("res://scripts/war/duel/duel_system.gd")
var failures: Array[String] = []
func _initialize(): call_deferred("run")
func check(ok: bool, message: String):
	if not ok: failures.append(message); push_error(message)
func run():
	var store = root.get_node("GameState")
	store.persist_enabled = false
	store.prepare_battle_test(true)
	var war = store.war
	var a: Dictionary = war.active_armies("liu_bei")[1]
	var b: Dictionary = war.active_armies("yuan_shao")[1]
	a["tactical"]["cell"] = war.Tactical.offset_cell(war.state["battlefield"],0,0)
	b["tactical"]["cell"] = war.Tactical.neighbors(a["tactical"]["cell"])[0]
	a["action"] = {"type":"engage"}
	b["action"] = {"type":"engage"}
	a["tactical"]["attack_target"] = b["id"]
	b["tactical"]["attack_target"] = a["id"]
	war.rules["duel"]["acceptance"] = 100.0
	var outcome: Dictionary = Duel.challenge(war,a,b,true)
	check(not outcome.is_empty() and outcome.get("result", "refused") != "refused", "Real duel event did not occur")
	a["combat_tick"] = war.state["tick"]
	b["combat_tick"] = war.state["tick"]
	var scene: Node3D = load("res://scenes/rtk14_world_3d.tscn").instantiate()
	root.add_child(scene)
	while not scene.loaded: await process_frame
	await process_frame
	await process_frame
	var world: Node3D = scene.army_world
	world.set_process(false)
	world.ui.drawer.hide()
	var group: Node3D = world.formations[a["id"]]
	var batch: MultiMeshInstance3D = group.get_node("Soldiers")
	var center: Vector3 = group.position.lerp(world.formations[b["id"]].position,0.5)
	scene.camera_target = center
	scene.target_goal = center
	scene.distance = 28
	scene.distance_goal = 28
	scene._update_camera()
	world.begin_day({})
	store.time_paused = false
	store.time_scale = 1.0
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://docs/validation/army-assets/smooth-duel"))
	var max_turn := 0.0
	# Soldier 0's drawn heading in world space; the turn itself runs in army_pose.gdshader.
	var heading := func() -> Basis: return batch.global_basis*world._soldier_transform(group,batch,0).basis.orthonormalized()
	for frame in range(60):
		var before: Basis = heading.call()
		world._process(1.0/30.0)
		var after: Basis = heading.call()
		max_turn = maxf(max_turn,before.z.angle_to(after.z))
		if frame == 15:
			world.refresh()
			check(after.is_equal_approx(heading.call()), "Refresh reset soldier heading")
			check(world.combat_effects.duels.size() == 1,"Duel missing or duplicated")
			check(world.combat_effects.contacts.size() >= 2,"Mutual combat contacts missing")
			var duel: Dictionary = world.combat_effects.duels.values()[0]
			check(duel["portraits"][0].texture != null and duel["portraits"][1].texture != null,"Missing officer portrait")
		if frame == 20:
			store.time_paused = true
			var time: float = world.animation_time
			world._process(0.2)
			check(world.animation_time == time and after.is_equal_approx(heading.call()),"Pause advanced pose or heading")
			store.time_paused = false
		await process_frame
		await RenderingServer.frame_post_draw
		if frame % 2 == 0: root.get_texture().get_image().save_png(ProjectSettings.globalize_path("res://docs/validation/army-assets/smooth-duel/%02d.png" % frame))
	check(max_turn <= 3.5/30.0+0.001,"Facing exceeded smooth angular speed")
	world._process(0.2)
	check(world.combat_effects.duels.is_empty(),"Duel effect was not cleaned up")
	world.begin_day({})
	world._process(0.2)
	check(world.combat_effects.duels.is_empty(),"Same duel replayed on refresh")
	# Target reversal and two fronts must stay bounded, never snap 180 degrees.
	var fronts := [{"target":group.position+Vector3(10,0,0)},{"target":group.position+Vector3(-10,0,0)}]
	for i in range(30):
		var before: Basis = heading.call()
		world.animation_time += 1.0/60
		world._face_contact_sectors(group,fronts,1.0/60)
		check(before.z.angle_to(heading.call().z) <= 3.5/60+0.001,"Multi-front soldier snapped")
	var facing: Basis = heading.call()
	var phase: Color = batch.multimesh.get_instance_custom_data(0)
	world._layout_formation(group, batch.multimesh.visible_instance_count - 1)
	check(facing.is_equal_approx(heading.call()) and phase.is_equal_approx(batch.multimesh.get_instance_custom_data(0)), "Casualty relayout reset heading or animation phase")
	scene.queue_free()
	await process_frame
	store.restore_battle_test()
	print("SMOOTH_DUEL_OK max_turn_degrees=", rad_to_deg(max_turn), " real_duel=",outcome.get("result")," failures=",failures)
	quit(0 if failures.is_empty() else 1)
