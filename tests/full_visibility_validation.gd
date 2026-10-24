extends SceneTree

const Brain = preload("res://scripts/agents/unit_brain.gd")
var failures: Array[String] = []

func _initialize() -> void: call_deferred("run")

func check(ok: bool, message: String) -> void:
	if not ok: failures.append(message); push_error(message)

func run() -> void:
	var store: Node = root.get_node("GameState")
	store.persist_enabled = false
	store.agent.enabled = false
	store.prepare_battle_test(true, "plains_clash", 42)
	var war = store.war
	war._observe_all()
	for army in war.active_armies():
		for enemy in war.active_armies():
			if not war.hostile(str(army["faction"]), str(enemy["faction"])): continue
			var record: Dictionary = army["intel"]["enemies"].get(enemy["id"], {})
			check(not record.is_empty(), "Hostile army missing from full visibility")
			check(int(record.get("strength_estimate", -1)) == war.Combat.strength(enemy), "Enemy strength is not exact")
			check(record.get("location", {}) == enemy["location"] and record.get("unit_mix_estimate", {}) == enemy["units"], "Enemy position or composition is not exact")
		var context := Brain.context(war, army)
		check(not context["candidates"].any(func(c): return c["canonical_plan"]["template"] == "scout"), "Scouting candidate remains")
	var own: Dictionary = war.active_armies("liu_bei")[0]
	var enemy: Dictionary = war.active_armies("yuan_shao")[0]
	var treasury: int = store.city_state(str(own["home"])).get("treasury", 0)
	var points: int = store.action_points
	war.Operations.scout(war, str(own["home"]))
	check(points == store.action_points and treasury == int(store.city_state(str(own["home"])).get("treasury", 0)), "Scouting still consumes resources")
	war.state["armies"][enemy["id"]]["status"] = "ended"
	war._observe_all()
	check(not own["intel"]["enemies"].has(enemy["id"]), "Ended army retained as stale enemy")
	enemy["status"] = "active"
	own["action"] = {"type": "scout"}
	war.setup(store, war.export_state())
	check(war.state["armies"][own["id"]]["action"]["type"] == "hold", "Old scout order did not migrate")
	check(war.state["armies"][own["id"]]["intel"]["enemies"].has(enemy["id"]), "Load did not restore full visibility")
	for city in store.scenario["places"]:
		check(int(war.player_city_intel(str(city))["strength_estimate"]) == int(store.city_state(str(city)).get("garrison", 0)), "City requires reconnaissance")
	if "--capture" in OS.get_cmdline_user_args():
		var scene: Node3D = load("res://scenes/rtk14_world_3d.tscn").instantiate()
		root.add_child(scene)
		current_scene = scene
		while not scene.loaded: await process_frame
		scene.set_process(false)
		store.battle_test = false
		var world = scene.army_world
		world.set_process(false)
		world.refresh()
		check(world.formations.size() == war.active_armies().size(), "Normal mode hides armies")
		for id in world.observed_enemies:
			check(not world.badges[id].estimated, "Enemy badge still shows estimated strength")
		world.focus_army(str(own["id"]))
		scene.camera_target = world.destinations[own["id"]]
		scene.target_goal = scene.camera_target
		scene.distance = 95
		scene.distance_goal = 95
		scene.pitch = deg_to_rad(48)
		scene._update_camera()
		world._process(0)
		world.show_enemy(str(enemy["id"]))
		for frame in range(4): await process_frame
		await RenderingServer.frame_post_draw
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://docs/validation/full-visibility"))
		check(root.get_texture().get_image().save_png("res://docs/validation/full-visibility/world.png") == OK, "Screenshot failed")
		# Rendering must also work when the player has no field observers.
		for army in war.active_armies("liu_bei"): army["status"] = "ended"
		world.refresh()
		check(world.formations.size() == war.active_armies().size() and not world.formations.is_empty(), "Enemy display still requires a player observer")
		store.battle_test = true
	store.restore_battle_test()
	print("FULL_VISIBILITY_OK" if failures.is_empty() else "FULL_VISIBILITY_FAILED " + str(failures))
	quit(0 if failures.is_empty() else 1)
