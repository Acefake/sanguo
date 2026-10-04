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
			var choice := "continue"
			for candidate in context["candidates"]:
				if candidate["action"]["type"] == "engage":
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
	check(store.war.active_armies().size() == 18 and store.war.active_armies("liu_bei").size() == 10 and store.war.active_armies("yuan_shao").size() == 8, "未全部派出18名武将")
	var ids := {}
	var strengths := {"liu_bei": 0, "yuan_shao": 0}
	for army in store.war.active_armies():
		ids[army["officer_id"]] = true
		strengths[army["faction"]] += store.war.Combat.strength(army)
		check(army["location"]["edge"] == "b094" and not army["intel"]["enemies"].is_empty(), "小沛接战位置或敌情无效")
	check(ids.size() == 18 and strengths["liu_bei"] == 20000 and strengths["yuan_shao"] == 20000, "重复武将或双方兵力不平衡")
	var fixture := BattleAgent.new()
	root.add_child(fixture)
	await store.war.step(fixture)
	check(fixture.count == 18 and store.war.state["decisions"].size() == 18, "未向双方全部主将分别请求决策")
	var fighting := 0
	for army in store.war.active_armies():
		if army.get("combat_tick", -1) == store.war.state["tick"]: fighting += 1
	check(fighting == 18, "对战未让全部军队接战")
	if "--capture" in OS.get_cmdline_user_args():
		var scene: Node3D = load("res://scenes/rtk14_world_3d.tscn").instantiate()
		root.add_child(scene)
		while not scene.loaded: await process_frame
		await process_frame
		check(scene.army_world.formations.size() == 18, "3D未显示全部军队")
		scene.army_world.ui.drawer.hide()
		scene.army_world.begin_day({})
		await create_timer(0.7).timeout
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(ProjectSettings.globalize_path("res://docs/validation/army-assets/xiaopei-battle.png"))
		while scene.army_world.presenting: await process_frame
		scene.queue_free()
		await process_frame
	store.restore_battle_test()
	check(store.day == old_day and store.war.state["tick"] == old_tick and not store.battle_test and store.agent == original_agent, "测试退出没有恢复原战役")
	fixture.queue_free()
	if failures.is_empty(): print("XIAOPEI_BATTLE_OK: 18 unique officers, 10 vs 8, 20000 per side, 18 agent decisions and combat events, isolated save and restoration")
	quit(0 if failures.is_empty() else 1)
