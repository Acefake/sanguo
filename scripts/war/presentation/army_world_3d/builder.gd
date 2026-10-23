@abstract
class_name ArmyWorld3DBuilder
extends "res://scripts/war/presentation/army_world_3d/hud.gd"
## 大地图军队表现层·构建：按战役状态创建与同步 3D 节点（士兵网格与姿态贴图、阵形与站位、旗帜、攻城器械、
## 行军路线、城墙破口、远近兵力密度）。refresh() 是总入口，也会刷新下层的界面叠层。

func _load_mesh() -> void:
	var document := GLTFDocument.new()
	var state := GLTFState.new()
	if document.append_from_file("res://assets/armies/rtk14/models/infantry-poses.glb", state) != OK: return
	var model: Node3D = document.generate_scene(state)
	var meshes := model.find_children("*", "MeshInstance3D", true, false)
	if not meshes.is_empty(): mesh = meshes[0].mesh
	for i in range(1, mini(9, meshes.size())): march_meshes.append(meshes[i].mesh)
	for i in range(9, mini(21, meshes.size())): combat_meshes.append(meshes[i].mesh)
	for i in range(21, meshes.size()): idle_meshes.append(meshes[i].mesh)
	var troop_meshes: Array = [mesh]
	troop_meshes.append_array(march_meshes)
	troop_meshes.append_array(combat_meshes)
	troop_meshes.append_array(idle_meshes)
	for troop_mesh in troop_meshes:
		for surface in range(troop_mesh.get_surface_count()):
			var material: StandardMaterial3D = troop_mesh.surface_get_material(surface).duplicate()
			material.vertex_color_use_as_albedo = true
			material.metallic = 0.12
			material.roughness = 0.78
			troop_mesh.surface_set_material(surface, material)
	# Upload all recovered vertex poses once; interpolate on the GPU per soldier.
	var poses: Array = [mesh]
	poses.append_array(march_meshes)
	poses.append_array(combat_meshes)
	poses.append_array(idle_meshes)
	_remember_pose_bounds("infantry",poses)
	var vertices: int = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size()
	var positions := Image.create(vertices, poses.size(), false, Image.FORMAT_RGBAF)
	var normals := Image.create(vertices, poses.size(), false, Image.FORMAT_RGBAF)
	for frame in range(poses.size()):
		var arrays: Array = poses[frame].surface_get_arrays(0)
		assert(arrays[Mesh.ARRAY_VERTEX].size() == vertices, "Army pose topology changed")
		for index in range(vertices):
			var point: Vector3 = arrays[Mesh.ARRAY_VERTEX][index]
			var normal: Vector3 = arrays[Mesh.ARRAY_NORMAL][index]
			positions.set_pixel(index, frame, Color(point.x, point.y, point.z, 1))
			normals.set_pixel(index, frame, Color(normal.x, normal.y, normal.z, 1))
	pose_material = ShaderMaterial.new()
	pose_material.shader = preload("res://shaders/army_pose.gdshader")
	pose_material.set_shader_parameter("pose_positions", ImageTexture.create_from_image(positions))
	pose_material.set_shader_parameter("pose_normals", ImageTexture.create_from_image(normals))
	pose_material.set_shader_parameter("albedo_texture", mesh.surface_get_material(0).albedo_texture)
	model.free()
	var archer_state := GLTFState.new()
	if document.append_from_file("res://assets/armies/rtk14/models/archer-poses.glb", archer_state) == OK:
		var archer_model := document.generate_scene(archer_state)
		var frames := archer_model.find_children("*", "MeshInstance3D", true, false)
		_remember_pose_bounds("archers",frames.map(func(part): return part.mesh))
		archer_mesh = frames[0].mesh
		var width: int = archer_mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size()
		var p := Image.create(width, frames.size(), false, Image.FORMAT_RGBAF)
		var n := Image.create(width, frames.size(), false, Image.FORMAT_RGBAF)
		for frame in range(frames.size()):
			var arrays: Array = frames[frame].mesh.surface_get_arrays(0)
			for index in range(width):
				var v: Vector3 = arrays[Mesh.ARRAY_VERTEX][index]
				var normal: Vector3 = arrays[Mesh.ARRAY_NORMAL][index]
				p.set_pixel(index, frame, Color(v.x,v.y,v.z,1))
				n.set_pixel(index, frame, Color(normal.x,normal.y,normal.z,1))
		archer_material = ShaderMaterial.new()
		archer_material.shader = pose_material.shader
		archer_material.set_shader_parameter("reference_archer", true)
		archer_material.set_shader_parameter("pose_positions", ImageTexture.create_from_image(p))
		archer_material.set_shader_parameter("pose_normals", ImageTexture.create_from_image(n))
		archer_material.set_shader_parameter("albedo_texture", archer_mesh.surface_get_material(0).albedo_texture)
		archer_model.free()
	var cavalry_state := GLTFState.new()
	if document.append_from_file("res://assets/armies/rtk14/models/cavalry-poses.glb",cavalry_state) == OK:
		var model_cavalry := document.generate_scene(cavalry_state)
		var frames := model_cavalry.find_children("*","MeshInstance3D",true,false)
		_remember_pose_bounds("cavalry",frames.map(func(part): return part.mesh))
		cavalry_mesh = frames[0].mesh
		var vertex_count: int = cavalry_mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size()
		var width := mini(vertex_count,4096)
		var rows := ceili(float(vertex_count)/width)
		var positions_cavalry := Image.create(width,rows*frames.size(),false,Image.FORMAT_RGBAF)
		var normals_cavalry := Image.create(width,rows*frames.size(),false,Image.FORMAT_RGBAF)
		for frame in range(frames.size()):
			var arrays: Array = frames[frame].mesh.surface_get_arrays(0)
			for index in range(vertex_count):
				var v: Vector3 = arrays[Mesh.ARRAY_VERTEX][index]
				var normal: Vector3 = arrays[Mesh.ARRAY_NORMAL][index]
				positions_cavalry.set_pixel(index%width,frame*rows+index/width,Color(v.x,v.y,v.z,1))
				normals_cavalry.set_pixel(index%width,frame*rows+index/width,Color(normal.x,normal.y,normal.z,1))
		cavalry_material = ShaderMaterial.new()
		cavalry_material.shader = pose_material.shader
		cavalry_material.set_shader_parameter("mounted_palette",true)
		cavalry_material.set_shader_parameter("pose_rows",rows)
		cavalry_material.set_shader_parameter("pose_positions",ImageTexture.create_from_image(positions_cavalry))
		cavalry_material.set_shader_parameter("pose_normals",ImageTexture.create_from_image(normals_cavalry))
		cavalry_material.set_shader_parameter("albedo_texture",cavalry_mesh.surface_get_material(0).albedo_texture)
		model_cavalry.free()

