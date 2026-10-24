extends Node3D

const Tactical = preload("res://scripts/war/tactical_battlefield.gd")
var map: Node3D

func show_plan(war, army: Dictionary) -> void:
	for child in get_children(): child.queue_free()
	var plan: Dictionary = army.get("battle_ai",{}).get("plan",{})
	if plan.is_empty() or not army.has("tactical"): return
	var goal := int(plan.get("position_goal",plan.get("goal_cell",-1)))
	if goal >= 0: marker(goal,Color("68c8e4"),"准备位置")
	var sight: Dictionary = army.get("battle_ai",{}).get("known_target",{})
	if sight.is_empty(): sight = army.get("intel",{}).get("enemies",{}).get(plan.get("target_id",""),{})
	if int(sight.get("tactical_cell",-1)) >= 0: marker(int(sight["tactical_cell"]),Color("e0a082"),"已知目标")
	var task: Dictionary = army.get("corps_task",{})
	var anchor := int(task.get("cell",-1))
	if anchor < 0 and Tactical.board_for(war,army).has("control_point"): anchor = int(Tactical.board_for(war,army)["control_point"]["cell"])
	if anchor >= 0 and anchor != goal: marker(anchor,Color("ddc56b"),"职责目标")

func marker(cell: int, color: Color, caption: String) -> void:
	var shape := ImmediateMesh.new()
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = color
	material.no_depth_test = true
	shape.surface_begin(Mesh.PRIMITIVE_LINE_STRIP,material)
	var polygon: PackedVector2Array = Tactical.grid().polygon(cell)
	for point in Array(polygon) + [polygon[0]]:
		shape.surface_add_vertex(Vector3(point.x,map.height_at(point.x,point.y)+0.6,point.y))
	shape.surface_end()
	var line := MeshInstance3D.new()
	line.mesh = shape
	add_child(line)
	var text := Label3D.new()
	text.text = caption
	text.font = preload("res://scripts/city_ui_skin.gd").font()
	text.font_size = 22
	text.pixel_size = 0.035
	text.modulate = color
	text.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	text.no_depth_test = true
	var center := Tactical.world_cell(cell)
	text.position = Vector3(center.x,map.height_at(center.x,center.y)+3.2,center.y)
	add_child(text)
