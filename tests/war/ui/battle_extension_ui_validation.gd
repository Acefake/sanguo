extends SceneTree

const Terrain = preload("res://scripts/war/battle/battle_terrain.gd")
var failures: Array[String] = []
var output_dir := "res://docs/validation/battle-ui-2026-10-11/"
func _initialize(): call_deferred("run")
func check(ok: bool, message: String):
	if not ok: failures.append(message); push_error(message)
func capture(name: String):
	await process_frame
	await RenderingServer.frame_post_draw
	var path := ProjectSettings.globalize_path(output_dir+name+".png")
	check(root.get_texture().get_image().save_png(path) == OK,"截图保存失败："+path)
func run():
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output_dir))
	var store = root.get_node("GameState")
	store.persist_enabled = false
	store.prepare_battle_test()
	for day in range(4): await store.war.step(null)
	var scene: Node3D = load("res://scenes/rtk14_world_3d.tscn").instantiate()
	root.add_child(scene)
	while not scene.loaded: await process_frame
	await process_frame
	var world: Node3D = scene.army_world
	world.ui.drawer.hide()
	var fighting: Array = store.war.active_armies().filter(func(a):return a.get("combat_tick",-1) == store.war.state["tick"])
	check(not fighting.is_empty(),"UI验证没有真实接战")
	var army: Dictionary = fighting[0] if not fighting.is_empty() else store.war.active_armies()[0]
	scene.camera_target = world.formations[army["id"]].global_position
	scene.target_goal = scene.camera_target
	scene.distance = 36
	scene.distance_goal = 36
	scene._update_camera()
	check(world.advantage_panel.visible and world.advantage_bar.value >= 0 and world.advantage_bar.value <= 100,"优势条没有显示或归一化越界")
	store.time_paused = false
	world.begin_day({})
	while world.loss_floaters.is_empty() and world.presenting: await process_frame
	check(world.loss_floaters.size() > 0 and world.loss_floaters.size() <= int(store.war.rules["feedback"]["max_floaters_per_day"]),"真实伤亡飘字缺失或超出上限")
	var floated: int = world.loss_floaters.size()
	world._spawn_loss_floaters()
	check(world.loss_floaters.size() == floated,"同日重复生成伤亡飘字")
	store.time_paused = true
	var age: float = world.loss_floaters[0].get_meta("age") if not world.loss_floaters.is_empty() else -1
	await create_timer(0.1).timeout
	check(world.loss_floaters.is_empty() or world.loss_floaters[0].get_meta("age") == age,"暂停后飘字继续计时")
	await capture("battle-extension-live")
	var own: Dictionary = store.war.active_armies("liu_bei")[0]
	world.ui.show_army(own["id"])
	world.ui.show_army_orders(own["id"])
	check(world.ui.body.find_child("ChangeFormation",true,false) == null and world.ui.body.find_child("FormationChoice",true,false) == null,"已移除的阵型操作仍显示")
	await capture("battle-extension-army")
	world.ui.show_battle_summary()
	check(world.ui.reports_view.mode == "summary" and world.ui.reports_view.visible,"会战总结没有打开")
	await capture("battle-extension-summary")
	store.time_paused = false
	while world.presenting: await process_frame
	world._update_loss_floaters(world.DAY_SECONDS)
	check(world.loss_floaters.is_empty(),"日播放结束后残留飘字")
	world.ui.drawer.hide()
	world.ui.reports_view.hide()
	world.advantage_panel.hide()
	# Capture real 3D ground at the same native cells used by the labeled 2D audit.
	var audit: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://docs/validation/terrain-code-audit.json"))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output_dir+"terrain-3d"))
	var note := Label.new()
	note.position = Vector2(470,95)
	note.add_theme_color_override("font_color",Color.WHITE)
	note.add_theme_color_override("font_shadow_color",Color.BLACK)
	note.add_theme_constant_override("shadow_offset_x",2)
	note.add_theme_constant_override("shadow_offset_y",2)
	world.layer.add_child(note)
	for code in [1,4,5,8,9,12,13]:
		var sample: Dictionary = audit["codes"][str(code)]["samples"][0]
		var point: Vector2 = scene.hex_world.grid.center(int(sample["cell"]))
		scene.camera_target = Vector3(point.x,scene.height_at(point.x,point.y),point.y)
		scene.target_goal = scene.camera_target
		scene.distance = 70
		scene.distance_goal = 70
		scene._update_camera()
		note.text = "地形核对：码%d · %s · 列%d 行%d" % [code,Terrain.name_of(Terrain.from_code(code)),sample["column"],sample["row"]]
		await create_timer(0.15).timeout
		await capture("terrain-3d/code-%d" % code)
	scene.queue_free()
	await process_frame
	store.restore_battle_test()
	print("BATTLE_EXTENSION_UI_OK: Vulkan map, advantage, loss labels, pause, formation removal, summary and 7 native terrain samples" if failures.is_empty() else "BATTLE_EXTENSION_UI_FAILED")
	quit(0 if failures.is_empty() else 1)
