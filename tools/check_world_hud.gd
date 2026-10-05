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
	assert(hud.portrait.texture != null)
	assert(hud.advance.pressed.get_connections().size() == 1)
	var target = world.target_goal
	var zoom = world.distance_goal
	hud._reports()
	assert(world.army_world.ui.drawer.visible)
	world.army_world.ui.drawer.hide()
	assert(world.target_goal == target and world.distance_goal == zoom)
	assert(world.vegetation_button.get_parent() == hud.tool_list)
	assert(not world.army_world.army_choice.visible)
	assert(not world.army_world.ui.next_button.is_visible_in_tree())
	var regular = preload("res://scripts/city_ui_skin.gd").primary_button_style()
	var highlight = preload("res://scripts/city_ui_skin.gd").primary_button_style(true)
	assert(regular.texture.resource_path.ends_with("primary-normal.png"))
	assert(highlight.texture.resource_path.ends_with("primary-highlight.png"))
	print("WORLD_HUD_CHECK_OK: portraits, hidden debug panels, reports action, camera, tools, button states")
	quit()
func _find_hud(node: Node):
	if node.get_script() == load("res://scripts/world_map_hud.gd"): return node
	for child in node.get_children():
		var found = _find_hud(child)
		if found != null: return found
	return null
