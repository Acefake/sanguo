extends SceneTree
const Fate = preload("res://scripts/war/officer_fate.gd")
var output := "res://docs/validation/officer-fate/"
func _initialize(): call_deferred("run")
func capture(name: String):
	for i in range(5): await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(output + name + ".png")
func run():
	var store = root.get_node("GameState")
	store.persist_enabled = false
	store.prepare_battle_test(true, "plains_clash")
	var offline = preload("res://scripts/agents/agent_adapter.gd").new()
	root.add_child(offline)
	var war = store.war
	war.rules["duel"]["enabled"] = false
	for day in range(8): await war.step(offline)
	var a: Dictionary = war.active_armies("liu_bei")[1]
	var b: Dictionary = war.active_armies("yuan_shao")[1]
	a["tactical"]["cell"] = war.Tactical.offset_cell(war.state["battlefield"], 0, 0)
	b["tactical"]["cell"] = war.Tactical.neighbors(a["tactical"]["cell"])[0]
	a["action"] = {"type":"engage"}; b["action"] = {"type":"engage"}
	a["formation_locked"] = false; b["formation_locked"] = false
	war.state["tick"] += 1
	war.Tactical.resolve(war)
	var scene = load("res://scenes/rtk14_world_3d.tscn").instantiate()
	root.add_child(scene)
	while not scene.loaded: await process_frame
	store.time_paused = true
	var center: Vector3 = scene.army_world.formations[a["id"]].position
	scene.camera_target = center; scene.target_goal = center
	scene.distance = 80; scene.distance_goal = 80
	scene._update_camera()
	scene.army_world.refresh()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output))
	scene.army_world.ui.show_army(a["id"])
	# Let the initial deferred battlefield focus complete before framing the unit.
	for frame in range(3): await process_frame
	scene.distance = 54; scene.distance_goal = 54
	scene.camera_target = center; scene.target_goal = center
	scene._update_camera()
	scene.army_world._spawn_loss_floaters()
	await capture("head-numbers")
	# Formal fog provides estimated enemy entries without officer IDs.
	store.battle_test = false
	war._observe_all()
	scene.army_world.refresh()
	await capture("fog-heads")
	store.battle_test = true
	scene.army_world.refresh()
	war._report(a, "战绩", "主将亲自杀敌与部队杀敌分列。", true)
	var report: Dictionary = war.state["reports"][-1]
	report["delivery_tick"] = war.state["tick"]
	war._deliver_reports()
	scene.army_world.ui.reports_view.open(a["id"])
	scene.army_world.ui.reports_view.select_report(report["id"])
	await capture("battle-report-kills")
	var opponents: Array = war.active_armies("yuan_shao").filter(func(unit): return not Fate.unavailable(war, str(unit["officer_id"])))
	if opponents.size() >= 2:
		Fate.settle(war, opponents[0], a, "dead", "单挑落败（验证样例）")
		Fate.settle(war, opponents[1], a, "captured", "单挑落败（验证样例）")
	scene.army_world.ui.reports_view.open()
	scene.army_world.ui.reports_view.show_summary()
	for i in range(3): await process_frame
	scene.army_world.ui.reports_view.detail_scroll.scroll_vertical = 320
	await capture("fates-ledger")
	var reports = scene.army_world.ui.reports_view
	for button in reports.detail.find_children("*", "Button", true, false):
		if not button.text.begins_with("释放 "): continue
		reports.detail_scroll.scroll_vertical += int(button.get_global_rect().position.y - reports.detail_scroll.get_global_rect().position.y - 180)
		for i in range(3): await process_frame
		var point: Vector2 = button.get_global_rect().get_center()
		var motion := InputEventMouseMotion.new()
		motion.position = point
		Input.parse_input_event(motion)
		for pressed in [true, false]:
			var event := InputEventMouseButton.new()
			event.button_index = MOUSE_BUTTON_LEFT
			event.position = point
			event.pressed = pressed
			Input.parse_input_event(event)
			await process_frame
		break
	if not war.state["officer_fates"].values().any(func(fate): return fate["status"] == "released"):
		push_error("Prisoner release button did not settle release")
		quit(1)
		return
	await capture("prisoner-release")
	scene.queue_free()
	await process_frame
	store.restore_battle_test()
	print("OFFICER_FATE_CAPTURE_OK")
	quit()