func _remember_pose_bounds(kind: String, frames: Array) -> void:
	var bounds: AABB = frames[0].get_aabb()
	# Anchor at the feet/hooves, not at the center of a forward-reaching weapon.
	var rest: Mesh = frames[0]
	var ground_bounds := AABB()
	var found := false
	var threshold := bounds.position.y+bounds.size.y*0.12
	for surface in range(rest.get_surface_count()):
		var vertices: PackedVector3Array = rest.surface_get_arrays(surface)[Mesh.ARRAY_VERTEX]
		for vertex in vertices:
			if vertex.y > threshold: continue
			if not found: ground_bounds = AABB(vertex,Vector3.ZERO); found = true
			else: ground_bounds = ground_bounds.expand(vertex)
	troop_ground_centers[kind] = ground_bounds.get_center()*Vector3(1,0,1) if found else Vector3.ZERO
	var standing := bounds
	for i in range(frames.size()):
		bounds = bounds.merge(frames[i].get_aabb())
		# Frames 9-20 are the combat lunges (see _set_pose); the rest stand or march.
		if i < 9 or i > 20: standing = standing.merge(frames[i].get_aabb())
	troop_pose_bounds[kind] = bounds
	troop_rest_bounds[kind] = standing

func _fit_formation_to_hex(group: Node3D, moving: bool = false) -> void:
	moving = moving or melee_positions.has(str(group.get_meta("army_id","")))
	var cell := HexPresentation.cell_at(group.global_position)
	if cell < 0: return
	var mode := "combat" if bool(group.get_meta("combat_pose",false)) else "march" if moving else "idle"
	var signature := [group.global_position, group.basis, mode,
		group.get_node("Soldiers").multimesh.visible_instance_count,
		group.get_node("Archers").multimesh.visible_instance_count if group.has_node("Archers") else 0,
		group.get_node("Mounted/Cavalry").multimesh.visible_instance_count if group.has_node("Mounted/Cavalry") else 0,
		group.get_meta("facing_revision",0), group.get_meta("siege_layout_revision",0),
		group.get_meta("march_layout_scale",1.0),group.get_meta("wall_contact",false)]
	var engines: Node3D = group.get_node_or_null("SiegeEngines")
	if engines != null:
		for engine in engines.get_children(): signature.append(roundi(atan2(engine.basis.z.x,engine.basis.z.z)*1000.0))
	if group.get_meta("fit_signature",[]) == signature: return
	group.set_meta("fit_signature",signature)
	# Troops: every layout keeps its standing and marching poses within a circle of
	# radius `extent` at any heading, so the hex fit needs no per-soldier envelope.
	var extent := 0.0
	for kind in TROOP_KINDS:
		var batch: MultiMeshInstance3D = group.get_node_or_null(TROOP_KINDS[kind]["batch"])
		if batch == null or not troop_pose_bounds.has(kind) or batch.multimesh.visible_instance_count == 0: continue
		_troop_offset(group,0,kind,mode)
		extent = maxf(extent,float(_troop_layout(kind)["extent"])+float(group.get_meta("layout_slack_"+kind,0.0)))
	var envelope := PackedVector2Array()
	var equipment: Node3D = group.get_node_or_null("SiegeEngines")
	var engine_count := equipment.get_child_count() if equipment != null else 0
	for engine in (equipment.get_children() if equipment != null else []):
		var basis: Basis = engine.basis.orthonormalized().scaled(Vector3.ONE*float(engine.get_meta("native_scale",1.0)))
		var bounds := SiegeVisual.pose_bounds(str(engine.get_meta("kind","catapult")))
		var radius := 0.0
		for corner in range(8):
			var point: Vector3 = basis*bounds.get_endpoint(corner)
			radius = maxf(radius,Vector2(point.x,point.z).length())
		# Engines aim independently from their final fitted positions; reserve
		# an orientation-independent envelope for every native mechanism pose.
		var offset := _engine_offset(engine.get_index(),engine_count)
		for corner in range(16):
			var angle := TAU*float(corner)/16
			var point: Vector3 = group.basis*(offset+Vector3(cos(angle),0,sin(angle))*radius*1.02)
			envelope.append(Vector2(point.x,point.z))
	if extent <= 0.0 and envelope.is_empty(): return
	var grid = store.war.Tactical.grid()
	var original := Vector2(group.global_position.x,group.global_position.z)
	var center: Vector2 = grid.center(cell)
	var anchor := original if moving or bool(group.get_meta("wall_contact",false)) else center
	var centered := _hex_fit(cell,center,extent,envelope)
	var size := _hex_fit(cell,anchor,extent,envelope)
	# Keep every model together. Move an off-center layout inward before it would
	# collapse near a wall or during a hex transition.
	for attempt in range(8):
		if size >= centered*0.85: break
		anchor = anchor.lerp(center,0.4)
		size = _hex_fit(cell,anchor,extent,envelope)
	if moving:
		# A moving formation traverses its route continuously. Re-centering on
		# each picked hex snapped every model at the boundary and shrank them.
		anchor = original
		size = float(group.get_meta("march_layout_scale",group.get_meta("formation_scale",centered)))
	var shift := group.basis.inverse()*Vector3(anchor.x-original.x,0,anchor.y-original.y)
	for kind in TROOP_KINDS:
		var batch: MultiMeshInstance3D = group.get_node_or_null(TROOP_KINDS[kind]["batch"])
		if batch == null or not troop_pose_bounds.has(kind): continue
		var count := batch.multimesh.visible_instance_count
		if count < 0: count = batch.multimesh.instance_count
		if count == 0: continue
		var bounds: AABB = troop_pose_bounds[kind]
		var middle: Vector3 = troop_ground_centers.get(kind,Vector3.ZERO)
		var model_scale := float(TROOP_KINDS[kind]["scale"])*size
		var render_bounds := AABB()
		for i in range(count):
			var basis := batch.multimesh.get_instance_transform(i).basis.orthonormalized().scaled(Vector3.ONE*model_scale)
			var offset := _troop_offset(group,i,kind,mode)*size+shift-basis*middle
			var point: Vector3 = group.global_position+group.basis*offset
			offset.y = map.height_at(point.x,point.z)-group.global_position.y+0.2
			var transform := Transform3D(basis,offset)
			batch.multimesh.set_instance_transform(i,transform)
			render_bounds = transform*bounds if i == 0 else render_bounds.merge(transform*bounds)
		# GPU pose interpolation can extend beyond the static rest mesh bounds.
		batch.multimesh.custom_aabb = render_bounds.grow(0.20)
	for engine in (equipment.get_children() if equipment != null else []):
		var basis: Basis = engine.basis.orthonormalized().scaled(Vector3.ONE*float(engine.get_meta("native_scale",1.0))*size)
		var offset := _engine_offset(engine.get_index(),engine_count)*size+shift
		var point: Vector3 = group.global_position+group.basis*offset
		offset.y = map.height_at(point.x,point.z)-group.global_position.y+0.2
		engine.transform = Transform3D(basis,offset)
	group.set_meta("formation_cell",cell)
	group.set_meta("formation_scale",size)
	group.set_meta("formation_shift", shift)
	group.set_meta("fit_updates",int(group.get_meta("fit_updates",0))+1)

