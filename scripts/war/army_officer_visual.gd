extends RefCounted

# Presentation only; existing armies own combat attributes and AI.
const Roles = preload("res://scripts/war/army_command_roles.gd")
const Actor = preload("res://scripts/war/mounted_duel_actor.gd")
const Hex = preload("res://scripts/war/hex_presentation.gd")
const UISkin = preload("res://scripts/city_ui_skin.gd")

static func sync(world, group: Node3D, army: Dictionary, concealed: bool = false) -> void:
	var resolved: Dictionary = Roles.resolve(world.store.war, army)
	var holder: Node3D = group.get_node_or_null("CommandOfficers")
	if holder == null:
		holder = Node3D.new()
		holder.name = "CommandOfficers"
		group.add_child(holder)
	for role in ["commander", "deputy"]:
		var card: Dictionary = resolved.get(role, {}) if resolved.get("enabled", true) and not concealed else {}
		var actor: Node3D = holder.get_node_or_null(role)
		if card.is_empty():
			if actor != null:
				holder.remove_child(actor)
				actor.queue_free()
			continue
		if actor == null:
			actor = Actor.new()
			actor.name = role
			actor.variant = "407a9723" if role == "commander" else "8edce9d9"
			holder.add_child(actor)
			var caption := Label3D.new()
			caption.name = "RoleLabel"
			caption.font = UISkin.font()
			caption.font_size = 32
			caption.outline_size = 8
			caption.pixel_size = 0.012
			caption.top_level = true
			caption.no_depth_test = true
			caption.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			caption.position.y = 2.6
			caption.modulate = Color("f2cf71") if role == "commander" else Color("a5d7ef")
			actor.add_child(caption)
			var bounds := PackedVector3Array()
			for part in actor.find_children("*", "MeshInstance3D", true, false):
				var box: AABB = part.mesh.get_aabb()
				for corner in range(8): bounds.append(actor.to_local(part.to_global(box.get_endpoint(corner))))
			actor.set_meta("pose_bounds", bounds)
		actor.set_meta("officer_id", str(card.get("id", "")))
		actor.set_meta("can_command", bool(card.get("can_command", false)))
		actor.get_node("RoleLabel").text = ("主将\n" if role == "commander" else "副将\n") + str(card.get("name", ""))
	ground(world, group)

static func ground(world, group: Node3D) -> void:
	var holder: Node3D = group.get_node_or_null("CommandOfficers")
	if holder == null: return
	var cell := Hex.cell_at(group.global_position)
	if cell < 0:
		holder.hide()
		return
	var size := float(group.get_meta("formation_scale", 0.65))
	var offsets := PackedVector2Array()
	for actor in holder.get_children():
		var desired := Vector3(-1.0 if actor.name == "commander" else 1.0, 0, -4.0)
		for corner in actor.get_meta("pose_bounds", PackedVector3Array()):
			var offset: Vector3 = group.basis * (desired + corner)
			offsets.append(Vector2(offset.x, offset.z))
	var shift: Vector3 = group.get_meta("formation_shift", Vector3.ZERO)
	var anchor: Vector3 = group.to_global(shift)
	# Cross a tile boundary continuously with the soldiers, without disappearing.
	# Once stationary, the combined formation envelope fits the assigned hex.
	if not world._formation_moving(group):
		size = minf(size, Hex.fit_scale(cell, Vector2(anchor.x, anchor.z), offsets))
	for actor in holder.get_children():
		actor.scale = Vector3.ONE * size
		var desired := Vector3(-1.0 if actor.name == "commander" else 1.0, 0, -4.0) * size + shift
		var point: Vector3 = group.to_global(desired)
		desired.y = world.map.height_at(point.x, point.z) - group.global_position.y + 0.2
		actor.position = desired
		actor.set_meta("formation_cell", cell)
		var label: Label3D = actor.get_node("RoleLabel")
		label.global_position = actor.global_position + group.basis * Vector3(-0.65 if actor.name == "commander" else 0.65, 0, 0) + Vector3.UP * 2.1
	holder.visible = size > 0.01 and (not group.get_node("RiverTransport").visible if group.has_node("RiverTransport") else true)
