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
	city["units"] = {"infantry": 10000, "archers": 0, "cavalry": 0}
	var members: Array = []
	for officer in store.war.roster.officers.values():
		if officer["faction"] == "liu_bei": members.append(officer["id"])
	assert(members.size() >= 6)
	var army: Dictionary = store.war._mobilize(store.war.preview_dispatch("luoyang", "hongnong", members[0]))
	var corps: Dictionary = store.war.Corps.form(store.war, army, members)
	var ui = load("res://scripts/war/ui/campaign_ui.gd").new()
	ui.store = store
	root.add_child(ui)
	ui.show_army(army["id"])
	await process_frame
	for role in ["主帅", "前锋", "护军", "参军"]: assert(role in ui.inspector.personnel.text)
	for id in corps["members"]: assert(store.war.roster.officers[id]["name"] in ui.inspector.personnel.text)
	assert_no_dots(ui)
	await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://docs/validation/six-member-corps-personnel.png")
	ui.show_army_orders(army["id"])
	var found := false
	for child in ui.body.get_children():
		if child is Label and "参军" in child.text: found = true
	assert(found)
	assert_no_dots(ui)
	ui.show_dispatch("hongnong")
	await process_frame
	assert(ui.companion_checks.values().filter(func(c): return c.button_pressed).size() <= 5)
	assert_no_dots(ui)
	var dispatch = preload("res://scripts/war/ui/dispatch_view.gd").new()
	dispatch.store = store
	dispatch.target = "hongnong"
	root.add_child(dispatch)
	await process_frame
	assert(dispatch.members().size() <= 5)
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://docs/validation/six-member-corps-dispatch.png")
	print("CORPS_PERSONNEL_UI: PASS")
	quit()

func assert_no_dots(node: Node) -> void:
	if node is Label or node is BaseButton:
		assert(not "·" in node.text and not "•" in node.text and not "・" in node.text)
	if node is Control: assert(not "·" in node.tooltip_text)
	for child in node.get_children(): assert_no_dots(child)