func _engine_offset(index: int, count: int) -> Vector3:
	return Vector3((index%2-(mini(count,2)-1)*0.5)*3.0,0,(index/2-(ceili(float(count)/2)-1)*0.5)*3.0)

# Largest scale (<= 1) keeping a troop circle of radius `extent` and the engine
# envelope inside the hex around `anchor`.
func _hex_fit(cell: int, anchor: Vector2, extent: float, envelope: PackedVector2Array) -> float:
	var size := HexPresentation.fit_scale(cell,anchor,envelope,FORMATION_MARGIN) if not envelope.is_empty() else 1.0
	if extent > 0.0: size = minf(size,HexPresentation.fit_radius(cell,anchor,extent,FORMATION_MARGIN))
	return size

func _wall_contact_point(army: Dictionary, center: Vector3) -> Vector3:
	var board: Dictionary = store.war.Tactical.board_for(store.war,army)
	var kind: String = preload("res://scripts/war/battle/troop_roles.gd").kind(army)
	# 弓兵与骑兵不上墙：只有步军（与器械）贴墙攻城。
	if not board.has("fortifications") or kind == "archers" or kind == "cavalry": return center
	var cell := int(army["tactical"]["cell"])
	if Fortifications.distance_to_wall(board,str(army["target"]),cell) != 1: return center
	for site in board["fortifications"].values():
		if site["id"] != army["target"]: continue
		var polygon := Fortifications.footprint(site)
		var start := Vector2(center.x,center.z)
		var wall := start
		var best := INF
		for i in range(polygon.size()):
			var p := Geometry2D.get_closest_point_to_segment(start,polygon[i],polygon[(i+1)%polygon.size()])
			if p.distance_squared_to(start) < best: wall = p; best = p.distance_squared_to(start)
		if is_inf(best): return center
		var desired := wall+(start-wall).normalized()*2.5
		# Stay in the authoritative hex; exterior partial cells can approach the wall.
		for i in range(16):
			if store.war.Tactical.grid().pick(desired) == cell and not Geometry2D.is_point_in_polygon(desired,polygon):
				return Vector3(desired.x,map.height_at(desired.x,desired.y)+0.2,desired.y)
			desired = desired.lerp(start,0.2)
	return center

