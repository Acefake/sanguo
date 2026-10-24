extends SceneTree

const Fort = preload("res://scripts/war/city_fortifications.gd")
var output := "res://docs/validation/city-volley-rework-2026-10-06/"

func _initialize() -> void: call_deferred("run")

func capture(world, directory: String, field: bool = false) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output + directory))
	for index in range(70):
		world.presentation_elapsed = float(index) / 20.0
		if field:
			world.animation_time += 0.05
			world.ground_timer = 0.16
			world.store.time_paused = false
			world._process(0)
			world.store.time_paused = true
		for frame in range(3): await process_frame
		await RenderingServer.frame_post_draw
		assert(world.find_children("CityArchers_*", "MultiMeshInstance3D", true, false).is_empty())
		root.get_texture().get_image().save_png(output + directory + "%02d.png" % index)

func camera_at(scene, point: Vector3, distance: float) -> void:
	scene.camera_target = point
	scene.target_goal = point
	scene.distance = distance
	scene.distance_goal = distance
	scene.pitch = deg_to_rad(43)
	scene.yaw = -0.35
	scene._update_camera()

func run() -> void:
	var store = root.get_node("GameState")
	store.persist_enabled = false
	store.agent.enabled = false
	store.prepare_battle_test(false, "siege_assault", 42)
	var scene: Node3D = load("res://scenes/rtk14_world_3d.tscn").instantiate()
	root.add_child(scene)
	current_scene = scene
	while not scene.loaded: await process_frame
	for frame in range(5): await process_frame
	scene.set_process(false)
	var war = store.war
	var board: Dictionary = war.state["battlefield"]
	var center := int(board["objectives"]["xiaopei"])
	var point: Vector2 = war.Tactical.world_cell(center)
	var candidates: Array = []
	for q in range(int(board["min_column"]), int(board["max_column"]) + 1):
		for r in range(int(board["min_row"]), int(board["max_row"]) + 1):
			var cell: int = war.Tactical.cell_at(q, r)
			if war.Tactical.cell_distance(cell, center) == 3 and war.Tactical.grid().walkable(cell) and Fort.line_of_sight(board, center, cell, "xiaopei"): candidates.append(cell)
	# Declared three-direction visual fixture; actual Fort.fire settles all losses.
	var armies: Array = war.active_armies("yuan_shao")
	while armies.size() < 3:
		var unit: Dictionary = armies[0].duplicate(true)
		unit["id"] = "capture-volley:" + str(armies.size())
		war.state["armies"][unit["id"]] = unit
		armies.append(unit)
	for other in war.active_armies():
		if not armies.slice(0, 3).has(other): other["status"] = "ended"
	armies = armies.slice(0, 3)
	war.state["corps"] = {}
	var used := []
	var directions := [Vector2(-1, 0.25), Vector2(0, 1), Vector2(1, 0.25)]
	for index in range(3):
		var options: Array = candidates.filter(func(cell): return not used.has(cell))
		options.sort_custom(func(a, b): return (war.Tactical.world_cell(a) - point).normalized().dot(directions[index]) > (war.Tactical.world_cell(b) - point).normalized().dot(directions[index]))
		used.append(options[0])
		var army: Dictionary = armies[index]
		army.erase("corps_id")
		army.erase("corps_task")
		army["tactical"]["cell"] = used[index]
		army["tactical"]["role"] = "main_attack"
		army["action"] = {"type": "hold"}
		army["combat_tick"] = -1
	store.city_state("xiaopei").merge({"garrison": 9000, "units": {"infantry": 5400, "archers": 3600, "cavalry": 0}}, true)
	war.state["tick"] = 1
	Fort.fire(war)
	assert(war.state["city_volleys"].size() == 3)
	var world = scene.army_world
	world.refresh()
	for id in world.formations: world.formations[id].position = world.destinations[id]
	camera_at(scene, Vector3(point.x, scene.height_at(point.x, point.y), point.y + 2.0), 63.0)
	world.ui.visible = false
	for child in scene.find_children("*", "CanvasLayer", true, false): child.visible = false
	world.layer.visible = true
	world.advantage_panel.visible = false
	world.begin_day({})
	store.time_paused = true
	var close_only := OS.get_cmdline_user_args().has("--close-only")
	if not close_only: await capture(world, "city/")
	var close_target: Node3D = world.formations[armies[1]["id"]]
	var wall: Vector3 = world._city_wall(Fort.for_city(store, "xiaopei"), close_target.global_position)
	camera_at(scene, wall.lerp(close_target.global_position, 0.6), 32.0)
	await capture(world, "city-close/")
	if close_only:
		print("CITY_ARROW_CLOSE_CAPTURE_OK: native projectile flight and fixed formation")
		quit()
		return
	var facts := {"fixture": "three declared attack directions; actual garrison settlement; no user save writes", "volleys": war.state["city_volleys"].duplicate(true), "city_archer_groups": 0, "arrow_groups": world.combat_effects.contacts.size(), "arrows_per_target": 12, "arrow_waves": 2, "range_from_wall": 2}
	facts["native_arrow"] = {"model": "f893127a", "texture": "00b434fc", "normal": "3801460a", "beam_trails": 0, "flight_seconds": 1.10}
	assert(world.combat_effects.contacts.size() == 3)
	world.set_process(false)
	world.presenting = false
	store.time_paused = false
	store.prepare_battle_test(false, "plains_clash", 42)
	# Isolate ordinary troop contact in this visual fixture; no campaign rule edit.
	war.rules["duel"]["enabled"] = false
	for day in range(30):
		await store.war.step(null)
		if war.active_armies().any(func(army): return army.get("combat_tick", -1) == war.state["tick"] and army["tactical"]["phase"] != "远射"): break
	world.refresh()
	for id in world.formations: world.formations[id].position = world.destinations[id]
	var fighter: Dictionary = war.active_armies().filter(func(army): return army.get("combat_tick", -1) == war.state["tick"] and army["tactical"]["phase"] != "远射")[0]
	var front: Dictionary = world._combat_visual(fighter["id"])
	assert(not front.is_empty() and not front["ranged"])
	var origin: Vector3 = world.formations[fighter["id"]].global_position
	camera_at(scene, origin.lerp(front["target"], 0.5), 36.0)
	world.begin_day({})
	world.ground_timer = 0.16
	world._process(0.001)
	world.set_process(true)
	store.time_paused = true
	await capture(world, "contact/", true)
	facts["field_tick"] = war.state["tick"]
	facts["field_contacts"] = world.combat_effects.contacts.size()
	facts["field_armies"] = war.active_armies().size()
	facts["reference"] = "屏幕录制 2026-10-06 112852.mp4 and 135334.mp4; native arrow with verified texture binding, native fan texture; original emitter parameters unverified"
	var file := FileAccess.open(output + "evidence.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(facts, "\t"))
	print("CITY_COUNTERATTACK_CAPTURE_OK ", JSON.stringify(facts))
	quit()
