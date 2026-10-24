extends SceneTree

# 战场密度/LOD headless 模型探针：先记录当前显示数量基线，再验证
# 近景增密、中远景限量与滞回、伤亡抽稀、镜外节流与显示开销采样。
# 日期标记 2026-10-11；方案文档 docs/追击与兵种近战改进方案-2026-10-10.md。

const T = preload("res://scripts/war/tactical_battlefield.gd")
const World = preload("res://scripts/war/army_world_3d.gd")
class WorldProbe extends "res://scripts/war/army_world_3d.gd":
	func _ready() -> void: pass
class MapStub extends Node3D:
	var camera := Camera3D.new()
	func height_at(_x: float, _z: float) -> float: return 0.0
var store
var world
var failures: Array[String] = []

func _initialize() -> void: call_deferred("run")

func check(ok: bool, message: String) -> void:
	if not ok: failures.append(message); push_error(message)

func make_group(army_id: String, kind: String) -> Node3D:
	var group := Node3D.new()
	world.add_child(group)
	group.set_meta("army_id",army_id)
	group.set_meta("troop_kind",kind)
	var point: Vector2 = T.world_cell(int(store.war.state["armies"][army_id]["tactical"]["cell"]))
	group.position = Vector3(point.x,0.0,point.y)
	world._create_formation(group)
	world._layout_formation(group,World.MAX_SOLDIERS if kind == "infantry" else 0)
	world._update_special_troops(group,World.MAX_SOLDIERS if kind == "archers" else 0,World.CAVALRY_MODELS if kind == "cavalry" else 0)
	return group