## 按当前战役状态重建或同步全部军队节点、补给标记、徽章、城墙破口、敌情与战况面板。
func refresh() -> void:
	if is_instance_valid(intent_overlay) and store.war.state[StateKeys.ARMIES].has(selected_plan_army): intent_overlay.show_plan(store.war,store.war.state[StateKeys.ARMIES][selected_plan_army])
	_update_city_breaches()
	_refresh_battle_feedback()
	_refresh_supplies()
	var active: Dictionary = {}
	army_choice.clear()
	army_choice.add_item("前往在外军队")
	var entries: Array = []
	observed_enemies.clear()
	var squad_numbers := {}
	for original in store.war.active_armies():
		var entry: Dictionary = original.duplicate(false)
		if original["faction"] != store.war.state[StateKeys.PLAYER_FACTION]:
			entry["faction"] = "observed_enemy"
			entry["strength_estimate"] = store.war.Combat.strength(original)
			observed_enemies[original["id"]] = store.war.enemy_intel(original)
		entries.append(entry)
	if not store.war.state.has(StateKeys.BATTLEFIELD):
		var grouped: Array = []
		for entry in entries:
			if entry.has("tactical"): grouped.append(entry); continue
			var corps: Dictionary = store.war.state[StateKeys.CORPS].get(entry.get("corps_id", ""), {})
			if not corps.is_empty():
				if entry["id"] != corps["root_id"]: continue
				entry = entry.duplicate(false)
				entry["display_strength"] = store.war.Corps.summary(store.war, corps)["strength"]
				entry["name"] = corps["name"]
			grouped.append(entry)
		entries = grouped
	for army in entries:
		if army.get("tactical",{}).get("placement_invalid",false): continue
		var id: String = army["id"]
		var enemy: bool = army["faction"] == "observed_enemy"
		active[id] = true
		if not enemy:
			army_choice.add_item(str(army["name"]) + "队" + ("  撤退" if army["returning"] else ""))
			army_choice.set_item_metadata(army_choice.item_count - 1, id)
		var target: Vector3 = world_position(army["location"])
		if army.has("tactical"): target = _wall_contact_point(army,_battle_point(int(army["tactical"]["cell"])))
		elif store.battle_test: target += store.battle_offsets.get(id, Vector3.ZERO)
		elif enemy: target += Vector3(8, 0, -6)
		destinations[id] = target
		if not formations.has(id):
			var group := Node3D.new()
			group.name = "Formation_" + id
			add_child(group)
			group.position = target
			formations[id] = group
			group.set_meta("army_id",id)
			_create_formation(group)
			var badge := Badge.new()
			badge.title = army["name"]
			badge.portrait = _portrait(str(store.war.roster.officers.get(army.get("officer_id", ""), {}).get("name", army["name"])))
			badge.selected.connect(func():
				map._clear_selection()
				if enemy: show_enemy(id)
				else: ui.show_army(id)
				for item in badges:
					badges[item].highlighted = item == id
					badges[item].queue_redraw()
			)
			layer.add_child(badge)
			badges[id] = badge
		formations[id].set_meta("wall_contact",army.has("tactical") and target.distance_squared_to(_battle_point(int(army["tactical"]["cell"]))) > 0.01)
		var badge: Control = badges[id]
		badge.title = str(army["name"])
		badge.portrait = _portrait(str(store.war.roster.officers.get(army.get("officer_id", ""), {}).get("name", army["name"])))
		badge.commander = str(store.war.roster.officers.get(army.get("officer_id", ""), {}).get("name", army["name"]))
		badge.officer_id = str(army.get("officer_id", ""))
		badge.commander_state = "战死" if army.get("commander_unavailable", false) and army.get("commander_fate", {}).get("status", "") == "dead" else "被俘" if army.get("commander_unavailable", false) else ""
		if str(army["location"].get("edge", "")) != "":
			var direction: Vector2 = points.get(str(army["location"].get("to", "")), Vector2.ZERO) - points.get(str(army["location"].get("from", "")), Vector2.ZERO)
			if direction.length_squared() > 0.01: formations[id].set_meta("march_heading", atan2(direction.x, direction.y))
		if army.has("tactical"):
			var direction: Vector3 = target - formations[id].position
			if direction.length_squared() > 0.01: formations[id].set_meta("march_heading", atan2(direction.x, direction.z))
		var operation: Dictionary = army.get("operation", {})
		badge.tooltip_text = preload("res://scripts/ui/ui_text.gd").clean("%s  %s\n%s" % [army["name"], preload("res://scripts/war/battle/tactical_battlefield.gd").ROLES.get(operation.get("role", ""), "自主行动"), army.get("tactical", {}).get("phase", "")])
		badge.strength = int(army.get("display_strength", store.war.Combat.strength(army)))
		badge.estimated = false
		badge.morale = float(army["morale"])
		badge.base_strength = badge.strength
		badge.base_morale = badge.morale
		var badge_side := str(army["faction"])
		squad_numbers[badge_side] = int(squad_numbers.get(badge_side, 0)) + 1
		badge.squad_number = int(squad_numbers[badge_side])
		badge.hostile = enemy or store.war.hostile(str(store.war.state[StateKeys.PLAYER_FACTION]), badge_side)
		badge.faction_color = Color("c86650") if enemy else Color(str(store.scenario["factions"].get(army["faction"], {}).get("color", "#8ac56b")))
		badge.queue_redraw()
		var batch: MultiMeshInstance3D = formations[id].get_node_or_null("Soldiers")
		if batch != null:
			var group: Node3D = formations[id]
			var types: Dictionary = army.get("units", {})
			# Fixed formations represent the dominant troop type; the badge and
			# ledger stay authoritative, while the rendered model count follows the
			# LOD level and casualties in _apply_troop_detail below.
			var kind := "infantry"
			for candidate in ["archers", "cavalry"]:
				if int(types.get(candidate,0)) > int(types.get(kind,0)): kind = candidate
			var bows := MAX_SOLDIERS if kind == "archers" else 0
			var horses := CAVALRY_MODELS if kind == "cavalry" else 0
			var count := MAX_SOLDIERS if kind == "infantry" else 0
			group.set_meta("troop_kind", kind)
			badge.troop_kind = kind
			badge.queue_redraw()
			group.set_meta("bow_count",bows)
			group.set_meta("horse_count",horses)
			batch.multimesh.visible_instance_count = count
			_layout_formation(formations[id], count)
			_update_special_troops(group, bows, horses)
			var flag_faction := str(army["faction"])
			if enemy: flag_faction = str(store.war.state[StateKeys.ARMIES][id]["faction"])
			var flag_color := Color(str(store.scenario["factions"].get(flag_faction, {}).get("color", "#c86650")))
			_set_flag(group, flag_faction, flag_color)
			_update_siege_engines(group, army)
			_apply_troop_detail(group)
			_fit_formation_to_hex(group,_formation_moving(group))
	for id in formations.keys():
		if not active.has(id):
			if presenting:
				var ended: Dictionary = store.war.state[StateKeys.ARMIES].get(id, {})
				if not ended.is_empty(): destinations[id] = _battle_point(int(ended["tactical"]["cell"])) if ended.has("tactical") else world_position(ended["location"])
				continue
			formations[id].queue_free()
			badges[id].queue_free()
			formations.erase(id)
			chatter_cooldowns.erase(id)
			badges.erase(id)
			destinations.erase(id)
	_update_corps_badges()

