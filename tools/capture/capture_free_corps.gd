extends SceneTree

func _initialize() -> void: call_deferred("run")
func run() -> void:
	root.size = Vector2i(1280, 900)
	var store: Node = root.get_node("GameState")
	store.persist_enabled = false
	store.agent.enabled = false
	store._load_demo()
	store.city_state("luoyang").merge({"faction": "liu_bei", "garrison": 30000, "units": {"infantry": 30000, "archers": 0, "cavalry": 0}}, true)
	var view = preload("res://scripts/war/ui/dispatch_view.gd").new()
	view.store = store
	view.target = "hongnong"
	view.home_hint = "luoyang"
	root.add_child(view)
	await process_frame
	var chosen: Array = []
	var chief: String = view.selection(view.chiefs)
	for id in view.checks:
		var selected: bool = id != chief and chosen.size() < 9
		view.checks[id].set_pressed_no_signal(selected)
		if selected: chosen.append(id)
	view.refresh(true)
	for index in range(chosen.size()):
		view.composition[chosen[index]] = {"role": "帐下都督" if index == 0 else "游击校尉" if index < 3 else "军师" if index == 3 else "部将", "parent": chosen[index-1] if index > 0 and index < 3 else chief, "strength": 0 if index == 3 else 1500}
	view.refresh()
	await process_frame
	await process_frame
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		var path: String = "res://orchestration/runs/2026-10-11-free-corps-continuation/free-corps-dispatch.png"
		root.get_texture().get_image().save_png(path)
		print("FREE_CORPS_SCREENSHOT ", path)
	var plan: Dictionary = view.current_plan()
	assert(plan["members"].size() > 5)
	assert(not view.confirm.disabled)
	view.deploy()
	var corps: Dictionary = store.war.state["corps"].values()[-1]
	assert(corps["members"].size() == chosen.size() + 1)
	assert(corps["appointments"][chosen[0]] == "帐下都督")
	assert(preload("res://scripts/war/campaign/corps_structure.gd").depth_of(corps, chosen[2]) == 3)
	print("FREE_CORPS_UI_OK: free roles, nested superiors and per-node troops deployed through actual dispatch UI")
	quit()
