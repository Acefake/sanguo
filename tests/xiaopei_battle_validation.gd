extends SceneTree

var failures: Array[String] = []

class BattleAgent extends Node:
	var model := "battle-fixture"
	var last_status := "测试代理"
	var metrics := {"fallbacks": 0}
	var count := 0
	func choose_batch(contexts: Array) -> Dictionary:
		var results := {}
		for context in contexts:
			count += 1
			var choice := "maintain"
			for candidate in context["candidates"]:
				if candidate["action"]["type"] == "deploy_corps":
					choice = candidate["id"]
					break
			results[context["request_id"]] = {"candidate_id": choice, "reason_summary": "测试接战", "source": "battle-fixture"}
		return results

func _initialize() -> void: call_deferred("_run")

func check(value: bool, message: String) -> void:
	if not value:
		failures.append(message)
		push_error(message)

func _run() -> void:
	var store: Node = root.get_node("GameState")
	store.persist_enabled = false
	var old_day: int = store.day
	var old_tick: int = store.war.state["tick"]
	var original_agent: Node = store.agent
	store.prepare_battle_test()
	check(store.agent == original_agent and not store.persist_enabled, "测试修改了模型配置或开启正式存档写入")
	check(store.war.state["corps"].size() == 2 and store.war.active_armies().size() == 2, "测试开始前已经预拆分军团")
	var ids := {}
	var strengths := {"liu_bei": 0, "yuan_shao": 0}
	for corps in store.war.state["corps"].values():
		for officer in corps["members"]:
			check(not ids.has(officer), "武将重复入军")
			ids[officer] = true
		check(corps["appointments"].size() == corps["members"].size(), "随军人物缺少任职")
	for army in store.war.active_armies():
		strengths[army["faction"]] += store.war.Combat.strength(army)
		check(army["location"]["edge"] == "b094", "小沛接战位置无效")
	check(ids.size() == 18 and strengths["liu_bei"] == 20000 and strengths["yuan_shao"] == 20000, "未编入全部18位人物或兵力不平衡")
	var own: Dictionary = store.war.active_armies("liu_bei").filter(func(army): return army["corps_task"]["type"] == "main_attack")[0]
	var corps: Dictionary = store.war.state["corps"][own["corps_id"]]
	var context: Dictionary = store.war.Corps.commander_context(store.war, corps)
	check(context["level"] == "commander" and context["corps"]["strength"] == 20000 and context["members"].size() == 10, "缺少军团总兵力和人物任职")
	check(store.war.Corps.fallback(context)["candidate_id"] != "withdraw_corps", "均势军团只按中军兵力逃跑")
	var fixture := BattleAgent.new()
	root.add_child(fixture)
	await store.war.step(fixture)
	check(fixture.count == 2 and store.war.state["corps"].values().all(func(c): return c["orders"].size() == 1), "没有仅向双方军团主帅请求统一决策")
	check(store.war.active_armies().size() > 2 and store.war.state["corps"].values().all(func(c): return c.get("deployed", false)), "主帅没有真正分出分队")
	var fighting := 0
	for army in store.war.active_armies():
		if army.get("combat_tick", -1) == store.war.state["tick"]: fighting += 1
	for day in range(3):
		if fighting > 0: break
		await store.war.step(fixture)
		for army in store.war.active_armies():
			if army.get("combat_tick", -1) == store.war.state["tick"]: fighting += 1
	check(fighting > 0, "前线没有接战")
	var cells := {}
	for army in store.war.active_armies():
		var cell: int = int(army["tactical"]["cell"])
		check(not cells.has(str(cell)) and not store.war.state["battlefield"]["blocked"].has(cell), "部队重叠或穿过障碍")
		cells[str(cell)] = true
	if "--capture" in OS.get_cmdline_user_args():
		var scene: Node3D = load("res://scenes/rtk14_world_3d.tscn").instantiate()
		root.add_child(scene)
		while not scene.loaded: await process_frame
		await process_frame
		check(scene.army_world.formations.size() == store.war.active_armies().size(), "3D未显示全部军队")
		check(scene.hex_world.grid == store.war.Tactical.grid(), "主地图和战斗没有共享同一个格子服务")
		check(not scene.army_world.has_method("_draw_obstacles"), "残留局部战斗网格绘制")
		for child in scene.army_world.get_children():
			check(not (child is MeshInstance3D and child.mesh is ImmediateMesh), "战斗仍叠加独立格线Mesh")
		var own_cell: int = own["tactical"]["cell"]
		var center: Vector2 = scene.hex_world.grid.center(own_cell)
		var screen: Vector2 = scene.camera.unproject_position(Vector3(center.x, scene.height_at(center.x, center.y), center.y))
		scene.hex_world.select_screen(screen)
		check(scene.hex_world.selected_cell == own_cell and scene.army_world.ui.selected_army == own["id"], "主格选中没有接通军队详情")
		scene.hex_world.toggle()
		for material in scene.hex_world.materials: check(not material.get_shader_parameter("hex_grid_enabled"), "关闭主格线后还有另一层格线")
		scene.hex_world.toggle()
		scene.army_world.ui.drawer.hide()
		var fighters: Array = store.war.active_armies().filter(func(a): return a.get("combat_tick", -1) == store.war.state["tick"])
		fighters.sort_custom(func(a,b): return scene.army_world._combat_fronts(a["id"]).size() > scene.army_world._combat_fronts(b["id"]).size())
		var fighter: Dictionary = fighters[0]
		scene.camera_target = scene.army_world.formations[fighter["id"]].global_position
		scene.target_goal = scene.camera_target
		scene.distance = 26
		scene.distance_goal = 26
		scene._update_camera()
		store.time_paused = false
		scene.army_world.begin_day({})
		await create_timer(0.25).timeout
		check(not scene.army_world.combat_effects.contacts.is_empty(), "真实交战没有生成扫击与命中特效")
		var shown := {"liu_bei": 0, "yuan_shao": 0}
		for unit in store.war.active_armies():
			if unit.get("combat_tick", -1) != store.war.state["tick"] or unit["returning"]: continue
			check(scene.army_world.combat_effects.contacts.has(unit["id"]), "参战部队缺少自身的攻击效果")
			shown[unit["faction"]] += 1
		check(shown["liu_bei"] > 0 and shown["yuan_shao"] > 0, "实际3D只显示单方攻击")
		for id in scene.army_world.combat_effects.contacts:
			var army_id: String = str(id).split(":contact:")[0]
			var group: Node3D = scene.army_world.formations[army_id]
			var target: Vector3 = scene.army_world._combat_visual(army_id)["target"]
			var heading := (target - group.global_position) * Vector3(1, 0, 1)
			check((group.basis * Vector3.BACK).normalized().dot(heading.normalized()) > 0.99, "士兵正面未朝向交战目标")
			var batch: MultiMeshInstance3D = group.get_node("Soldiers")
			check(batch.multimesh.mesh == scene.army_world.mesh and batch.material_override.get_shader_parameter("pose_start") == 9, "攻击仍在跳换整队网格")
			check(batch.multimesh.get_instance_custom_data(0).r != batch.multimesh.get_instance_custom_data(1).r, "小兵攻击完全同步")
		store.time_paused = true
		var frozen: float = scene.army_world.animation_time
		await create_timer(0.12).timeout
		check(scene.army_world.animation_time == frozen, "暂停后特效仍在播放")
		store.time_paused = false
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(ProjectSettings.globalize_path("res://docs/validation/army-assets/xiaopei-combat-effects.png"))
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://docs/validation/army-assets/combat-frames"))
		for index in range(16):
			await create_timer(0.06).timeout
			await RenderingServer.frame_post_draw
			root.get_texture().get_image().save_png(ProjectSettings.globalize_path("res://docs/validation/army-assets/combat-frames/%02d.png" % index))
		scene.army_world.ui.show_army(own["id"])
		await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(ProjectSettings.globalize_path("res://docs/validation/army-assets/xiaopei-battle-details.png"))
		while scene.army_world.presenting: await process_frame
		await process_frame
		check(scene.army_world.combat_effects.contacts.is_empty(), "日播放结束后残留交战特效")
		scene.queue_free()
		await process_frame
	store.restore_battle_test()
	check(store.day == old_day and store.war.state["tick"] == old_tick and not store.battle_test and store.agent == original_agent, "测试退出没有恢复原战役")
	fixture.queue_free()
	if failures.is_empty(): print("XIAOPEI_BATTLE_OK: 18 officers in 2 corps, whole corps at start, commander-controlled split, 20000 per side, 2 commander decisions, frontline combat and collision checks, isolated save and restoration")
	quit(0 if failures.is_empty() else 1)
