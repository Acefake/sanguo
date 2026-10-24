extends SceneTree

const Inspector = preload("res://scripts/war/ui/army_inspector.gd")
const UISkin = preload("res://scripts/war/ui/war_ui_skin.gd")
var failures: Array[String] = []
var checks := 0
var output := "res://docs/validation/war-ui/"

class LocalAgent extends Node:
	var model := "ui-local-fixture"
	var last_status := "本地策略"
	var metrics := {"calls":0,"failures":0,"fallbacks":0}
	func choose_batch(contexts: Array) -> Dictionary:
		var answers := {}
		for context in contexts:
			answers[context["request_id"]] = preload("res://scripts/war/campaign/army_corps.gd").fallback(context)
		return answers

func _initialize() -> void: call_deferred("run")
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message); push_error(message)
func capture(file: String) -> void:
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(ProjectSettings.globalize_path(output + file))

func click(button: Button) -> void:
	await process_frame
	var point := button.get_global_rect().get_center()
	var motion := InputEventMouseMotion.new()
	motion.position = point
	Input.parse_input_event(motion)
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point
		event.global_position = point
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		Input.parse_input_event(event)
		await process_frame

func run() -> void:
	var store := root.get_node("GameState")
	store.persist_enabled = false
	store.prepare_battle_test(true)
	var fixture := LocalAgent.new()
	root.add_child(fixture)
	for day in range(5): await store.war.step(fixture)
	var own: Dictionary = {}
	for army in store.war.active_armies("liu_bei"):
		if store.war.roster.officers[army["officer_id"]]["name"] == "关羽": own = army
	if own.is_empty(): own = store.war.active_armies("liu_bei")[0]
	var scene: Node3D = load("res://scenes/rtk14_world_3d.tscn").instantiate()
	root.add_child(scene)
	while not scene.loaded: await process_frame
	var ui: CanvasLayer = scene.army_world.ui
	scene.camera_target = scene.army_world.formations[own["id"]].position
	scene.target_goal = scene.camera_target
	scene.distance = 54
	scene.distance_goal = 54
	scene._update_camera()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output))
	ui.show_army(own["id"])
	await process_frame
	check(ui.drawer.visible and ui.inspector != null, "Army card not opened")
	check(ui.inspector.judgment.get_theme_font_size("font_size") == 13, "Decision body font too large")
	check(ui.inspector.portrait.texture != null, "Officer portrait missing")
	check(ui.inspector.card_morale.size.y == 4, "Plaque morale meter expanded into a thick block")
	check(ui.inspector.attribute_labels.size() == 4, "Plaque attribute layout incomplete")
	await capture("army-inspector.png")
	check(ui.drawer_scroll.get_v_scroll_bar().max_value <= ui.drawer_scroll.size.y + 2, "Default inspector still requires a long scroll")
	var card_id: int = ui.inspector.get_instance_id()
	ui.refresh()
	check(ui.inspector.get_instance_id() == card_id, "Refresh destroys the open card")
	var corps: Dictionary = store.war.state["corps"].get(own.get("corps_id", ""), {})
	var key := "corps:" + str(corps["id"])
	store.war.planner.ready[key] = {"result":{"source":"model","reason_summary":"敌军粮道受威胁，建议前锋维持阵线，奇兵绕后。"},"tick":store.war.state["tick"]}
	ui.inspector.update_info()
	check(ui.inspector.judgment.text.contains("奇兵绕后") and ui.inspector.source.text.contains("待执行"), "Returned model proposal not visible before execution")
	check(ui.inspector.source.text.contains("智能体返回"), "Model proposal source missing")
	await capture("army-inspector-thinking.png")
	store.war.planner.ready.erase(key)
	ui.inspector.update_info()
	await click(ui.inspector.find_child("OpenArmyOrders", true, false))
	check(ui.page == "army_orders" and ui.body.find_child("WithdrawArmy", true, false) != null, "Commands disappeared from their separate page")
	await capture("army-orders.png")
	ui.show_army(own["id"])
	await click(ui.inspector.report_button)
	check(ui.reports_view.visible and not ui.drawer.visible, "Reports not shown in their separate window")
	check(ui.reports_view.filter_army == own["id"], "Army report button lost army filter")
	check(ui.reports_view.entries.all(func(r): return r["army_id"] == own["id"] and r["received"]), "Wrong army or undelivered report exposed")
	await capture("military-reports.png")
	var original_signature: String = ui.reports_view.signature
	store.busy = true
	ui.reports_view.signature = "advance-in-progress"
	ui.reports_view.refresh()
	check(ui.reports_view.signature == "advance-in-progress", "Archive rebuilds during intermediate simulation days")
	ui.reports_view.signature = original_signature
	store.busy = false
	if not ui.reports_view.entries.is_empty():
		var report: Dictionary = ui.reports_view.entries[0]
		check(report["snapshot"].has("wounded") and report["snapshot"].has("organization"), "Detailed report lacks frozen battle figures")
		var troops_before: int = report["snapshot"]["strength"]
		var old_units: Dictionary = own["units"].duplicate()
		own["units"]["infantry"] += 1
		check(report["snapshot"]["strength"] == troops_before, "Report figures follow live army instead of its sent snapshot")
		own["units"] = old_units
	ui.reports_view.kind_filter.select(1)
	ui.reports_view.rebuild()
	check(ui.reports_view.entries.all(func(r): return ui.reports_view._matches(r)), "Report kind filter broken")
	await click(ui.reports_view.summary_tab)
	check(ui.reports_view.mode == "summary", "Summary tab does not switch")
	await capture("battle-ledger.png")
	await click(ui.reports_view.find_child("CloseReports", true, false))
	check(not ui.reports_view.visible, "Report window did not close")
	ui.show_reports()
	ui.reports_view.filter_army = "nonexistent"
	ui.reports_view.rebuild()
	check(ui.reports_view.entries.is_empty(), "Empty-state army filter broken")
	await capture("reports-empty.png")
	scene.queue_free()
	fixture.queue_free()
	await process_frame
	store.restore_battle_test()
	print("WAR_UI_VALIDATION checks=", checks, " failures=", failures.size())
	quit(0 if failures.is_empty() else 1)