func _create_formation(group: Node3D) -> void:
	if mesh == null: return
	var batch := MultiMeshInstance3D.new()
	batch.name = "Soldiers"
	batch.multimesh = MultiMesh.new()
	batch.multimesh.transform_format = MultiMesh.TRANSFORM_3D
	batch.multimesh.use_colors = true
	batch.multimesh.use_custom_data = true
	batch.material_override = pose_material.duplicate()
	batch.multimesh.mesh = mesh
	batch.multimesh.instance_count = MAX_SOLDIERS
	group.add_child(batch)
	if archer_mesh != null:
		var archers := MultiMeshInstance3D.new()
		archers.name = "Archers"
		archers.multimesh = MultiMesh.new()
		archers.multimesh.transform_format = MultiMesh.TRANSFORM_3D
		archers.multimesh.use_colors = true
		archers.multimesh.use_custom_data = true
		archers.multimesh.mesh = archer_mesh
		archers.multimesh.instance_count = MAX_SOLDIERS
		archers.multimesh.visible_instance_count = 0
		archers.material_override = archer_material.duplicate()
		group.add_child(archers)
	var mounted := Node3D.new()
	mounted.name = "Mounted"
	group.add_child(mounted)
	if cavalry_mesh != null:
		var riders := MultiMeshInstance3D.new()
		riders.name = "Cavalry"
		riders.multimesh = MultiMesh.new()
		riders.multimesh.transform_format = MultiMesh.TRANSFORM_3D
		riders.multimesh.use_colors = true
		riders.multimesh.use_custom_data = true
		riders.multimesh.mesh = cavalry_mesh
		riders.multimesh.instance_count = CAVALRY_MODELS
		riders.multimesh.visible_instance_count = 0
		riders.material_override = cavalry_material.duplicate()
		mounted.add_child(riders)
	var banner := MeshInstance3D.new()
	banner.name = "Banner"
	var document := GLTFDocument.new()
	var state := GLTFState.new()
	if document.append_from_file("res://assets/armies/rtk14/models/9eea5b67.glb",state) == OK:
		var model := document.generate_scene(state)
		var parts := model.find_children("*","MeshInstance3D",true,false)
		if not parts.is_empty(): banner.mesh = parts[0].mesh
		model.free()
	var flag_cloth := ShaderMaterial.new()
	flag_cloth.shader = preload("res://shaders/army_flag.gdshader")
	if banner.mesh != null:
		for surface in range(mini(2,banner.mesh.get_surface_count())):
			banner.set_surface_override_material(surface,flag_cloth)
	banner.scale = Vector3.ONE * 1.1
	banner.rotation.y = PI / 2.0
	banner.position.y = 1.3
	group.add_child(banner)
	var transport := Node3D.new()
	transport.name = "RiverTransport"
	transport.hide()
	group.add_child(transport)
	var wood := StandardMaterial3D.new()
	wood.albedo_color = Color("65513a")
	for index in range(3):
		var boat := Node3D.new()
		boat.position = Vector3((index - 1) * 2.4, 0.0, abs(index - 1) * 1.5)
		transport.add_child(boat)
		var hull := MeshInstance3D.new()
		var shape := PrismMesh.new()
		shape.size = Vector3(1.5, 0.8, 4.8)
		shape.material = wood
		hull.mesh = shape
		hull.rotation.z = PI
		boat.add_child(hull)
		var deck := MeshInstance3D.new()
		var plank := BoxMesh.new()
		plank.size = Vector3(1.2, 0.15, 3.7)
		plank.material = wood
		deck.mesh = plank
		deck.position.y = 0.45
		boat.add_child(deck)
		var mast := MeshInstance3D.new()
		var pole := CylinderMesh.new()
		pole.height = 2.5
		pole.top_radius = 0.055
		pole.bottom_radius = 0.055
		pole.material = wood
		mast.mesh = pole
		mast.position.y = 1.5
		boat.add_child(mast)
		var sail := MeshInstance3D.new()
		var cloth := BoxMesh.new()
		cloth.size = Vector3(1.1, 1.6, 0.05)
		cloth.material = StandardMaterial3D.new()
		cloth.material.albedo_color = Color("d5c8a4")
		sail.mesh = cloth
		sail.position = Vector3(0.55, 1.7, 0.0)
		boat.add_child(sail)