func run() -> void:
	store = root.get_node("GameState")
	store.persist_enabled = false
	store.agent.enabled = false
	store.prepare_battle_test(true,"plains_clash",42)
	store.time_paused = true

	# 1) 纯映射：基线数量与伤亡抽稀单调性。
	check(World.MAX_SOLDIERS == 128 and World.CAVALRY_MODELS == 48,"Near-view capacity was not raised above the 96/36 baseline")
	check(World.density_counts("infantry") == [128,80,40],"Infantry LOD table changed")
	check(World.density_counts("archers") == [128,80,40],"Archer LOD table changed")
	check(World.density_counts("cavalry") == [48,30,16],"Cavalry LOD table changed")
	check(World.density_for_strength(128,1.0) == 128,"Full strength did not show the full rank")
	check(World.density_for_strength(128,0.5) == 78,"Half strength thinning mismatch: %d" % World.density_for_strength(128,0.5))
	check(World.density_for_strength(128,0.25) == 53,"Quarter strength thinning mismatch: %d" % World.density_for_strength(128,0.25))
	check(World.density_for_strength(128,0.0) < World.density_for_strength(128,0.5),"Zero strength is not the thinnest")
	check(World.density_for_strength(48,0.5) == 29,"Cavalry thinning mismatch: %d" % World.density_for_strength(48,0.5))
	print("DENSITY_TABLE ",World.density_counts("infantry")," ",World.density_counts("cavalry"))

	# 2) 实体探针：数量/LOD/滞回/伤亡映射与布局方向。
	world = WorldProbe.new()
	world.store = store
	world.map = MapStub.new()
	root.add_child(world.map)
	world.map.add_child(world.map.camera)
	root.add_child(world)
	world.set_process(false)
	world._load_mesh()
	check(world.mesh != null and world.archer_mesh != null and world.cavalry_mesh != null,"Model meshes failed to load headless")
	var own: Dictionary = store.war.active_armies("liu_bei")[0]
	own["units"] = {"infantry":6000,"cavalry":0,"archers":0}
	own["initial_strength"] = 6000
	var group := make_group(str(own["id"]),"infantry")
	var camera: Camera3D = world.map.camera
	var home: Vector3 = group.position
	camera.global_position = home + Vector3(0,10,24)
	camera.look_at(home)
	var batch: MultiMeshInstance3D = group.get_node("Soldiers")
	world.animation_time = 0.0
	world._apply_troop_detail(group)
	check(batch.multimesh.visible_instance_count == 128,"Near view does not show the full 128 rank: %d" % batch.multimesh.visible_instance_count)
	own["units"]["infantry"] = 3000
	world.animation_time += 1.0
	world._apply_troop_detail(group)
	check(batch.multimesh.visible_instance_count == World.density_for_strength(128,0.5),"Casualty thinning did not follow the strength ratio: %d" % batch.multimesh.visible_instance_count)
	own["units"]["infantry"] = 1500
	world.animation_time += 1.0
	world._apply_troop_detail(group)
	check(batch.multimesh.visible_instance_count == World.density_for_strength(128,0.25),"Heavy casualties did not thin further: %d" % batch.multimesh.visible_instance_count)
	own["units"]["infantry"] = 6000
	world.animation_time += 1.0
	world._apply_troop_detail(group)
	check(batch.multimesh.visible_instance_count == 128,"Recovered strength did not restore the rank")
	# LOD 滞回：125/110 与 260/235 两个边界间不抖动。
	camera.global_position = home + Vector3(0,0,120)
	world.animation_time += 1.0
	world._apply_troop_detail(group)
	check(int(group.get_meta("detail_level",0)) == 0,"Near level flipped inside the 110/125 hysteresis band")
	camera.global_position = home + Vector3(0,0,130)
	world.animation_time += 1.0
	world._apply_troop_detail(group)
	check(batch.multimesh.visible_instance_count == 80,"Mid LOD count is not the 80 rank: %d" % batch.multimesh.visible_instance_count)
	camera.global_position = home + Vector3(0,0,250)
	world.animation_time += 1.0
	world._apply_troop_detail(group)
	check(int(group.get_meta("detail_level",0)) == 1,"Level left the mid band without crossing 260")
	camera.global_position = home + Vector3(0,0,270)
	world.animation_time += 1.0
	world._apply_troop_detail(group)
	check(batch.multimesh.visible_instance_count == 40,"Far LOD count is not the 40 rank: %d" % batch.multimesh.visible_instance_count)
	camera.global_position = home + Vector3(0,0,240)
	world.animation_time += 1.0
	world._apply_troop_detail(group)
	check(int(group.get_meta("detail_level",0)) == 2,"Far level reduced before 235")
	# 镜外节流：背对时 0.5s 内不重复检查；超时后恢复。
	camera.global_position = home + Vector3(0,20,-24)
	camera.look_at(home + Vector3(0,0,-100))
	var before_check := float(group.get_meta("detail_check_at",-1.0))
	world.animation_time += 1.0
	world._apply_troop_detail(group)
	var first_check := float(group.get_meta("detail_check_at",-1.0))
	world._apply_troop_detail(group)
	check(is_equal_approx(float(group.get_meta("detail_check_at",-1.0)),first_check),"Off-screen refresh ignored the 0.5s cadence")
	world.animation_time += 1.0
	world._apply_troop_detail(group)
	check(float(group.get_meta("detail_check_at",-1.0)) > first_check,"Off-screen cadence never resumed")
	# 前排优先布局：低位索引在前排，伤亡前缀从后排开始抽稀。
	var front: Vector3 = world._troop_offset(group,0,"infantry","idle")
	var back: Vector3 = world._troop_offset(group,127,"infantry","idle")
	check(front.z > back.z,"Front rank does not lead the layout")
	var visible_min := INF
	var visible_max := -INF
	var full_min := INF
	var full_max := -INF
	for i in range(128):
		var offset: Vector3 = world._troop_offset(group,i,"infantry","idle")
		full_min = minf(full_min,offset.z)
		full_max = maxf(full_max,offset.z)
		if i < 64:
			visible_min = minf(visible_min,offset.z)
			visible_max = maxf(visible_max,offset.z)
	check(is_equal_approx(visible_max,full_max),"Thinning removed the contact rank")
	check(visible_min > full_min,"Thinning did not leave the rear rank empty")
	print("DENSITY_LAYOUT front_z=",front.z," back_z=",back.z)

	# 3) 显示开销采样：10 支部队 LOD 检查与强制重排的时间。
	var squads: Array = []
	for army in store.war.active_armies().slice(0,10):
		army["units"] = {"infantry":4000,"cavalry":0,"archers":0}
		army["initial_strength"] = 4000
		var squad := make_group(str(army["id"]),"infantry")
		var point: Vector2 = T.world_cell(int(army["tactical"]["cell"]))
		camera.global_position = Vector3(point.x,10,point.y+24)
		camera.look_at(squad.position)
		world.animation_time += 1.0
		world._apply_troop_detail(squad)
		squads.append(squad)
	var start := Time.get_ticks_usec()
	for step in range(200):
		world.animation_time += 0.01
		for squad in squads: world._apply_troop_detail(squad)
	var detail_usec := Time.get_ticks_usec()-start
	start = Time.get_ticks_usec()
	for step in range(20):
		for squad in squads:
			squad.remove_meta("fit_signature")
			world._fit_formation_to_hex(squad)
	var fit_usec := Time.get_ticks_usec()-start
	var metrics: Dictionary = store.war.state.get("battle_ai_metrics",{})
	print("DENSITY_PERF squads=",squads.size()," detail_200x10_usec=",detail_usec," fit_20x10_usec=",fit_usec," decision_ms_last=",metrics.get("decision_ms","n/a")," instances=",World.MAX_SOLDIERS,"/",World.CAVALRY_MODELS)

	print("ARMY_DENSITY_OK" if failures.is_empty() else "ARMY_DENSITY_FAILED " + str(failures))
	quit(0 if failures.is_empty() else 1)
