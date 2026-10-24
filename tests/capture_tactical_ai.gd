extends SceneTree

const Brain = preload("res://scripts/agents/unit_brain.gd")
const Eval = preload("res://scripts/agents/tactical_evaluator.gd")
const Commit = preload("res://scripts/agents/decision_commit.gd")
const Roles = preload("res://scripts/war/battle/troop_roles.gd")
var directory := "res://docs/validation/tactical-ai-2026-10-09/"
var evidence: Array = []

func _initialize() -> void: call_deferred("run")

func shot(name: String, store) -> void:
	for frame in range(3): await process_frame
	await RenderingServer.frame_post_draw
	assert(root.get_texture().get_image().save_png(directory+name+".png") == OK)
	evidence.append({"image":name,"round":store.war.state["battle_round"],"winner":store.war.state["battlefield"].get("winner","")})

func animate(world, duration: float) -> void:
	for frame in range(12):
		world._process(duration/12)
		await process_frame

func run() -> void:
	var store: Node = root.get_node("GameState")
	store.persist_enabled = false
	var original_enabled: bool = store.agent.enabled
	store.agent.enabled = false
	store.prepare_battle_test(false,"plains_clash",101)
	var scene: Node3D = load("res://scenes/rtk14_world_3d.tscn").instantiate()
	root.add_child(scene)
	current_scene = scene
	while not scene.loaded: await process_frame
	scene.set_process(false)
	var world = scene.army_world
	world.set_process(false)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory))
	for scenario in ["plains_clash","mountain_pass","siege_assault","hill_contest"]:
		store.prepare_battle_test(false,scenario,101)
		store.war.rules["duel"]["enabled"] = false
		for day in range(8):
			var before := {}
			for army in store.war.active_armies(): before[army["id"]] = army["location"].duplicate(true)
			await store.war.step()
			store.time_paused = false
			world.begin_day(before)
			await animate(world,world.presentation_duration+0.1)
		var army: Dictionary = store.war.active_armies("liu_bei")[1] if not store.war.active_armies("liu_bei").is_empty() else store.war.active_armies()[0]
		world.ui._refresh_status()
		assert(world.ui.scenario_picker.text.contains(store.war.state["battlefield"]["scenario_name"]))
		world.focus_army(army["id"])
		world.ui.inspector.expanded = true
		world.ui.inspector.judgment.max_lines_visible = -1
		world.ui.inspector.update_info()
		var center: Vector2 = store.war.Tactical.world_cell(army["tactical"]["cell"])
		scene.camera_target = Vector3(center.x,scene.height_at(center.x,center.y),center.y)
		scene.target_goal = scene.camera_target
		scene.distance = 70
		scene.distance_goal = 70
		scene.pitch = deg_to_rad(48)
		scene._update_camera()
		world._process(0)
		world.ui.drawer_scroll.scroll_vertical = 800
		await shot(scenario,store)
		assert(not world.ui.inspector.judgment.text.contains("□□"))
		world.ui.show_army_orders(army["id"])
		if scenario == "plains_clash": await shot("orders",store)
		world.ui.drawer.hide()
	# Declared local safety fixture: lower the bow unit's organization, keeping its
	# body and campaign entity alive; show preparation, movement and recovery.
	store.prepare_battle_test(false,"plains_clash",42)
	store.war.rules["duel"]["enabled"] = false
	for day in range(5): await store.war.step()
	var bow: Dictionary = store.war.active_armies("liu_bei").filter(func(a): return Roles.kind(a) == "archers")[0]
	bow["organization"] = 5.0
	bow["morale"] = 40.0
	bow["fatigue"] = 95.0
	bow["battle_ai"]["submitted_round"] = -1
	var context := Brain.context(store.war,bow)
	Commit.apply(store.war,context,Eval.choose(context))
	store.war.Tactical.move(store.war)
	world.refresh()
	world.focus_army(bow["id"])
	world.ui.inspector.judgment.max_lines_visible = -1
	world.ui.inspector.update_info()
	assert(bow["battle_ai"]["plan"]["template"] == "rally" and not bow["returning"])
	var point: Vector2 = store.war.Tactical.world_cell(bow["tactical"]["cell"])
	scene.camera_target = Vector3(point.x,scene.height_at(point.x,point.y),point.y)
	scene.target_goal = scene.camera_target
	scene._update_camera()
	world._process(0)
	world.ui.drawer_scroll.scroll_vertical = 800
	await shot("local-rally",store)
	world.ui.drawer.hide()
	# Play two unchanged scenario armies to their actual objective settlements.
	for scenario in ["hill_contest","siege_assault"]:
		store.prepare_battle_test(false,scenario,101)
		store.war.rules["duel"]["enabled"] = false
		var completed := false
		for day in range(240):
			var before := {}
			for army in store.war.active_armies(): before[army["id"]] = army["location"].duplicate(true)
			await store.war.step()
			store.time_paused = false
			world.begin_day(before)
			await animate(world,world.presentation_duration+0.1)
			if day % 15 == 0: await shot(scenario+"-round-%03d" % (day+1),store)
			if store.war.state["battlefield"].has("winner"):
				completed = true
				break
		assert(completed,"Scenario did not reach a real settlement")
		world.ui.show_battle_summary()
		await shot(scenario+"-settlement",store)
		world.ui.drawer.hide()
	FileAccess.open(directory+"evidence.json",FileAccess.WRITE).store_string(JSON.stringify({"captures":evidence,"fixture":"Local rally changes own organization/fatigue only. Duels disabled solely to isolate tactical visual verification; 48 headless cases retain normal rules."},"\t"))
	store.restore_battle_test()
	store.agent.enabled = original_enabled
	print("TACTICAL_VISUAL_OK ",evidence.size())
	quit()