func _update_siege_engines(group: Node3D, army: Dictionary) -> void:
	var count: int = preload("res://scripts/war/battle/troop_roles.gd").engine_count(army)
	var equipment: Node3D = group.get_node_or_null("SiegeEngines")
	if equipment == null:
		equipment = Node3D.new()
		equipment.name = "SiegeEngines"
		group.add_child(equipment)
	if int(equipment.get_meta("count",-1)) == count: return
	group.set_meta("siege_layout_revision",int(group.get_meta("siege_layout_revision",0))+1)
	for child in equipment.get_children(): equipment.remove_child(child); child.queue_free()
	equipment.set_meta("count",count)
	for i in range(mini(count,4)):
		var kind: String = preload("res://scripts/war/presentation/siege_visual.gd").KINDS[i % 2]
		var model: Node3D = preload("res://scripts/war/presentation/siege_visual.gd").create(kind)
		model.position = Vector3((i-(mini(count,4)-1)*0.5)*3.5,0,3.8)
		equipment.add_child(model)

func _set_flag(group: Node3D, faction: String, color: Color) -> void:
	var banner: MeshInstance3D = group.get_node("Banner")
	if banner.mesh == null: return
	var cloth: ShaderMaterial = banner.get_surface_override_material(0)
	if cloth == null: return
	if not flag_symbols.has(faction):
		var path := "res://assets/war/badges/flag-%s.png" % faction
		flag_symbols[faction] = load(path if ResourceLoader.exists(path) else "res://assets/war/badges/flag-unknown.png")
	cloth.set_shader_parameter("symbol",flag_symbols[faction])
	cloth.set_shader_parameter("faction_color",color)

