extends SceneTree

const Roles = preload("res://scripts/war/army_command_roles.gd")
const Hex = preload("res://scripts/war/hex_presentation.gd")
var failures: Array[String] = []
const OUT := "res://docs/validation/combat-grid-command-2026-10-11/"

func _initialize() -> void: call_deferred("run")
func check(value: bool, message: String) -> void:
	if not value: failures.append(message); push_error(message)

func run() -> void:
	root.size = Vector2i(1600, 900)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	var store = root.get_node("GameState")
	store.persist_enabled = false
	store.agent.enabled = false
	store.prepare_battle_test(true, "plains_clash", 42)
	store.time_paused = true
	var war = store.war
	var corps: Dictionary = war.state["corps"].values().filter(func(c): return c["faction"] == war.state["player_faction"])[0]
	var army: Dictionary = war.state["armies"][corps["root_id"]]
	var staff: String = war.Corps.staff_advice(war, corps)["officer_id"]
	check(Roles.set_deputy(war, army, staff).get("ok", false), "随军参军不能显式标为副将")
	var scene = load("res://scenes/rtk14_world_3d.tscn").instantiate()
	root.add_child(scene)
	var started := Time.get_ticks_msec()
	while not scene.loaded:
		await process_frame
		if Time.get_ticks_msec() - started > 120000: check(false, "地图加载超时"); quit(1); return
	for frame in range(5): await process_frame
	scene.set_process(false)
	var world = scene.army_world
	world.presenting = false
	world.refresh()
	for id in world.formations: world.formations[id].position = world.destinations[id]
	var group: Node3D = world.formations[army["id"]]
	world._fit_formation_to_hex(group)
	world.OfficerVisual.ground(world, group)
	var holder: Node3D = group.get_node_or_null("CommandOfficers")
	check(holder != null and holder.get_child_count() == 2, "主副将模型没有独立生成")
	if holder != null:
		for actor in holder.get_children():
			check(Hex.cell_at(actor.global_position) == Hex.cell_at(group.global_position), "军官显示位置超出部队格")
			check(not actor.get_node("RoleLabel").text.is_empty(), "军官没有名字标识")
			for corner in actor.get_meta("pose_bounds", PackedVector3Array()):
				check(Hex.cell_at(actor.to_global(corner)) == Hex.cell_at(group.global_position), "军官模型边界超出部队格")
			var soldiers: MultiMeshInstance3D = group.get_node("Soldiers")
			for index in range(soldiers.multimesh.visible_instance_count):
				var point: Vector3 = soldiers.to_global(soldiers.multimesh.get_instance_transform(index).origin)
				check(Vector2(point.x, point.z).distance_to(Vector2(actor.global_position.x, actor.global_position.z)) > 0.20, "军官与士兵站位重叠")
		check(holder.get_node("commander").get_meta("can_command", false), "主将失去指挥标识")
		check(not holder.get_node("deputy").get_meta("can_command", true), "副将获得额外指挥权")
	scene.camera_target = group.global_position
	scene.target_goal = group.global_position
	scene.pitch = deg_to_rad(48)
	scene.distance = 28
	scene.distance_goal = 28
	scene._update_camera()
	if not scene.hex_world.enabled: scene.hex_world.toggle()
	world.ui.show_army(str(army["id"]))
	for frame in range(5): await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(OUT + "commanders-and-info.png")
	world.ui.drawer_scroll.ensure_control_visible(world.ui.inspector.command_personnel)
	for frame in range(3): await process_frame
	check(world.ui.inspector.command_personnel.text.contains("副将") and world.ui.inspector.command_personnel.text.contains(str(war.roster.officers[staff]["name"])), "角色信息缺少副将独立名字")
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(OUT + "command-role-details.png")
	world.set_process(false)
	var origin: Vector3 = group.global_position
	var grid = war.Tactical.grid()
	var neighbor: int = grid.neighbors(Hex.cell_at(origin))[0]
	var next_center: Vector2 = grid.center(neighbor)
	world.motion_start[army["id"]] = origin
	world.destinations[army["id"]] = Vector3(next_center.x, origin.y, next_center.y)
	world.presenting = true
	world.presentation_elapsed = 0.5
	group.global_position = origin.lerp(world.destinations[army["id"]], 0.5)
	world.OfficerVisual.ground(world, group)
	check(holder.visible, "跨格行军导致军官消失")
	for actor in holder.get_children():
		check(is_equal_approx(actor.scale.x, float(group.get_meta("formation_scale"))), "行军军官与士兵缩放不一致")
	group.hide()
	check(not holder.get_node("commander/RoleLabel").is_visible_in_tree(), "隐藏编队泄露军官标签")
	group.show()
	group.global_position = origin
	world.presenting = false
	world.motion_start.erase(army["id"])
	world.destinations[army["id"]] = origin
	war.state["officer_states"][staff]["duel_wounded"] = true
	world.refresh()
	check(not holder.has_node("deputy"), "失效副将模型未移除")
	check(group.get_node("Soldiers").multimesh.visible_instance_count > 0, "缺副将影响士兵")
	war.state["officer_states"][staff]["duel_wounded"] = false
	army["command_roles"]["enabled"] = false
	world.refresh()
	check(holder.get_child_count() == 0, "关闭配置仍显示军官")
	army["command_roles"]["enabled"] = true
	world.refresh()
	world.OfficerVisual.sync(world, group, army, true)
	check(holder.get_child_count() == 0, "隐藏敌人仍泄露军官身份")
	print("COMMAND_ROLES_SCENE_", "OK" if failures.is_empty() else "FAILED")
	quit(0 if failures.is_empty() else 1)
