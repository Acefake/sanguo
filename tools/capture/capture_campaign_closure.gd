extends SceneTree

var directory := "res://docs/validation/campaign-visual-2026-10-06/"
var captured := {}
var stages: Array = []
func _initialize() -> void: call_deferred("run")
func shot(name: String, war) -> void:
	for frame in range(3): await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(directory + name + ".png")
	stages.append({"image": name, "tick": war.state["tick"], "owner": war.store.city_state("xiaopei").get("faction", ""), "siege": war.state["sieges"].get("xiaopei", {}).duplicate(true)})
func run() -> void:
	var store = root.get_node("GameState")
	store.persist_enabled = false
	store.agent.enabled = false
	store._load_demo()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory))
	var menu = load("res://scenes/battle_start.tscn").instantiate()
	root.add_child(menu)
	await shot("00-战役入口", store.war)
	menu.queue_free()
	await process_frame
	store.war.set_player_faction("yuan_shu")
	# Declared visual fixture: strong departure garrison and a weak city so all
	# real siege stages can be captured without altering the user's saved campaign.
	store.city_state("peiguo").merge({"faction": "yuan_shu", "garrison": 20000, "units": {"infantry": 15000, "archers": 4000, "cavalry": 1000}}, true)
	store.city_state("xiaopei").merge({"garrison": 2200, "units": {"infantry": 1000, "archers": 1200, "cavalry": 0}, "defense": 20}, true)
	store.war.rules["strategy"] = {}
	store.war.start_campaign()
	store.war.state["city_policies"]["xiaopei"] = {"defense": "hold", "rebuild": "balanced", "delegated": false}
	var scene: Node3D = load("res://scenes/rtk14_world_3d.tscn").instantiate()
	root.add_child(scene); current_scene = scene
	while not scene.loaded: await process_frame
	scene.set_process(false)
	var point: Vector2 = store.war.Fortifications.for_city(store, "xiaopei")["point"]
	scene.camera_target = Vector3(point.x, scene.height_at(point.x, point.y), point.y + 10)
	scene.target_goal = scene.camera_target
	scene.distance = 68; scene.distance_goal = 68; scene.pitch = deg_to_rad(43); scene.yaw = -0.35
	scene._update_camera()
	var world = scene.army_world
	world.ui.show_city_policy("peiguo")
	await shot("01-城务与人事", store.war)
	world.ui.drawer.hide()
	scene.selected_city = "xiaopei"
	scene._enter_selected_city()
	await shot("02-敌城只读", store.war)
	assert(scene.city_interior.city_name == "小沛" and not world.ui.visible)
	scene.city_interior._close()
	await process_frame
	assert(scene.city_interior == null and world.ui.visible)
	var chief := ""
	for officer in store.war.available_officers("yuan_shu"):
		if store.war.state["officer_states"].get(officer["id"], {}).get("city", "") == "peiguo": chief = officer["id"]; break
	assert(chief != "")
	var result: Dictionary = store.war.dispatch("peiguo", "xiaopei", chief)
	assert(result["ok"])
	var army: Dictionary = store.war.state["armies"][result["army_id"]]
	for child in scene.find_children("*", "CanvasLayer", true, false): child.visible = false
	for index in range(100):
		await store.war.step()
		world.refresh()
		for id in world.formations: world.formations[id].position = world.destinations[id]
		world.begin_day({})
		store.time_paused = true
		world.presentation_elapsed = 0.5
		if army.has("tactical") and not captured.has("approach"):
			captured["approach"] = true
			await shot("03-接近城墙", store.war)
		if not store.war.state["city_volleys"].is_empty() and not captured.has("volley"):
			captured["volley"] = true
			await shot("04-城头齐射", store.war)
		var siege: Dictionary = store.war.state["sieges"].get("xiaopei", {})
		if siege.has("breach_cell") and not captured.has("breach"):
			captured["breach"] = true
			await shot("05-城墙破口", store.war)
		if store.city_state("xiaopei")["faction"] == "yuan_shu" and not captured.has("capture"):
			captured["capture"] = true
			await shot("06-占领与驻防", store.war)
		if captured.has("capture") and army["status"] == "ended":
			captured["return"] = true
			await shot("07-归营结束", store.war)
			break
		world.presenting = false
		store.time_paused = false
	assert(captured.has("breach") and captured.has("capture") and captured.has("return"))
	# Exercise the actual river transport renderer on a predeclared campaign route.
	var preview: Dictionary = store.war.preview_dispatch("peiguo", "runan", chief)
	if preview["ok"]:
		var traveler: Dictionary = store.war._mobilize(preview)
		var path: PackedInt32Array = store.war.Fortifications.road_path(store, "hongnong", "luoyang")
		for index in range(path.size()):
			if store.war.Tactical.grid().terrain(path[index]) not in store.war.Fortifications.WATER_CODES: continue
			traveler["location"] = {"node": "hongnong", "edge": "b049", "from": "hongnong", "to": "luoyang", "progress": float(index) / maxi(1, path.size() - 1)}
			world.refresh()
			world.formations[traveler["id"]].position = world.destinations[traveler["id"]]
			scene.camera_target = world.destinations[traveler["id"]]; scene.target_goal = scene.camera_target
			scene.distance = 40; scene._update_camera()
			await shot("08-自动渡河运输", store.war)
			assert(world.formations[traveler["id"]].get_node("RiverTransport").visible)
			break
	# Declared terminal fixture exercises the actual unification rule and dialog.
	for city in store.scenario["places"].values():
		if city.has("garrison"): city["faction"] = "yuan_shu"
	store.war.Operations.result(store.war)
	world.ui.visible = true
	world.ui.refresh()
	await shot("09-战役胜利与返回入口", store.war)
	assert(world.ui.next_button.disabled and is_instance_valid(world.ui.result_dialog))
	var file := FileAccess.open(directory + "evidence.json", FileAccess.WRITE)
	file.store_string(JSON.stringify({"fixture": "formal siege; declared ferry and terminal render fixtures; no user save writes", "stages": stages, "captured": captured}, "\t"))
	print("CAMPAIGN_VISUAL_OK ", JSON.stringify(captured))
	quit()