func _build_march_route(id: String) -> void:
	var army: Dictionary = store.war.state[StateKeys.ARMIES].get(id,{})
	if not army.has("tactical") or not motion_start.has(id): return
	var path: Array = army["tactical"].get("move_path",[])
	if path.size() < 2 or motion_start[id].distance_squared_to(destinations[id]) < 0.01:
		march_exit_directions.erase(id)
		return
	var waypoints := PackedVector3Array([motion_start[id]])
	for i in range(1,path.size()-1): waypoints.append(_battle_point(int(path[i])))
	waypoints.append(destinations[id])
	var allowed := {}
	for cell in path: allowed[int(cell)] = true
	var exit_direction: Vector3 = (waypoints[waypoints.size()-1]-waypoints[waypoints.size()-2]).normalized()
	var goal: int = army["tactical"].get("previous_goal",path[path.size()-1])
	if goal != int(path[path.size()-1]):
		var toward: Vector3 = (_battle_point(goal)-destinations[id]).normalized()
		if exit_direction.dot(toward) > 0.0: exit_direction = (exit_direction+toward).normalized()
	var points := PackedVector3Array([waypoints[0]])
	for leg in range(waypoints.size()-1):
		var a := waypoints[leg]
		var b := waypoints[leg+1]
		var direction := (b-a).normalized()
		var incoming: Vector3 = march_exit_directions.get(id,direction) if leg == 0 else (b-waypoints[leg-1]).normalized()
		var outgoing := exit_direction if leg == waypoints.size()-2 else (waypoints[leg+2]-a).normalized()
		if incoming.dot(direction) <= 0.0: incoming = direction
		var span := a.distance_to(b)
		var segment := PackedVector3Array()
		var legal := true
		for sample in range(1,25):
			var t := float(sample)/24.0
			var t2 := t*t
			var t3 := t2*t
			var point := a*(2*t3-3*t2+1)+incoming*span*(t3-2*t2+t)+b*(-2*t3+3*t2)+outgoing*span*(t3-t2)
			if not allowed.has(HexPresentation.cell_at(point)): legal = false
			segment.append(point)
		# Keep the curve inside the checked route around walls and occupied cells.
		if not legal:
			segment.clear()
			for sample in range(1,25): segment.append(a.lerp(b,float(sample)/24.0))
			if leg == waypoints.size()-2: exit_direction = direction
		points.append_array(segment)
	var lengths := PackedFloat32Array([0.0])
	for i in range(1,points.size()): lengths.append(lengths[i-1]+points[i].distance_to(points[i-1]))
	march_routes[id] = {"points":points,"lengths":lengths}
	march_exit_directions[id] = exit_direction

func _update_special_troops(group: Node3D, bows: int, horses: int) -> void:
	if group.get_meta("special_counts",[]) == [bows,horses]: return
	group.set_meta("special_counts",[bows,horses])
	var archers: MultiMeshInstance3D = group.get_node_or_null("Archers")
	if archers != null:
		archers.multimesh.visible_instance_count = bows
		for i in range(bows):
			var offset := _troop_offset(group,i,"archers","idle")
			archers.multimesh.set_instance_transform(i,Transform3D(Basis.IDENTITY.scaled(Vector3.ONE*float(TROOP_KINDS["archers"]["scale"])),offset))
			archers.multimesh.set_instance_color(i,Color.WHITE)
			archers.multimesh.set_instance_custom_data(i,Color(float(i%12)/12,0.5,1,1))
	var cavalry: MultiMeshInstance3D = group.get_node_or_null("Mounted/Cavalry")
	if cavalry != null:
		cavalry.multimesh.visible_instance_count = horses
		for i in range(horses):
			cavalry.multimesh.set_instance_transform(i,Transform3D(Basis.IDENTITY.scaled(Vector3.ONE*float(TROOP_KINDS["cavalry"]["scale"])),_troop_offset(group,i,"cavalry","idle")))
			cavalry.multimesh.set_instance_color(i,Color.WHITE)
			cavalry.multimesh.set_instance_custom_data(i,Color(float(i%6)/6,0.5,1,1))

func _constrain_offset(group: Node3D, offset: Vector3, board: Dictionary) -> Vector3:
	if board.is_empty(): return offset
	var grid = store.war.Tactical.grid()
	for attempt in range(16):
		var point := group.position + group.basis * offset
		var cell: int = grid.pick(Vector2(point.x, point.z))
		if cell == grid.pick(Vector2(group.position.x,group.position.z)) and store.war.Tactical.in_battlefield(board, cell) and (not Fortifications.contains_point(board,Vector2(point.x,point.z)) or Fortifications.contains_point(board,Vector2(group.position.x,group.position.z))): return offset
		offset.x *= 0.8
		offset.z *= 0.8
	return Vector3(0, offset.y, 0)

func _apply_troop_detail(group: Node3D) -> bool:
	var distance: float = map.camera.global_position.distance_to(group.global_position)
	# Off-screen formations refresh on a slower cadence; on-screen ones react at once.
	if not _formation_on_screen(group.global_position) and animation_time-float(group.get_meta("detail_check_at",-100.0)) < 0.5 and absf(distance-float(group.get_meta("detail_distance",-1.0))) < 6.0:
		return false
	group.set_meta("detail_check_at",animation_time)
	group.set_meta("detail_distance",distance)
	var old: int = group.get_meta("detail_level",0)
	var level := old
	# Hysteresis prevents counts oscillating at a zoom boundary.
	if old == 0 and distance > 125: level = 1
	elif old == 1 and distance < 110: level = 0
	elif old == 1 and distance > 260: level = 2
	elif old == 2 and distance < 235: level = 1
	var kind := str(group.get_meta("troop_kind","infantry"))
	var ratio := _density_ratio(str(group.get_meta("army_id","")))
	var levels: Array = density_counts(kind)
	group.set_meta("detail_level",level)
	group.set_meta("density_ratio",ratio)
	var targets := {"Soldiers":0,"Archers":0,"Mounted/Cavalry":0}
	var batch_name := "Soldiers" if kind == "infantry" else "Archers" if kind == "archers" else "Mounted/Cavalry"
	targets[batch_name] = density_for_strength(int(levels[level]),ratio)
	var changed := false
	for name in targets:
		var batch: MultiMeshInstance3D = group.get_node_or_null(name)
		if batch == null: continue
		if batch.multimesh.visible_instance_count != int(targets[name]):
			changed = true
			batch.multimesh.visible_instance_count = int(targets[name])
	return changed

