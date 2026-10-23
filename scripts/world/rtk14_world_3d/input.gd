@abstract
class_name Rtk14World3DInput
extends "res://scripts/world/rtk14_world_3d/state.gd"
## 3D 大地图·输入：鼠标拖拽缩放与点选、城池与关隘的聚焦和选中、工具栏按钮命令（出征、入城、武将、显示开关）。

## 镜头移到关隘；immediate 为真时不做缓动。
func focus_gate(gate_id: String, immediate := false) -> void:
	if not gate_nodes.has(gate_id):
		return
	target_goal = gate_nodes[gate_id].position
	distance_goal = 65.0
	pitch = deg_to_rad(46)
	yaw = gate_nodes[gate_id].rotation.y + 0.08
	_clear_selection()
	if immediate:
		camera_target = target_goal
		distance = distance_goal
		_update_camera()

func _focus_forest(immediate := false) -> void:
	if not loaded:
		return
	var reference: Vector3 = city_nodes["luoyang"].position
	var best := Vector3.ZERO
	var best_distance := INF
	for batch in vegetation_batches:
		if bool(batch.get_meta("ground_cover", false)):
			continue
		for point: Vector3 in batch.get_meta("placement_centres", PackedVector3Array()):
			var separation := reference.distance_to(point)
			if separation > 45.0 and separation < best_distance:
				best = point
				best_distance = separation
	target_goal = best + Vector3(0, 2.0, 0)
	distance_goal = 38.0
	pitch = deg_to_rad(45)
	yaw = 0.5
	_clear_selection()
	if immediate:
		camera_target = target_goal
		distance = distance_goal
		_update_camera()

func _unhandled_input(event: InputEvent) -> void:
	if city_interior != null:
		return
	if officer_page != null and officer_page.visible:
		return
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			distance_goal = clampf(distance_goal / 1.14, 38.0, 3000.0)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			distance_goal = clampf(distance_goal * 1.14, 38.0, 3000.0)
		elif event.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_MIDDLE, MOUSE_BUTTON_RIGHT]:
			if event.pressed:
				dragging_button = event.button_index
				drag_distance = 0
			else:
				if dragging_button == MOUSE_BUTTON_LEFT and drag_distance < 5:
					if hex_world != null:
						hex_world.select_screen(event.position, event.shift_pressed)
					if not event.shift_pressed:
						_select_at(event.position)
				dragging_button = 0
	elif event is InputEventMouseMotion and dragging_button != 0:
		drag_distance += event.relative.length()
		if dragging_button == MOUSE_BUTTON_RIGHT:
			yaw -= event.relative.x * 0.005
			pitch = clampf(pitch + event.relative.y * 0.003, deg_to_rad(28), deg_to_rad(82))
		else:
			var right := Vector3(cos(yaw), 0, -sin(yaw))
			var forward := Vector3(sin(yaw), 0, cos(yaw))
			target_goal -= (right * event.relative.x + forward * event.relative.y) * distance * 0.0014
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_F:
			_show_overview()
		elif event.keycode == KEY_ESCAPE:
			_clear_selection()
			if hex_world != null:
				hex_world.clear_selection()
		elif event.keycode == KEY_G and hex_world != null:
			hex_world.toggle()
		elif event.keycode == KEY_HOME:
			focus_city("luoyang")
		elif event.keycode == KEY_TAB:
			for child in get_children():
				if child is CanvasLayer:
					child.visible = not child.visible
			if hex_world != null:
				hex_world.ui_visible = not hex_world.ui_visible

func _select_at(screen: Vector2) -> void:
	var closest := ""
	var best := 26.0
	if not cities_root.visible:
		return
	for id in city_pick_positions:
		var world: Vector3 = city_pick_positions[id]
		if camera.is_position_behind(world):
			continue
		var projected := camera.unproject_position(world)
		var delta := screen.distance_to(projected)
		if delta < best:
			best = delta
			closest = str(id)
	if not closest.is_empty():
		_select_city(closest)
	else:
		_clear_selection()

## 选中城池并把镜头移过去；immediate 为真时不做缓动。
func focus_city(city_id: String, immediate := false) -> void:
	if not city_nodes.has(city_id):
		return
	var node: Node3D = city_nodes[city_id]
	target_goal = node.position
	distance_goal = 240.0
	pitch = deg_to_rad(35)
	yaw = 0.045
	if immediate:
		camera_target = target_goal
		distance = distance_goal
		_update_camera()
	_select_city(city_id)

func _select_city(city_id: String) -> void:
	if not city_nodes.has(city_id):
		return
	selected_city = city_id
	var node: Node3D = city_nodes[city_id]
	var foundation: Dictionary = city_foundations[city_id]
	var radius := maxf(12.0, float(foundation["selection_radius"]))
	var torus := selected_ring.mesh as TorusMesh
	torus.inner_radius = radius
	torus.outer_radius = radius + 0.08
	selected_ring.position = Vector3(node.position.x, float(foundation["height"]) + 0.08, node.position.z)
	selected_ring.visible = true
	if city_popup != null:
		city_popup.visible = GameState.canonical_city_id(selected_city) != ""

func _clear_selection() -> void:
	selected_city = ""
	if selected_ring != null:
		selected_ring.visible = false
	if city_popup != null:
		city_popup.visible = false

func _show_overview(immediate := false) -> void:
	target_goal = Vector3(1024, 8, 1024)
	distance_goal = 3000
	yaw = 0
	pitch = deg_to_rad(78)
	_clear_selection()
	if immediate:
		camera_target = target_goal
		distance = distance_goal
		_update_camera()

func _deploy_selected_city() -> void:
	if selected_city.is_empty():
		return
	if army_world != null:
		army_world.deploy_city(selected_city)

func _enter_selected_city() -> void:
	if selected_city.is_empty() or city_interior != null: return
	var logical_id := GameState.canonical_city_id(selected_city)
	if logical_id == "": return
	var name: String = GameState.war.graph.name_of(logical_id)
	city_hidden_layers.clear()
	for overlay in find_children("*", "CanvasLayer", true, false):
		if overlay.visible:
			city_hidden_layers.append(overlay)
			overlay.hide()
	city_interior = load("res://scenes/city_interior.tscn").instantiate()
	add_child(city_interior)
	city_interior.open_city(logical_id, name, "")
	city_interior.closed.connect(func() -> void:
		city_interior.queue_free()
		city_interior = null
		for overlay in city_hidden_layers:
			if is_instance_valid(overlay): overlay.show()
		city_hidden_layers.clear()
	)
	city_popup.hide()

func _open_officers() -> void:
	if officer_page == null:
		officer_page = load("res://scenes/officer_page.tscn").instantiate()
		add_child(officer_page)
	officer_page.open_page(true)

func _toggle_vegetation() -> void:
	if vegetation_root == null:
		return
	vegetation_root.visible = not vegetation_root.visible
	vegetation_button.text = "植被：开" if vegetation_root.visible else "植被：关"

func _toggle_labels() -> void:
	labels_enabled = not labels_enabled
	labels_button.text = "城名：开" if labels_enabled else "城名：关"

func _toggle_cities() -> void:
	if cities_root == null:
		return
	cities_root.visible = not cities_root.visible
	city_button.text = "城池：开" if cities_root.visible else "城池：关"
	if not cities_root.visible:
		_clear_selection()
