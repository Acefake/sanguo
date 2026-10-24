extends SceneTree

func _initialize() -> void: call_deferred("run")

func run() -> void:
	var store: Node = root.get_node("GameState")
	store.persist_enabled = false
	store._load_demo()
	store.agent.configure({"enabled": false}, false)
	var city: Dictionary = store.city_state("luoyang")
	city["faction"] = "liu_bei"
	city["garrison"] = 10000
	city["grain"] = 0
	city["units"] = {"infantry": 10000, "archers": 0, "cavalry": 0}
	var officer_id := ""
	for officer in store.war.roster.officers.values():
		if officer["name"] == "关羽": officer_id = officer["id"]
	var army: Dictionary = store.war._mobilize(store.war.preview_dispatch("luoyang", "hongnong", officer_id))
	var ui = load("res://scripts/war/ui/campaign_ui.gd").new()
	ui.store = store
	root.add_child(ui)
	ui.show_army(army["id"])
	await process_frame
	assert(not ui.inspector.grain.visible)
	await save("res://docs/validation/no-supply-army.png")
	ui.show_dispatch("hongnong")
	await save("res://docs/validation/no-supply-dispatch.png")
	print("NO_SUPPLY_UI: PASS")
	quit()

func save(path: String) -> void:
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	assert(root.get_texture().get_image().save_png(path) == OK)