func _layout_formation(group: Node3D, count: int) -> void:
	var batch: MultiMeshInstance3D = group.get_node("Soldiers")
	var previous_count: int = group.get_meta("layout_count", 0)
	if previous_count == count: return
	group.set_meta("layout_count", count)
	var base_offsets: Array = []
	var random := RandomNumberGenerator.new()
	random.seed = hash(group.name)
	var radius: float = _troop_layout("infantry")["b"]
	for i in range(count):
		var offset := _troop_offset(group,i,"infantry","idle")
		var basis := Basis.IDENTITY.scaled(Vector3.ONE * float(TROOP_KINDS["infantry"]["scale"]))
		if i < previous_count: basis = batch.multimesh.get_instance_transform(i).basis
		var world_offset := group.basis * offset
		offset.y = map.height_at(group.position.x + world_offset.x, group.position.z + world_offset.z) - group.position.y + 0.2
		batch.multimesh.set_instance_transform(i, Transform3D(basis, offset))
		base_offsets.append(offset)
		var custom := Color(random.randf(), random.randf(), clampf((offset.z / maxf(radius, 0.1) + 0.25) * 1.5, 0, 1), 1)
		if i < previous_count: custom = batch.multimesh.get_instance_custom_data(i)
		batch.multimesh.set_instance_custom_data(i, custom)
		batch.multimesh.set_instance_color(i, Color.WHITE)
	group.set_meta("base_offsets", base_offsets)

func _update_city_breaches() -> void:
	for node in city_breaches:
		var active: bool = int(store.war.state.get(StateKeys.SIEGES, {}).get(node, {}).get("breach_cell", -1)) >= 0
		city_breaches[node]["root"].visible = active
		for material in city_breaches[node].get("materials", []): material.set_shader_parameter("breach_open", active)
	for node in store.war.state.get(StateKeys.SIEGES, {}):
		var siege: Dictionary = store.war.state[StateKeys.SIEGES][node]
		var cell := int(siege.get("breach_cell", -1))
		if cell < 0: continue
		var site := Fortifications.for_city(store, node)
		if site.is_empty(): continue
		if not city_breaches.has(node):
			var rubble := Node3D.new()
			rubble.name = "Breach_" + node
			add_child(rubble)
			var stone := StandardMaterial3D.new()
			stone.albedo_color = Color("6c6255")
			for index in range(12):
				var chunk := MeshInstance3D.new()
				var box := BoxMesh.new()
				box.size = Vector3(0.5 + index % 3 * 0.25, 0.45, 0.55)
				box.material = stone
				chunk.mesh = box
				chunk.position = Vector3((index % 4 - 1.5) * 0.8, 0.25, (index / 4 - 1) * 0.8)
				chunk.rotation = Vector3(index * 0.12, index * 1.2, index * 0.1)
				rubble.add_child(chunk)
			var banner := MeshInstance3D.new()
			var cloth := BoxMesh.new()
			cloth.size = Vector3(2, 1.5, 0.08)
			cloth.material = StandardMaterial3D.new()
			banner.mesh = cloth
			banner.position.y = 5
			rubble.add_child(banner)
			city_breaches[node] = {"root": rubble, "banner": banner}
		var record: Dictionary = city_breaches[node]
		record["root"].position = _battle_point(cell)
		var render_id := str(site["render_id"]) if site["native"] else str(site["id"])
		var wall := _city_wall(site, record["root"].global_position)
		wall.y = map.city_nodes[render_id].global_position.y if map.city_nodes.has(render_id) else map.height_at(wall.x, wall.z)
		var direction := ((wall - Vector3(site["point"].x, wall.y, site["point"].y)) * Vector3(1, 0, 1)).normalized()
		record["root"].global_position = wall
		if not record.has("materials") and map.city_nodes.has(render_id):
			record["materials"] = []
			for mesh_node in map.city_nodes[render_id].find_children("*", "MeshInstance3D", true, false):
				for surface in range(mesh_node.mesh.get_surface_count()):
					var original: Material = mesh_node.get_active_material(surface)
					var material := ShaderMaterial.new()
					material.shader = preload("res://shaders/city_breach.gdshader")
					if original is StandardMaterial3D:
						material.set_shader_parameter("albedo_texture", original.albedo_texture)
						material.set_shader_parameter("tint", original.albedo_color)
					mesh_node.set_surface_override_material(surface, material)
					record["materials"].append(material)
		for material in record.get("materials", []):
			material.set_shader_parameter("breach_center", wall)
			material.set_shader_parameter("breach_forward", direction)
			material.set_shader_parameter("breach_open", true)
		var faction: Dictionary = store.faction_for(node)
		record["banner"].mesh.material.albedo_color = Color(str(faction.get("color", "#a68962")))
