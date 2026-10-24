extends SceneTree

const Scenarios = preload("res://scripts/war/battle/battle_scenarios.gd")
const Badge = preload("res://scripts/war/presentation/army_badge.gd")

var failures: Array[String] = []
var checks: int = 0

func _initialize() -> void:
	call_deferred("run")

func check(ok: bool, text: String) -> void:
	checks += 1
	if not ok and not failures.has(text):
		failures.append(text)
		push_error(text)

func run() -> void:
	var store: Node = root.get_node("GameState")
	store.persist_enabled = false
	store.agent.enabled = false
	store.prepare_battle_test(true, "guandu_clash", 1910901)
	var war = store.war
	var corps_list: Array = war.state["corps"].values().filter(func(c): return c["faction"] == "liu_bei")
	check(not corps_list.is_empty(), "刘备军团未能初始化")
	var liu_bei_corps: Dictionary = corps_list[0] if not corps_list.is_empty() else {}
	check(liu_bei_corps.get("units", []).size() > 1, "刘备军团分队数量必须大于1")
	var root_id: String = liu_bei_corps.get("root_id", "")
	var scene: Node3D = load("res://scenes/rtk14_world_3d.tscn").instantiate()
	root.add_child(scene)
	while not scene.loaded:
		await process_frame
	for frame in range(4):
		await process_frame
	scene.set_process(false)
	var world: Node3D = scene.army_world
	world.set_process(false)
	store.time_paused = true
	var root_group: Node3D = world.formations[root_id]
	scene.camera_target = root_group.position
	scene.target_goal = root_group.position
	# 测试 1：远景模式（距离 180.0，超过阈值 135.0），验证军团徽标聚合
	scene.distance = 180.0
	scene.distance_goal = 180.0
	scene._update_camera()
	world._process(0.016)
	var root_badge: Control = world.badges[root_id]
	check(root_badge.corps_aggregated, "远景下主帅徽标必须处于聚合状态")
	check(root_badge.visible, "远景下主帅徽标必须保持可见")
	check(root_badge.scale.x >= 0.38, "远景聚合下主帅徽标缩放必须享有保底 scale (>=0.38)")
	var expected_total_strength: int = 0
	for uid in liu_bei_corps["units"]:
		if world.badges.has(uid):
			expected_total_strength += world.badges[uid].base_strength
	check(root_badge.strength == expected_total_strength, "远景聚合下主帅必须显示军团总兵力")
	for uid in liu_bei_corps["units"]:
		if uid == root_id: continue
		var sub_badge: Control = world.badges[uid]
		check(not sub_badge.visible, "远景聚合下从属分队徽标必须隐藏避免重叠")
		check(not sub_badge.corps_aggregated, "从属分队不应被标记为聚合帅印")
	# 测试 2：拉近微操模式（距离 70.0，低于阈值 135.0），验证军团徽标展开
	scene.distance = 70.0
	scene.distance_goal = 70.0
	scene._update_camera()
	world._process(0.016)
	check(not root_badge.corps_aggregated, "拉近后主帅徽标必须恢复展开状态")
	check(root_badge.strength == root_badge.base_strength, "拉近后主帅徽标必须恢复单队基础兵力")
	for uid in liu_bei_corps["units"]:
		var unit_badge: Control = world.badges[uid]
		check(unit_badge.visible, "拉近后所有分队徽标必须恢复显示")
		check(not unit_badge.corps_aggregated, "拉近后所有分队均处于非聚合状态")
	# 测试 3：再次拉远到鸟瞰全局（距离 210.0），验证平滑重新聚合
	scene.distance = 210.0
	scene.distance_goal = 210.0
	scene._update_camera()
	world._process(0.016)
	check(root_badge.corps_aggregated, "再次拉远后主帅徽标平滑重新聚合")
	check(root_badge.strength == expected_total_strength, "重新聚合后军团总兵力正确保持")
	for uid in liu_bei_corps["units"]:
		if uid != root_id:
			check(not world.badges[uid].visible, "重新聚合后从属分队再次隐藏")
	print("ARMY_BADGE_AGGREGATION_VALIDATION checks=%d failures=%d" % [checks, failures.size()])
	if not failures.is_empty():
		for f in failures:
			print("FAIL: ", f)
		quit(1)
		return
	quit(0)
