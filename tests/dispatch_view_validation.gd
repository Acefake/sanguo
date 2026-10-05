extends SceneTree

func _initialize() -> void: call_deferred("run")

func run() -> void:
	var store: Node = root.get_node("GameState")
	store.persist_enabled = false
	store.war.setup(store)
	var view = preload("res://scripts/war/dispatch_view.gd").new()
	view.store = store
	view.target = "xiaopei"
	if not store.war.graph.places.has(view.target):
		for id in store.war.graph.places:
			if store.city_state(str(id)).get("faction", "") != store.war.state["player_faction"]: view.target = str(id); break
	root.add_child(view)
	await process_frame
	await process_frame
	if view.confirm.disabled:
		push_error("No deployable preview: " + view.resources.text)
		quit(1)
		return
	view.troops.value = maxi(int(store.war.rules["minimum_army"]), int(view.troops.max_value * 0.7))
	var home: String = view.selection(view.sources)
	var before: int = int(store.city_state(home)["garrison"])
	var wanted: int = int(view.troops.value)
	var preview: Dictionary = store.war.preview_dispatch(home, view.selection(view.targets), view.selection(view.chiefs), false, wanted)
	assert(preview["ok"] and preview["strength"] == wanted)
	assert(store.city_state(home)["garrison"] == before)
	assert(view.radar.values.size() == 5)
	if not DisplayServer.get_name() == "headless":
		await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("res://docs/validation/army-assets/dispatch-view.png")
	var layout: Dictionary = store.war.Corps.preview_appointments(store.war, view.selection(view.chiefs), view.members(), wanted)
	view.deploy()
	var corps: Dictionary = store.war.state["corps"].values()[-1]
	assert(corps["appointments"] == layout["appointments"])
	assert(corps["units"].size() == layout["formations"].size())
	assert(store.city_state(home)["garrison"] == before - wanted)
	print("DISPATCH_VIEW_OK: pure preview, troop selection, radar, actual corps deployment")
	quit()

