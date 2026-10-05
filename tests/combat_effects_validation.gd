extends SceneTree

var failures: Array[String] = []
class MapStub extends Node3D:
	var hex_world: Dictionary = {"grid": preload("res://scripts/rtk14_hex_grid.gd").shared()}
	func height_at(_x: float, _z: float) -> float: return 7.0

func _initialize() -> void: call_deferred("run")
func check(ok: bool, message: String) -> void:
	if not ok: failures.append(message); push_error(message)
func run() -> void:
	var store: Node = root.get_node("GameState")
	store.persist_enabled = false
	store.prepare_battle_test()
	for day in range(3): await store.war.step(null)
	var world = preload("res://scripts/war/army_world_3d.gd").new()
	var map := MapStub.new()
	world.store = store
	world.map = map
	for army in store.war.active_armies():
		var group := Node3D.new()
		root.add_child(group)
		group.position = world._battle_point(army["tactical"]["cell"])
		world.formations[army["id"]] = group
	var fighter: Dictionary = store.war.active_armies("yuan_shao").filter(func(a): return a.get("combat_tick", -1) == store.war.state["tick"])[0]
	var visual: Dictionary = world._combat_visual(fighter["id"])
	check(not visual.is_empty() and not visual["siege"], "接战目标没有接到可见军队")
	store.war.state["sieges"][fighter["target"]] = {"phase": "强攻", "active_tick": store.war.state["tick"], "participants": [fighter["id"]]}
	visual = world._combat_visual(fighter["id"])
	check(visual["siege"] and visual["target"] == world._battle_point(store.war.state["battlefield"]["objectives"]["xiaopei"]), "攻城光效没有接到城市格")
	store.war.state["sieges"].clear()
	fighter["tactical"]["phase"] = "远射"
	check(world._combat_visual(fighter["id"])["ranged"], "远射没有区分投射轨迹")
	store.battle_test = false
	world.observed_enemies[fighter["id"]] = {"fighting": true, "observed_at": store.war.state["tick"] - 1}
	check(world._combat_visual(fighter["id"]).is_empty(), "旧敌情泄露当前交战")
	store.battle_test = true
	fighter["combat_tick"] = -1
	check(world._combat_visual(fighter["id"]).is_empty(), "非交战军队触发特效")
	for unit in store.war.active_armies(): unit["combat_tick"] = -1
	var own: Dictionary = store.war.active_armies("liu_bei")[1]
	var enemies: Array = store.war.active_armies("yuan_shao")
	own["combat_tick"] = store.war.state["tick"]
	own["tactical"]["attack_target"] = enemies[0]["id"]
	own["tactical"]["phase"] = "近战"
	var neighbors: Array = store.war.Tactical.neighbors(own["tactical"]["cell"])
	for i in range(2):
		enemies[i]["tactical"]["cell"] = neighbors[i]
		enemies[i]["tactical"]["attack_target"] = own["id"]
		enemies[i]["combat_tick"] = store.war.state["tick"]
		world.formations[enemies[i]["id"]].position = world._battle_point(neighbors[i])
	check(world._combat_fronts(own["id"]).size() == 2, "多面接敌仍然只朝一个方向出招")
	if DisplayServer.get_name() != "headless":
		world._load_mesh()
		var own_group: Node3D = world.formations[own["id"]]
		world._create_formation(own_group)
		world._layout_formation(own_group, 24)
		var batch: MultiMeshInstance3D = own_group.get_node("Soldiers")
		batch.multimesh.visible_instance_count = 24
		world._face_contact_sectors(own_group, world._combat_fronts(own["id"]))
		var headings := {}
		for i in range(24):
			var direction := batch.multimesh.get_instance_transform(i).basis * Vector3.BACK
			headings[snappedf(atan2(direction.x,direction.z),0.01)] = true
		check(headings.size() >= 2, "多面接敌时小兵仍只朝一个方向攻击")
		# Facing now converges smoothly rather than snapping in one frame.
		for frame in range(60): world._face_contact_sectors(own_group, [{"target": own_group.position + Vector3.BACK * 10}], 1.0 / 60.0)
		for i in range(24):
			check((batch.multimesh.get_instance_transform(i).basis * Vector3.BACK).normalized().dot(Vector3.BACK) > 0.99, "单面接敌后仍残留旧方向")
	var effects = preload("res://scripts/war/combat_effects_3d.gd").new()
	root.add_child(effects)
	effects.height_at = map.height_at
	var camera := Camera3D.new()
	root.add_child(camera)
	camera.position = Vector3(20, 30, 20)
	camera.look_at(Vector3.ZERO)
	effects.camera = camera
	for target in [Vector3(10,0,0), Vector3(-10,0,0), Vector3(0,0,10), Vector3(0,0,-10)]:
		var angle: float = effects.attack_angle(Vector3.ZERO, target)
		var outward := Vector2(-sin(angle), -cos(angle))
		var projected := (camera.unproject_position(target) - camera.unproject_position(Vector3.ZERO)).normalized()
		check(outward.dot(projected) > 0.999, "扫击展开方向并非本队到敌人")
	var forward: float = effects.attack_angle(Vector3.ZERO, Vector3(10, 0, 6))
	var backward: float = effects.attack_angle(Vector3(10, 0, 6), Vector3.ZERO)
	check(absf(absf(wrapf(forward - backward, -PI, PI)) - PI) < 0.001, "相互攻击没有按摄像机投影形成相反方向")
	effects.begin_frame()
	effects.show_contact("a", Vector3.ZERO, Vector3(10, 0, 6), 0.8)
	effects.show_contact("b", Vector3(10, 0, 6), Vector3.ZERO, 0.8)
	check(effects.contacts["a"]["slash"].position.distance_to(effects.contacts["b"]["slash"].position) > 0.5, "双向效果挤在同一个位置")
	for id in ["a", "b"]:
		check(effects.contacts[id]["slash"].mesh.material.get_shader_parameter("tint").a >= 0.12, "相互攻击的一侧整个周期消失")
	effects.begin_frame()
	effects.end_frame()
	await process_frame
	for index in range(40): effects.show_contact(str(index), Vector3.ZERO, Vector3(10, 0, 0), 0.2, false, false)
	check(effects.contacts.size() == effects.MAX_CONTACTS, "特效数量没有上限")
	check(is_equal_approx(effects.contacts["0"]["spark"].position.y, 8.2), "特效未贴合实际地形高度")
	check(effects.contacts["0"]["slash"].mesh is PlaneMesh, "近战效果仍是朝向摄像机的箭头")
	check(effects.contacts["0"]["slash"].position == Vector3.ZERO, "打击线没有锚定本队阵型")
	var before_heading: Basis = effects.contacts["0"]["slash"].basis
	camera.position = Vector3(-20,30,20)
	camera.look_at(Vector3.ZERO)
	effects.show_contact("0", Vector3.ZERO, Vector3(10,0,0), 0.2)
	check(effects.contacts["0"]["slash"].basis == before_heading, "旋转镜头改变了阵型上的实际打击方向")
	var same = effects.contacts["0"]["slash"]
	effects.show_contact("0", Vector3.ZERO, Vector3(10, 0, 0), 0.3)
	check(effects.contacts["0"]["slash"] == same, "每帧重建交战效果")
	effects.begin_frame()
	effects.end_frame()
	await process_frame
	check(effects.contacts.is_empty() and effects.get_child_count() == 0, "停止交战后特效节点泄漏")
	for group in world.formations.values(): group.queue_free()
	world.free()
	map.free()
	effects.queue_free()
	camera.queue_free()
	store.restore_battle_test()
	print("COMBAT_EFFECTS_OK: contact target, siege city, ranged, stale fog, idle, bounded reuse, terrain and cleanup" if failures.is_empty() else "COMBAT_EFFECTS_FAILED")
	quit(0 if failures.is_empty() else 1)
