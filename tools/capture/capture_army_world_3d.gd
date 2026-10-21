extends SceneTree

var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func check(value: bool, message: String) -> void:
	if not value:
		failures.append(message)
		push_error(message)

func _run() -> void:
	var store: Node = root.get_node("GameState")
	store.persist_enabled = false
	store._load_demo()
	store.year = 191
	store.month = 9
	store.day = 1
	store.agent.enabled = false
	var home: Dictionary = store.city_state("chengdu")
	home["faction"] = "liu_bei"
	home["garrison"] = 8000
	home["units"] = {"infantry": 8000, "archers": 0, "cavalry": 0}
	home["grain"] = 50000
	store.city_state("zitong")["faction"] = "liu_bei"
	var available: Array = store.war.available_officers("liu_bei")
	var officer_id := str(available[0]["id"]) if not available.is_empty() else ""
	check(officer_id != "", "刘备势力没有可派遣武将")
	var result: Dictionary = store.war.dispatch("chengdu", "hanzhong", officer_id)
	check(bool(result["ok"]), "3D测试派遣失败")
	var id: String = result.get("army_id", "")
	if id == "": quit(1); return
	var army: Dictionary = store.war.state["armies"][id]
	var path: Dictionary = store.war.graph.path("chengdu", "hanzhong")
	army["location"] = {"node": "chengdu", "from": "chengdu", "to": path["nodes"][1], "edge": path["edges"][0], "progress": 0.35}
	var scene: Node3D = load("res://scenes/rtk14_world_3d.tscn").instantiate()
	root.add_child(scene)
	var start := Time.get_ticks_msec()
	while not scene.loaded:
		await process_frame
		if Time.get_ticks_msec() - start > 120000:
			check(false, "3D地图加载超时")
			quit(1)
			return
	await process_frame
	var world: Node3D = scene.army_world
	check(world.city_aliases["city_303"] == "zitong", "3D城池名称别名不匹配")
	check(world.formations.has(id) and world.badges.has(id), "军队模型或头像标记未创建")
	check(world.march_meshes.size() == 8, "步兵行军帧没有加载")
	check(world.combat_meshes.size() == 12, "步兵战斗帧没有加载")
	check(world.idle_meshes.size() == 8, "步兵待机呼吸帧没有加载")
	world.deploy_city("chengdu")
	check(is_instance_valid(world.ui.dispatch_view) and world.ui.dispatch_view.target != "chengdu" and world.ui.dispatch_view.selection(world.ui.dispatch_view.sources) == "chengdu", "3D出阵没有保留出发城")
	world.badges[id].selected.emit()
	check(world.ui.drawer.visible and world.ui.page == "army", "军队详情没有打开")
	scene.camera_target = world.world_position(army["location"])
	scene.target_goal = scene.camera_target
	scene.distance = 70
	scene.distance_goal = 70
	scene.pitch = deg_to_rad(46)
	scene._update_camera()
	await create_timer(2.5).timeout
	await RenderingServer.frame_post_draw
	var screenshot := ProjectSettings.globalize_path("res://docs/validation/army-assets/army-world-3d.png")
	root.get_texture().get_image().save_png(screenshot)
	army["intel"]["enemies"]["observed-test"] = {"id": "observed-test", "location": {"node": "xiangping", "edge": "", "progress": 0.0}, "strength_estimate": 1300, "observed_at": 0, "uncertainty": 200, "routing": false}
	world.refresh()
	check(world.badges.has("observed-test") and world.badges["observed-test"].estimated and world.badges["observed-test"].strength == 1300, "可见敌军没有采用侦察估计")
	world.badges["observed-test"].selected.emit()
	check(world.ui.page == "enemy" and world.ui.body.find_child("WithdrawArmy", true, false) == null, "敌军情报暴露了控制操作")
	army["intel"]["enemies"].clear()
	world.refresh()
	check(not world.badges.has("observed-test"), "过期敌军情报没有移除")
	world.ui.show_army(id)
	var original_location: Dictionary = army["location"].duplicate(true)
	var movement_start: Vector3 = world.formations[id].position
	var time_start := Time.get_ticks_msec()
	var motion_samples: Array[Vector3] = []
	var sample_motion := func(): motion_samples.append(world.formations[id].position)
	process_frame.connect(sample_motion)
	await store.advance_day()
	process_frame.disconnect(sample_motion)
	var movement_end: Vector3 = world.formations[id].position
	check(Time.get_ticks_msec() - time_start >= 1800 and motion_samples.size() >= 10, "日期没有等待可见行军播放")
	check(movement_start.distance_to(movement_end) > 0.1, "军队没有随日期移动")
	var intermediate := false
	for point in motion_samples:
		if point.distance_to(movement_start) > 0.05 and point.distance_to(movement_end) > 0.05: intermediate = true
	check(intermediate, "行军只有起点和终点，没有连续中间位置")
	army["combat_tick"] = int(store.war.state["tick"])
	scene.camera_target = movement_end
	scene.target_goal = movement_end
	scene._update_camera()
	world.begin_day({})
	await create_timer(0.3).timeout
	var soldiers: MultiMeshInstance3D = world.formations[id].get_node("Soldiers")
	check(soldiers.material_override.get_shader_parameter("pose_start") == 9 and soldiers.material_override.get_shader_parameter("pose_count") == 12, "接战没有切换战斗动画")
	store.busy = true
	store.toggle_time_pause()
	var frozen_position: Vector3 = world.formations[id].position
	var frozen_elapsed: float = world.presentation_elapsed
	var frozen_mesh: Mesh = soldiers.multimesh.mesh
	await create_timer(0.3).timeout
	check(world.formations[id].position.is_equal_approx(frozen_position) and is_equal_approx(world.presentation_elapsed, frozen_elapsed) and soldiers.multimesh.mesh == frozen_mesh, "暂停没有立即冻结位置和战斗动作")
	store.toggle_time_pause()
	store.busy = false
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(ProjectSettings.globalize_path("res://docs/validation/army-assets/army-combat-3d.png"))
	while world.presenting: await process_frame
	army["location"] = original_location
	world.refresh()
	world.formations[id].position = world.world_position(original_location)
	var command: Dictionary = store.war.command_army(id, {"engage": false, "retreat": false, "pursue": false, "after_battle": "hold"})
	check(bool(command["ok"]), "军令更新失败")
	var context: Dictionary = store.war.context_for(army)
	for candidate in context["candidates"]:
		check(candidate["action"]["type"] not in ["engage", "withdraw", "pursue"], "禁止的军令仍暴露给智能体")
	store.busy = true
	check(not store.war.command_army(id, {}, true)["ok"], "推进日期时仍能撤退")
	store.busy = false
	world.ui.show_army_orders(id)
	var button: Button = world.ui.body.find_child("WithdrawArmy", true, false)
	check(button != null, "没有主动撤退入口")
	button.pressed.emit()
	check(bool(army["returning"]) and is_equal_approx(float(army["location"]["progress"]), 0.65), "撤退没有反向沿路行军")
	check(not store.war.command_army(id, {}, true)["ok"], "重复撤退应拒绝")
	for index in range(60):
		await store.war.step()
		if army["status"] == "ended": break
	check(army["status"] == "ended", "撤退没有完成归营")
	check(int(home["garrison"]) == 8000, "撤退归营时兵力不守恒")
	store.campaign_changed.emit()
	check(not world.formations.has(id), "归营后没有移除军队标记")
	if failures.is_empty():
		print("ARMY_WORLD_3D_OK: original model, commander badge, details, orders, busy guard, road reversal, persistent retreat and troop conservation")
	quit(0 if failures.is_empty() else 1)
