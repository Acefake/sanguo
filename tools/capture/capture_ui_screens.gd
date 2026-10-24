extends SceneTree
## 改版界面的截图：选择战场、设置（人物智能页）、地图 HUD（独立战场，打开部队抽屉）、战役地图（打开城务与人事抽屉）。
##
## 用法：godot --path . --resolution 1600x900 --script res://tools/capture/capture_ui_screens.gd -- --out=<目录> [--only=picker|settings|hud|campaign]
## 文件名带分辨率后缀，如 picker_1600x900.png。需要真实渲染（不能 --headless）。

var out_dir := "user://"
var only := ""
var store: Node


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="): out_dir = arg.trim_prefix("--out=")
		elif arg.begins_with("--only="): only = arg.trim_prefix("--only=")
	call_deferred("_run")


func _run() -> void:
	store = root.get_node("GameState")
	store.persist_enabled = false
	store.agent.enabled = false
	if only in ["", "picker", "settings"]:
		change_scene_to_file("res://scenes/battle_start.tscn")
		for i in 3: await process_frame
	if only in ["", "picker"]:
		store.open_battle_scenarios(true)
		store.battle_picker.choose("guandu_clash")
		await _shot("picker")
		store.battle_picker.surface.hide()
	if only in ["", "settings"]:
		store.open_settings()
		await _shot("settings")
		store.settings_menu.window.hide()
	if only in ["", "hud"]: await _hud()
	if only == "campaign": await _campaign()
	quit(0)


func _hud() -> void:
	store.prepare_battle_test(true, "guandu_clash", 1910901)
	for day in 3: await store.war.step(null)
	var scene: Node3D = load("res://scenes/rtk14_world_3d.tscn").instantiate()
	root.add_child(scene)
	while not scene.loaded: await process_frame
	for i in 30: await process_frame
	var world = scene.army_world
	world.ui.refresh()
	var own: Array = store.war.active_armies(str(store.war.state["player_faction"]))
	if not own.is_empty(): world.ui.show_army(str(own[0]["id"]))
	for i in 20: await process_frame
	await _shot("hud")


## 战役模式（非独立战场）的 3D 地图：顶栏多出「城务」「人才」入口，抽屉打开城务与人事。
func _campaign() -> void:
	store.battle_test = false
	store._load_demo()
	store.war.start_campaign()
	var scene: Node3D = load("res://scenes/rtk14_world_3d.tscn").instantiate()
	root.add_child(scene)
	while not scene.loaded: await process_frame
	for i in 30: await process_frame
	scene.army_world.ui.show_city_policy()
	for i in 20: await process_frame
	await _shot("campaign")


func _shot(name: String) -> void:
	for i in 4: await process_frame
	await create_timer(0.3).timeout
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	var path := "%s/%s_%dx%d.png" % [out_dir, name, image.get_width(), image.get_height()]
	print("SHOT %s %s" % [path, "ok" if image.save_png(path) == OK else "error"])
