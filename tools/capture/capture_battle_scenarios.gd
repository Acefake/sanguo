extends SceneTree

const Scenarios = preload("res://scripts/war/battle/battle_scenarios.gd")
var failures: Array = []
var output := "res://docs/validation/battle-scenarios/"

func _initialize() -> void: call_deferred("run")
func check(ok: bool, text: String) -> void:
	if not ok: failures.append(text); push_error(text)

func capture(name: String) -> void:
	for frame in range(5): await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(output + name + ".png")

func activate(control: Control) -> void:
	# Inject window coordinates: Control rectangles are in logical canvas units,
	# while Input.parse_input_event applies the viewport's stretch transform.
	var point := control.get_viewport().get_final_transform() * control.get_global_rect().get_center()
	var motion := InputEventMouseMotion.new()
	motion.position = point
	motion.global_position = point
	Input.parse_input_event(motion)
	await process_frame
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.position = point
		event.global_position = point
		event.pressed = pressed
		Input.parse_input_event(event)
		await process_frame
	await process_frame
	await process_frame

func run() -> void:
	var store: Node = root.get_node("GameState")
	store.persist_enabled = false
	var original_agent: Node = store.agent
	var offline := preload("res://scripts/agents/agent_adapter.gd").new()
	root.add_child(offline)
	store.agent = offline
	store.prepare_battle_test(false, "plains_clash")
	var scene: Node = load("res://scenes/rtk14_world_3d.tscn").instantiate()
	root.add_child(scene)
	current_scene = scene
	while not scene.loaded: await process_frame
	await process_frame
	await process_frame
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output))
	# Locate the selector by its displayed text on the campaign canvas.
	var selector: Button
	for button in scene.army_world.ui.find_children("*", "Button", true, false):
		if button.text.begins_with("战场："): selector = button; break
	check(selector != null, "World battle selector button missing")
	if selector == null: quit(1); return
	await activate(selector)
	if not is_instance_valid(store.battle_picker):
		check(false, "World battle selector signal is not connected")
		quit(1)
		return
	check(store.battle_picker.surface.visible, "World battle selector button does not open picker")
	await capture("selector")
	for spec in Scenarios.definitions():
		var requested := OS.get_cmdline_user_args()
		if not requested.is_empty() and not requested.has(spec["id"]): continue
		store.open_battle_scenarios()
		await activate(store.battle_picker.buttons[spec["id"]])
		check(store.battle_picker.selected == spec["id"], "Scenario selection signal fails")
		await activate(store.battle_picker.launch)
		await process_frame
		scene = current_scene
		while not scene.loaded: await process_frame
		check(store.war.state["battlefield"]["scenario_id"] == spec["id"], "Launch button fails to switch battlefield")
		for day in range(8): await store.war.step(offline)
		scene.army_world.refresh()
		var board: Dictionary = store.war.state["battlefield"]
		var center: Vector2 = store.war.Tactical.world_cell(board["anchor"])
		scene.camera_target = Vector3(center.x, scene.height_at(center.x, center.y), center.y)
		scene.target_goal = scene.camera_target
		scene.distance = float(spec.get("camera_distance", 180))
		scene.distance_goal = scene.distance
		scene._update_camera()
		await capture(spec["id"])
		print("SCENARIO_CAPTURE ", spec["id"])
	store.restore_battle_test()
	store.agent = original_agent
	offline.queue_free()
	current_scene.queue_free()
	print("SCENARIO_UI_VALIDATION failures=", failures.size())
	quit(0 if failures.is_empty() else 1)
