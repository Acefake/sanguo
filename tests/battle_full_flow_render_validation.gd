extends SceneTree

# Replay actual autonomous decisions through the map renderer until settlement.
# Sampled video is accelerated; every intermediate presentation step is rendered.
var failures: Array[String] = []
func _initialize() -> void: call_deferred("run")
func check(ok: bool, message: String) -> void:
	if not ok and not failures.has(message): failures.append(message); push_error(message)
func run() -> void:
	root.size = Vector2i(1280,720)
	var store = root.get_node("GameState")
	store.persist_enabled = false
	store.agent.enabled = false
	store.prepare_battle_test(false,"plains_clash",42)
	store.time_paused = true
	var scene = load("res://scenes/rtk14_world_3d.tscn").instantiate()
	root.add_child(scene)
	while not scene.loaded: await process_frame
	for frame in range(4): await process_frame
	scene.set_process(false)
	var world = scene.army_world
	world.set_process(false)
	for canvas in scene.find_children("*","CanvasLayer",true,false): canvas.visible = false
	world.layer.visible = true
	var board: Dictionary = store.war.state["battlefield"]
	var point: Vector2 = store.war.Tactical.grid().center(board["anchor"])
	scene.camera_target = Vector3(point.x,scene.height_at(point.x,point.y),point.y)
	scene.target_goal = scene.camera_target
	scene.distance = 78
	scene.distance_goal = 78
	scene._update_camera()
	var note := Label.new()
	note.position = Vector2(20,20)
	note.add_theme_font_override("font",preload("res://scripts/city_ui_skin.gd").font())
	note.add_theme_font_size_override("font_size",22)
	note.add_theme_constant_override("outline_size",6)
	note.add_theme_color_override("font_outline_color",Color.BLACK)
	world.layer.add_child(note)
	var output := "res://docs/validation/battle-full-flow-2026-10-07/"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output))
	var captures := 0
	var days := 0
	var retreats := 0
	var ranged := 0
	var melee := 0
	for day in range(100):
		var before := {}
		for army in store.war.active_armies(): before[army["id"]] = army["location"].duplicate(true)
		await store.war.step(null)
		world.begin_day(before)
		store.time_paused = false
		store.time_scale = 1.0
		note.text = "自主会战  第%d日" % store.war.state["tick"]
		var frames := 0
		while world.presenting and frames < 60:
			world._process(0.10)
			world.advantage_panel.hide()
			for id in world.formations:
				var visual: Dictionary = world._combat_visual(id)
				if not visual.is_empty():
					if visual["ranged"]: ranged += 1
					else: melee += 1
				var army: Dictionary = store.war.state["armies"][id]
				if army["returning"]: retreats += 1
			await process_frame
			if frames%4 == 0:
				await RenderingServer.frame_post_draw
				root.get_texture().get_image().save_png(output+"frame-%03d.png"%captures)
				captures += 1
			frames += 1
		check(not world.presenting,"A battle day never finishes its animation")
		world._process(0)
		await process_frame
		check(world.formations.size() == store.war.active_armies().size(),"Ended or retreating army markers diverge from live state")
		for id in world.formations:
			check(world._at_display_destination(id),"A displayed army never reaches its actual tile")
			check(world.badges[id].strength == store.war.Combat.strength(store.war.state["armies"][id]),"Displayed casualties diverge from settlement")
		for side in store.war.Feedback.snapshot(store.war): check(side["initial"] == side["accounted"],"Rendered battle loses troop accounting")
		days += 1
		print("FULL_FLOW_DAY ",days," active=",world.formations.size()," winner=",board.get("winner","ongoing"))
		if board.has("winner"): break
	check(board.has("winner") and retreats > 0 and ranged > 0 and melee > 0,"Autonomous rendered battle misses combat, retreat or outcome")
	store.time_paused = true
	world._process(0)
	await process_frame
	world.combat_effects.begin_frame()
	world.combat_effects.end_frame()
	await process_frame
	check(world.combat_effects.contacts.is_empty() and world.combat_effects.projectiles.is_empty() and world.combat_effects.target_markers.is_empty(),"Finished battle leaves attack effects behind")
	world.ui.show()
	world.ui.show_battle_summary()
	check(world.ui.visible,"Battle summary canvas stays hidden")
	check(world.ui.reports_view.visible and world.ui.reports_view.mode == "summary","Actual result cannot open battle summary")
	check(store.war.Feedback.summary(store.war)["winner"] == board.get("winner",""),"Summary winner differs from battle outcome")
	note.text = "会战结束  战果结算"
	for frame in range(3): await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(output+"result.png")
	print("BATTLE_FULL_FLOW_RENDER ","PASS" if failures.is_empty() else failures," days=",days," winner=",board.get("winner","")," melee=",melee," ranged=",ranged," retreat=",retreats," captures=",captures)
	quit(0 if failures.is_empty() else 1)
