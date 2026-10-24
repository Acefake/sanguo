extends SceneTree
func _initialize() -> void:
	call_deferred("_check")
func _check() -> void:
	var world = load("res://scenes/rtk14_world_3d.tscn").instantiate()
	root.add_child(world)
	while not world.loaded: await process_frame
	await process_frame
	var hud = _find_hud(world)
	assert(hud != null)
	assert(not world.status.visible)
	assert(not world.hex_world.panel.visible)
	# 新外壳：顶栏（势力 · 日期 · 推进 · 入口）替代旧的头像牌与「进行」大按钮；左下小地图。
	assert(hud.top_bar != null and hud.top_bar.find_child("FlowButton", true, false) != null)
	assert(hud.top_bar.flow_pressed.get_connections().size() == 1)
	assert(hud.top_bar.find_child("Entry_reports", true, false) != null)
	assert(hud.minimap != null and hud.minimap.visible)
	var target = world.target_goal
	var zoom = world.distance_goal
	hud._reports()
	assert(world.army_world.ui.drawer.visible and world.army_world.ui.page == "reports")
	assert(world.army_world.ui.reports_view.get_parent() == world.army_world.ui.drawer.pages)
	world.army_world.ui.drawer.hide()
	assert(world.target_goal == target and world.distance_goal == zoom)
	assert(world.vegetation_button.get_parent() == hud.tool_list)
	assert(not world.army_world.army_choice.visible)
	# 3D 大地图上推进按钮在顶栏，军务界面不再自建工具行。
	assert(world.army_world.ui.next_button == null)
	var regular = preload("res://scripts/ui/city_ui_skin.gd").primary_button_style()
	var highlight = preload("res://scripts/ui/city_ui_skin.gd").primary_button_style(true)
	assert(regular.texture.resource_path.ends_with("primary-normal.png"))
	assert(highlight.texture.resource_path.ends_with("primary-highlight.png"))
	print("WORLD_HUD_CHECK_OK: top bar, minimap, hidden debug panels, reports drawer, camera, tools, button states")
	quit()
func _find_hud(node: Node):
	if node.get_script() == load("res://scripts/world/world_map_hud.gd"): return node
	for child in node.get_children():
		var found = _find_hud(child)
		if found != null: return found
	return null
