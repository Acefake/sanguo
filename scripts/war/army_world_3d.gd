extends Node3D

const CampaignUI = preload("res://scripts/war/campaign_ui.gd")
const Badge = preload("res://scripts/war/army_badge.gd")
const Chatter = preload("res://scripts/war/battle_chatter.gd")
var chatter_time := 0.0
var next_chatter_at := 0.8
var chatter_cooldowns := {}
var flag_symbols := {}
const MAX_SOLDIERS := 64
const CAVALRY_MODELS := 36
const Feedback = preload("res://scripts/war/battle_feedback.gd")
const DuelPresentation = preload("res://scripts/war/duel_gold_presentation.gd")
var advantage_panel: PanelContainer
var advantage_label: Label
var advantage_bar: ProgressBar
var loss_floaters: Array[Label3D] = []
var floated_tick := -1
var floated_armies: Dictionary = {}
var loss_contact_since: Dictionary = {}
var presentation_stats: Dictionary = {}
var map: Node3D
var store: Node
var ui: CanvasLayer
var layer: CanvasLayer
var formations: Dictionary = {}
var supply_markers: Dictionary = {}
var badges: Dictionary = {}
var destinations: Dictionary = {}
var points: Dictionary = {}
var city_aliases: Dictionary = {}
var mesh: Mesh
var march_meshes: Array[Mesh] = []
var idle_meshes: Array[Mesh] = []
var animation_time := 0.0
var portraits: Dictionary = {}
var textures: Dictionary = {}
var army_choice: OptionButton
var ground_timer := 0.0
var observed_enemies: Dictionary = {}
var combat_meshes: Array[Mesh] = []
var combat_effects: Node3D
var duel_presentation: CanvasLayer
var seen_duel_records: Dictionary = {}
var selected_enemy := ""
var pose_material: ShaderMaterial
var archer_mesh: Mesh
var archer_material: ShaderMaterial
var cavalry_mesh: Mesh
var cavalry_material: ShaderMaterial
var presenting := false
var presentation_elapsed := 0.0
var motion_start: Dictionary = {}
var motion_locations: Dictionary = {}
var city_breaches: Dictionary = {}
const DAY_SECONDS := 3.6
const CONTACT_SECONDS := 1.2
var presentation_duration := DAY_SECONDS
const Fortifications = preload("res://scripts/war/city_fortifications.gd")
const HexPresentation = preload("res://scripts/war/hex_presentation.gd")
const SiegeVisual = preload("res://scripts/war/siege_visual.gd")
var troop_pose_bounds: Dictionary = {}

func _ready() -> void:
	store = get_node("/root/GameState")
	store.war_presentation = self
	portraits = JSON.parse_string(FileAccess.get_file_as_string("res://data/officer_portraits.json"))
	var positions: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/war/world_3d_positions.json"))
	for id in positions["positions"]:
		var entry: Dictionary = positions["positions"][id]
		points[id] = Vector2(entry["x"], entry["z"])
	city_aliases = positions["city_aliases"]
	for site in Fortifications.sites(store).values():
		if site["id"] != "": points[site["id"]] = site["point"]
	_load_mesh()
	combat_effects = preload("res://scripts/war/combat_effects_3d.gd").new()
	combat_effects.height_at = map.height_at
	combat_effects.camera = map.camera
	add_child(combat_effects)
	layer = CanvasLayer.new()
	layer.layer = 3
	add_child(layer)
	duel_presentation = DuelPresentation.new()
	for record in store.war.state.get("duels", {}).get("records", []):
		seen_duel_records[_duel_record_key(record)] = true
	layer.add_child(duel_presentation)
	duel_presentation.effects = combat_effects
	ui = CampaignUI.new()
	ui.store = store
	ui.toolbar_offset = Vector2(16, 72)
	add_child(ui)
	ui.drawer.offset_top = 112
	ui.army_dispatched.connect(focus_army)
	army_choice = OptionButton.new()
	army_choice.position = Vector2(16, 208)
	army_choice.custom_minimum_size = Vector2(200, 32)
	army_choice.add_theme_font_override("font", preload("res://scripts/city_ui_skin.gd").font())
	army_choice.item_selected.connect(func(index):
		if index > 0: focus_army(str(army_choice.get_item_metadata(index)))
	)
	layer.add_child(army_choice)
	army_choice.hide()
	_build_battle_feedback()
	store.campaign_changed.connect(refresh)
	store.campaign_changed.connect(_refresh_enemy_panel)
	store.city_changed.connect(func(_id):
		if not store.busy: refresh()
	)
	refresh()
	if is_instance_valid(map.hex_world): map.hex_world.cell_selected.connect(_select_global_cell)
	if store.war.state.has("battlefield"): _create_supply_markers()
	if store.battle_test: call_deferred("_focus_battle")

func _focus_battle() -> void:
	var center := Vector3.ZERO
	for position in destinations.values(): center += position
	center /= maxf(destinations.size(), 1)
	map.camera_target = center
	map.target_goal = center
	map.distance = 180 if store.war.state.get("battlefield", {}).get("scenario_id", "") == "mountain_pass" else 100
	map.distance_goal = map.distance
	map.pitch = deg_to_rad(58)
	map._update_camera()

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
	for frame in frames: bounds = bounds.merge(frame.get_aabb())
	troop_pose_bounds[kind] = bounds

func _formation_moving(group: Node3D) -> bool:
	var id := str(group.get_meta("army_id",""))
	return presenting and presentation_elapsed < DAY_SECONDS and motion_start.has(id) and motion_start[id].distance_squared_to(destinations.get(id,motion_start[id])) > 0.01

func _fit_formation_to_hex(group: Node3D, moving: bool = false) -> void:
	var cell := HexPresentation.cell_at(group.global_position)
	if cell < 0: return
	var records: Array = []
	var envelope := PackedVector2Array()
	for spec in [["Soldiers","infantry",8,0.5,0.5,1.18],["Archers","archers",8,0.5,0.5,1.2],["Mounted/Cavalry","cavalry",6,0.85,1.25,0.72]]:
		var batch: MultiMeshInstance3D = group.get_node_or_null(spec[0])
		if batch == null or not troop_pose_bounds.has(spec[1]): continue
		var count := batch.multimesh.visible_instance_count
		if count < 0: count = batch.multimesh.instance_count
		var bounds: AABB = troop_pose_bounds[spec[1]]
		var columns: int = spec[2]
		var rows := ceili(float(count)/columns)
		for i in range(count):
			var basis := batch.multimesh.get_instance_transform(i).basis.orthonormalized().scaled(Vector3.ONE*float(spec[5]))
			var raw := Vector3((i%columns-(columns-1)*0.5)*float(spec[3]),0,(i/columns-(rows-1)*0.5)*float(spec[4]))
			var middle := bounds.get_center()*Vector3(1,0,1)
			var offset := raw-basis*middle
			records.append({"batch":batch,"index":i,"basis":basis,"offset":offset,"bounds":bounds})
			for corner in range(8):
				var point: Vector3 = group.basis*(offset+basis*bounds.get_endpoint(corner))
				envelope.append(Vector2(point.x,point.z))
	var equipment: Node3D = group.get_node_or_null("SiegeEngines")
	if equipment != null:
		var count := equipment.get_child_count()
		for engine in equipment.get_children():
			var i: int = engine.get_index()
			var basis: Basis = engine.basis.orthonormalized().scaled(Vector3.ONE*float(engine.get_meta("native_scale",1.0)))
			var bounds := SiegeVisual.pose_bounds(str(engine.get_meta("kind","catapult")))
			var raw := Vector3((i%2-(min(count,2)-1)*0.5)*3.0,0,(i/2-(ceili(float(count)/2)-1)*0.5)*3.0)
			var offset := raw
			records.append({"engine":engine,"basis":basis,"offset":offset})
			var radius := 0.0
			for corner in range(8):
				var point: Vector3 = basis*bounds.get_endpoint(corner)
				radius = maxf(radius,Vector2(point.x,point.z).length())
			# Engines aim independently from their final fitted positions; reserve
			# an orientation-independent envelope for every native mechanism pose.
			for corner in range(16):
				var angle := TAU*float(corner)/16
				var point: Vector3 = group.basis*(offset+Vector3(cos(angle),0,sin(angle))*radius*1.02)
				envelope.append(Vector2(point.x,point.z))
	if envelope.is_empty(): return
	var grid = store.war.Tactical.grid()
	var original := Vector2(group.global_position.x,group.global_position.z)
	var center: Vector2 = grid.center(cell)
	var anchor := original
	var centered := HexPresentation.fit_scale(cell,center,envelope)
	var size := HexPresentation.fit_scale(cell,anchor,envelope)
	# Keep every model and its attack poses together. Move an off-center layout
	# inward before it would collapse near a wall or during a hex transition.
	for attempt in range(8):
		if size >= centered*0.85: break
		anchor = anchor.lerp(center,0.4)
		size = HexPresentation.fit_scale(cell,anchor,envelope)
	if moving:
		# A moving formation traverses its route continuously. Re-centering on
		# each picked hex snapped every model at the boundary and shrank them.
		anchor = original
		size = float(group.get_meta("march_layout_scale",group.get_meta("formation_scale",centered)))
	var shift := group.basis.inverse()*Vector3(anchor.x-original.x,0,anchor.y-original.y)
	var render_bounds := {}
	for record in records:
		var offset: Vector3 = record["offset"]*size+shift
		var point: Vector3 = group.global_position+group.basis*offset
		offset.y = map.height_at(point.x,point.z)-group.global_position.y+0.2
		var transform := Transform3D(record["basis"].scaled(Vector3.ONE*size),offset)
		if record.has("batch"):
			var batch: MultiMeshInstance3D = record["batch"]
			batch.multimesh.set_instance_transform(record["index"],transform)
			var bounds: AABB = transform*record["bounds"]
			render_bounds[batch] = render_bounds[batch].merge(bounds) if render_bounds.has(batch) else bounds
		else: record["engine"].transform = transform
	for batch in render_bounds:
		# GPU pose interpolation can extend beyond the static rest mesh bounds.
		batch.multimesh.custom_aabb = render_bounds[batch].grow(0.20)
	group.set_meta("formation_cell",cell)
	group.set_meta("formation_scale",size)

func world_position(location: Dictionary) -> Vector3:
	var node: String = str(location.get("node", ""))
	var point: Vector2 = points.get(node, Vector2(1024, 1024))
	if str(location.get("edge", "")) != "":
		point = Fortifications.road_point(store, str(location.get("from", node)), str(location.get("to", node)), float(location.get("progress", 0)))
	else:
		var path := Fortifications.road_path(store, node, node)
		if not path.is_empty(): point = store.war.Tactical.grid().center(path[0])
	return Vector3(point.x, map.height_at(point.x, point.y) + 0.2, point.y)

func _battle_point(cell: int) -> Vector3:
	var point: Vector2 = map.hex_world.grid.center(cell)
	return Vector3(point.x, map.height_at(point.x, point.y) + 0.2, point.y)

func _wall_contact_point(army: Dictionary, center: Vector3) -> Vector3:
	var board: Dictionary = store.war.Tactical.board_for(store.war,army)
	if not board.has("fortifications") or preload("res://scripts/war/troop_roles.gd").kind(army) == "archers": return center
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
		var margin := 3.5 if preload("res://scripts/war/troop_roles.gd").kind(army) == "cavalry" else 2.5
		var desired := wall+(start-wall).normalized()*margin
		# Stay in the authoritative hex; exterior partial cells can approach the wall.
		for i in range(16):
			if store.war.Tactical.grid().pick(desired) == cell and not Geometry2D.is_point_in_polygon(desired,polygon):
				return Vector3(desired.x,map.height_at(desired.x,desired.y)+0.2,desired.y)
			desired = desired.lerp(start,0.2)
	return center

func _select_global_cell(cell: int, preview: bool) -> void:
	if preview: return
	for id in formations:
		var army: Dictionary = store.war.state["armies"].get(id, {})
		if not army.has("tactical") or int(army["tactical"]["cell"]) != cell: continue
		if army["faction"] == store.war.state["player_faction"]: ui.show_army(id)
		elif observed_enemies.has(id): show_enemy(id)
		return

func _create_supply_markers() -> void:
	if not store.war.supply_enabled(): return
	for corps in store.war.state["corps"].values():
		if int(corps["supply"]["cell"]) < 0: continue
		var marker := Label.new()
		marker.add_theme_font_override("font", preload("res://scripts/city_ui_skin.gd").font())
		marker.add_theme_font_size_override("font_size", 14)
		marker.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var style := StyleBoxFlat.new()
		style.bg_color = Color(0.07, 0.10, 0.06, 0.85)
		style.set_content_margin_all(5)
		marker.add_theme_stylebox_override("normal", style)
		marker.set_meta("anchor", _battle_point(int(corps["supply"]["cell"])) + Vector3(0, 4, 0))
		layer.add_child(marker)
		supply_markers[corps["id"]] = marker
	_refresh_supplies()

func _refresh_supplies() -> void:
	for id in supply_markers:
		var corps: Dictionary = store.war.state["corps"].get(id, {})
		if corps.is_empty(): supply_markers[id].hide(); continue
		var known: bool = corps["faction"] == store.war.state["player_faction"] or store.battle_test
		for own in store.war.state["corps"].values():
			if own["faction"] == store.war.state["player_faction"] and own["known_supplies"].has(id): known = true
		supply_markers[id].set_meta("known", known and not corps.get("ended", false))
		supply_markers[id].visible = known and not corps.get("ended", false)
		var blocked: bool = int(corps["supply"]["blocked_until"]) > int(store.war.state["tick"])
		supply_markers[id].text = "%s粮道\n%s" % [corps["name"], "截断" if blocked else "畅通"]
		supply_markers[id].modulate = Color("ed7354") if blocked else Color("f1d888")

func refresh() -> void:
	_update_city_breaches()
	_refresh_battle_feedback()
	_refresh_supplies()
	var active: Dictionary = {}
	army_choice.clear()
	army_choice.add_item("前往在外军队")
	var entries: Array = store.war.active_armies(str(store.war.state["player_faction"]))
	observed_enemies.clear()
	var squad_numbers := {}
	for army in entries:
		for id in army["intel"]["enemies"]:
			var observed: Dictionary = army["intel"]["enemies"][id]
			if not observed_enemies.has(id) or int(observed["observed_at"]) > int(observed_enemies[id]["observed_at"]): observed_enemies[id] = observed
	for observed in observed_enemies.values():
		var entry := {"id": observed["id"], "name": "敌军", "faction": "observed_enemy", "location": observed["location"], "strength_estimate": observed["strength_estimate"], "morale": 0, "returning": observed["routing"], "units": observed.get("unit_mix_estimate", {})}
		if int(observed.get("tactical_cell", -1)) >= 0: entry["tactical"] = {"cell": int(observed["tactical_cell"])}
		entries.append(entry)
	if store.battle_test:
		entries = []
		for original in store.war.active_armies():
			var entry: Dictionary = original.duplicate(false)
			if original["faction"] != store.war.state["player_faction"]:
				entry["faction"] = "observed_enemy"
				entry["strength_estimate"] = store.war.Combat.strength(original)
			entries.append(entry)
	if not store.war.state.has("battlefield"):
		var grouped: Array = []
		for entry in entries:
			if entry.has("tactical"): grouped.append(entry); continue
			var corps: Dictionary = store.war.state["corps"].get(entry.get("corps_id", ""), {})
			if not corps.is_empty():
				if entry["id"] != corps["root_id"]: continue
				entry = entry.duplicate(false)
				entry["display_strength"] = store.war.Corps.summary(store.war, corps)["strength"]
				entry["name"] = corps["name"]
			grouped.append(entry)
		entries = grouped
	for army in entries:
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
		var badge: Control = badges[id]
		badge.title = str(army["name"])
		badge.portrait = _portrait(str(store.war.roster.officers.get(army.get("officer_id", ""), {}).get("name", army["name"])))
		badge.commander = str(store.war.roster.officers.get(army.get("officer_id", ""), {}).get("name", army["name"]))
		badge.commander_state = "战死" if army.get("commander_unavailable", false) and army.get("commander_fate", {}).get("status", "") == "dead" else "被俘" if army.get("commander_unavailable", false) else ""
		if str(army["location"].get("edge", "")) != "":
			var direction: Vector2 = points.get(str(army["location"].get("to", "")), Vector2.ZERO) - points.get(str(army["location"].get("from", "")), Vector2.ZERO)
			if direction.length_squared() > 0.01: formations[id].set_meta("march_heading", atan2(direction.x, direction.y))
		if army.has("tactical"):
			var direction: Vector3 = target - formations[id].position
			if direction.length_squared() > 0.01: formations[id].set_meta("march_heading", atan2(direction.x, direction.z))
		var operation: Dictionary = army.get("operation", {})
		badge.tooltip_text = preload("res://scripts/ui_text.gd").clean("%s  %s\n%s" % [army["name"], preload("res://scripts/war/tactical_battlefield.gd").ROLES.get(operation.get("role", ""), "自主行动"), army.get("tactical", {}).get("phase", "")])
		badge.strength = int(army["strength_estimate"]) if enemy else int(army.get("display_strength", store.war.Combat.strength(army)))
		badge.estimated = enemy and not store.battle_test
		badge.morale = float(army["morale"])
		var badge_side := str(army["faction"])
		squad_numbers[badge_side] = int(squad_numbers.get(badge_side, 0)) + 1
		badge.squad_number = int(squad_numbers[badge_side])
		badge.hostile = enemy or store.war.hostile(str(store.war.state["player_faction"]), badge_side)
		badge.faction_color = Color("c86650") if enemy else Color(str(store.scenario["factions"].get(army["faction"], {}).get("color", "#8ac56b")))
		badge.queue_redraw()
		var batch: MultiMeshInstance3D = formations[id].get_node_or_null("Soldiers")
		if batch != null:
			var group: Node3D = formations[id]
			var types: Dictionary = army.get("units", {})
			# Fixed formations represent the dominant troop type. Strength remains
			# in the badge and combat ledger, never in the rendered model count.
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
			if enemy and store.battle_test: flag_faction = str(store.war.state["armies"][id]["faction"])
			var flag_color := Color(str(store.scenario["factions"].get(flag_faction, {}).get("color", "#c86650")))
			_set_flag(group, flag_faction, flag_color)
			_update_siege_engines(group, army)
			_fit_formation_to_hex(group,_formation_moving(group))
	for id in formations.keys():
		if not active.has(id):
			if presenting:
				var ended: Dictionary = store.war.state["armies"].get(id, {})
				if not ended.is_empty(): destinations[id] = _battle_point(int(ended["tactical"]["cell"])) if ended.has("tactical") else world_position(ended["location"])
				continue
			formations[id].queue_free()
			badges[id].queue_free()
			formations.erase(id)
			chatter_cooldowns.erase(id)
			badges.erase(id)
			destinations.erase(id)

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
	var count: int = preload("res://scripts/war/troop_roles.gd").engine_count(army)
	var equipment: Node3D = group.get_node_or_null("SiegeEngines")
	if equipment == null:
		equipment = Node3D.new()
		equipment.name = "SiegeEngines"
		group.add_child(equipment)
	if int(equipment.get_meta("count",-1)) == count: return
	for child in equipment.get_children(): equipment.remove_child(child); child.queue_free()
	equipment.set_meta("count",count)
	for i in range(mini(count,4)):
		var kind: String = preload("res://scripts/war/siege_visual.gd").KINDS[i % 2]
		var model: Node3D = preload("res://scripts/war/siege_visual.gd").create(kind)
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

func _speech_event(id: String) -> String:
	if observed_enemies.has(id) and not store.battle_test:
		var sight: Dictionary = observed_enemies[id]
		if int(sight.get("observed_at",-1)) != int(store.war.state["tick"]): return ""
		if sight.get("routing",false): return "retreat"
		return "attack" if sight.get("fighting",false) else "hold"
	var army: Dictionary = store.war.state["armies"].get(id,{})
	if army.is_empty() or army.get("commander_unavailable",false): return ""
	if army.get("returning",false): return "retreat"
	if army.get("action",{}).get("type","") == "evade": return "evade"
	if float(army.get("morale",100)) < 35: return "rally"
	if int(army.get("combat_tick",-1)) == int(store.war.state["tick"]):
		var front: Dictionary = _combat_visual(id)
		if front.get("siege",false): return "siege"
		return "ranged" if front.get("ranged",false) else "attack"
	if str(army.get("location",{}).get("edge","")) != "" or (presenting and motion_start.has(id) and motion_start[id].distance_squared_to(destinations.get(id,motion_start[id])) > 0.01): return "march"
	return "hold"

func _update_chatter(force: bool = false) -> void:
	var speaking: Array = []
	for id in badges:
		var badge: Control = badges[id]
		if not badge.speech.is_empty() and chatter_time >= badge.speech_until: badge.set_speech("",0)
		if not badge.speech.is_empty(): speaking.append(id)
	if speaking.size() >= 2 or (not force and chatter_time < next_chatter_at): return
	var candidates: Array = []
	for id in formations:
		var badge: Control = badges[id]
		if not formations[id].visible or not badge.visible or not badge.speech_visible: continue
		if not get_viewport().get_visible_rect().intersects(Rect2(badge.position,badge.size*badge.scale)): continue
		if speaking.has(id) or float(chatter_cooldowns.get(id,-100.0)) > chatter_time: continue
		if speaking.any(func(other): return badges[other].position.distance_to(badge.position) < 155): continue
		var event := _speech_event(id)
		if not event.is_empty(): candidates.append({"id":id,"event":event,"priority":0 if event not in ["hold","march"] else 1,"order":absi(hash(str(id)+str(store.war.state["tick"])+str(floori(chatter_time/3.2))))})
	candidates.sort_custom(func(a,b): return a["priority"] < b["priority"] if a["priority"] != b["priority"] else a["order"] < b["order"])
	next_chatter_at = chatter_time + (3.2 if not candidates.is_empty() else 0.8)
	if candidates.is_empty(): return
	var choice: Dictionary = candidates[0]
	var badge: Control = badges[choice["id"]]
	badge.set_speech(Chatter.line_for(badge.commander,choice["event"],choice["order"]),chatter_time+4.5)
	chatter_cooldowns[choice["id"]] = chatter_time+12.0

func _march_position(id: String, progress: float) -> Vector3:
	var before: Dictionary = motion_locations.get(id, {})
	var army: Dictionary = store.war.state["armies"].get(id, {})
	var sight: Dictionary = observed_enemies.get(id, {}) if not store.battle_test else {}
	var tactical: bool = int(sight.get("tactical_cell", -1)) >= 0 if not sight.is_empty() else army.has("tactical")
	if tactical and sight.is_empty():
		var path: Array = army.get("tactical",{}).get("move_path",[])
		if path.size() > 2:
			var cursor := clampf(progress,0,1)*float(path.size()-1)
			var leg := mini(floori(cursor),path.size()-2)
			var a: Vector3 = motion_start[id] if leg == 0 else _battle_point(int(path[leg]))
			var b: Vector3 = destinations[id] if leg == path.size()-2 else _battle_point(int(path[leg+1]))
			return a.lerp(b,cursor-float(leg))
	if tactical or before.is_empty(): return motion_start[id].lerp(destinations[id], progress)
	var after: Dictionary = sight.get("location", {}) if not sight.is_empty() else army.get("location", {})
	var old_edge := str(before.get("edge", ""))
	var new_edge := str(after.get("edge", ""))
	var location: Dictionary = after.duplicate(true)
	if new_edge != "" and (old_edge == "" or old_edge == new_edge):
		var start := float(before.get("progress", 0.0)) if old_edge != "" else 0.0
		if old_edge != "" and before.get("from", "") != after.get("from", ""): start = 1.0 - start
		location["progress"] = lerpf(start, float(after["progress"]), progress)
		return world_position(location)
	if old_edge != "" and new_edge == "" and after.get("node", "") == before.get("to", ""):
		location = before.duplicate(true)
		location["progress"] = lerpf(float(before["progress"]), 1.0, progress)
		return world_position(location)
	return motion_start[id].lerp(destinations[id], progress)

func _update_special_troops(group: Node3D, bows: int, horses: int) -> void:
	var archers: MultiMeshInstance3D = group.get_node_or_null("Archers")
	if archers != null:
		archers.multimesh.visible_instance_count = bows
		for i in range(bows):
			var offset := Vector3((i % 8 - 3.5)*0.5,0, (i/8 - 3.5)*0.5)
			archers.multimesh.set_instance_transform(i,Transform3D(Basis.IDENTITY.scaled(Vector3.ONE*1.2),offset))
			archers.multimesh.set_instance_color(i,Color.WHITE)
			archers.multimesh.set_instance_custom_data(i,Color(float(i%12)/12,0.5,1,1))
	var cavalry: MultiMeshInstance3D = group.get_node_or_null("Mounted/Cavalry")
	if cavalry != null:
		cavalry.multimesh.visible_instance_count = horses
		for i in range(horses):
			cavalry.multimesh.set_instance_transform(i,Transform3D(Basis.IDENTITY.scaled(Vector3.ONE*.72),Vector3((i%6-2.5)*.85,0,(i/6-2.5)*1.25)))
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

func _layout_formation(group: Node3D, count: int) -> void:
	var batch: MultiMeshInstance3D = group.get_node("Soldiers")
	var previous_count: int = group.get_meta("layout_count", 0)
	if previous_count == count: return
	group.set_meta("layout_count", count)
	var base_offsets: Array = []
	var random := RandomNumberGenerator.new()
	random.seed = hash(group.name)
	var radius := 2.7
	for i in range(count):
		var offset := Vector3((i%8-3.5)*.5,0,(i/8-3.5)*.5)
		var size_value := 1.18
		var basis := Basis.IDENTITY.scaled(Vector3.ONE * size_value)
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


func _portrait(name: String) -> Texture2D:
	if textures.has(name): return textures[name]
	var path: String = str(portraits.get(name, {}).get("unit_portrait", portraits.get(name, {}).get("portrait", "")))
	var texture: Texture2D = null
	if FileAccess.file_exists(path): texture = load(path)
	textures[name] = texture
	return texture

func _process(delta: float) -> void:
	_present_new_duel()
	var duel_shown: bool = duel_showing()
	if duel_shown: return
	if map == null or map.camera == null: return
	ground_timer += delta
	if not store.time_paused:
		animation_time += delta * store.time_scale
		if not duel_shown: chatter_time += delta
		if presenting: presentation_elapsed += delta * store.time_scale
	var update_ground: bool = ground_timer >= 0.15
	if update_ground: ground_timer = 0.0
	combat_effects.begin_frame()
	for id in formations:
		var group: Node3D = formations[id]
		if presenting and motion_start.has(id):
			group.position = _march_position(id, clampf(presentation_elapsed / DAY_SECONDS, 0, 1))
		group.position.y = map.height_at(group.position.x, group.position.z) + 0.2
		var unit: Dictionary = store.war.state["armies"].get(id, {})
		if not store.time_paused and _formation_moving(group):
			var progress := clampf(presentation_elapsed / DAY_SECONDS,0,1)
			var tangent := (_march_position(id,minf(1,progress+0.01))-_march_position(id,maxf(0,progress-0.01)))*Vector3(1,0,1)
			if tangent.length_squared() > 0.01: group.set_meta("march_heading",atan2(tangent.x,tangent.z))
			var facing := float(group.get_meta("march_heading",group.rotation.y))
			group.rotation.y = lerp_angle(group.rotation.y,facing,minf(delta*store.time_scale*8.0,1.0))
		elif presenting and not store.time_paused:
			var engaged := _combat_visual(id)
			if not engaged.is_empty(): group.rotation.y = lerp_angle(group.rotation.y,_yaw_between(group.global_position,engaged["target"]),minf(delta*store.time_scale*8.0,1.0))
		var cell: int = store.war.Tactical.grid().pick(Vector2(group.position.x, group.position.z))
		var afloat: bool = not unit.has("tactical") and store.war.Tactical.grid().terrain(cell) in Fortifications.WATER_CODES
		var boats: Node3D = group.get_node_or_null("RiverTransport")
		if boats != null: boats.visible = afloat
		if afloat: group.position.y = maxf(group.position.y, map.WATER_LEVEL + 0.45)
		var pose_batch: MultiMeshInstance3D = group.get_node_or_null("Soldiers")
		if pose_batch != null: pose_batch.visible = not afloat
		if pose_batch != null: pose_batch.material_override.set_shader_parameter("animation_clock", animation_time)
		var bow_batch: MultiMeshInstance3D = group.get_node_or_null("Archers")
		if bow_batch != null: bow_batch.visible = not afloat
		var cavalry: Node3D = group.get_node_or_null("Mounted")
		if cavalry != null: cavalry.visible = not afloat
		var cavalry_batch: MultiMeshInstance3D = group.get_node_or_null("Mounted/Cavalry")
		if cavalry_batch != null: cavalry_batch.material_override.set_shader_parameter("animation_clock", animation_time)
		if bow_batch != null: bow_batch.material_override.set_shader_parameter("animation_clock", animation_time)
		if update_ground and not store.time_paused:
			var batch: MultiMeshInstance3D = group.get_node_or_null("Soldiers")
			if batch != null:
				var army: Dictionary = {} if observed_enemies.has(id) and not store.battle_test else store.war.state["armies"].get(id, {})
				if observed_enemies.has(id) and not store.battle_test:
					var observed: Dictionary = observed_enemies[id]
					army = {"location": observed["location"], "combat_tick": int(store.war.state["tick"]) if observed.get("fighting", false) else -1, "action": {"type": "continue" if observed["routing"] else "hold"}}
				var marching: bool = str(army.get("location", {}).get("edge", "")) != "" and str(army.get("action", {}).get("type", "")) in ["march", "continue", "withdraw"]
				if army.has("tactical") and motion_start.has(id):
					marching = _formation_moving(group)
				var fighting: bool = not _combat_visual(id).is_empty()
				if presenting and fighting and not combat_meshes.is_empty():
					_set_pose(batch, 9, combat_meshes.size(), 6.5)
				elif presenting and marching and not march_meshes.is_empty():
					_set_pose(batch, 1, march_meshes.size(), 6.5)
				elif not idle_meshes.is_empty():
					# Standing armies breathe and shift instead of freezing on one pose.
					_set_pose(batch, 1 + march_meshes.size() + combat_meshes.size(), idle_meshes.size(), 2.2)
				else:
					_set_pose(batch, 0, 1, 0.0)
				# Turn the whole formation onto its engagement or march heading so
				# the soldiers' +Z front matches what the army is actually doing.
				var facing := INF
				var engaged: Dictionary = _combat_visual(id) if fighting else {}
				if not engaged.is_empty(): facing = _yaw_between(group.global_position, engaged["target"])
				if is_inf(facing) and marching: facing = float(group.get_meta("march_heading", INF))
				if bow_batch != null:
					_set_pose(bow_batch,9,12,6.5) if presenting and fighting else _set_pose(bow_batch,1,8,6.5) if presenting and marching else _set_pose(bow_batch,21,8,2.2)
				if cavalry_batch != null:
					_set_pose(cavalry_batch,9,12,6.0) if presenting and fighting else _set_pose(cavalry_batch,1,8,3.2) if presenting and marching else _set_pose(cavalry_batch,21,8,4.0)
				if not engaged.is_empty(): SiegeVisual.aim(group.get_node_or_null("SiegeEngines"),engaged["target"])
				_fit_formation_to_hex(group,_formation_moving(group))

		if presenting and group.visible:
			var visual: Dictionary = _combat_visual(id)
			var moving: bool = _formation_moving(group)
			SiegeVisual.animate(group.get_node_or_null("SiegeEngines"), animation_time, not visual.is_empty(), moving)
			if not visual.is_empty():
				var fronts: Array = _combat_fronts(id)
				for front in fronts:
					var target_cell: int = front.get("target_cell",HexPresentation.cell_at(front["target"]))
					if front["ranged"] and group.get_node("Archers").multimesh.visible_instance_count > 0:
						combat_effects.show_archer_volley(front["key"],group,front["target"],animation_time,target_cell)
					else:
						combat_effects.show_contact(front["key"], group.global_position, front["target"], animation_time, front["siege"], front["ranged"], _formation_radius(group), front.get("duel",false),1.55,target_cell)
					if group.get_node_or_null("SiegeEngines") != null:
						combat_effects.show_siege_projectiles(front["key"],group.get_node_or_null("SiegeEngines"),front["target"],animation_time,target_cell)
				if not store.time_paused: _face_contact_sectors(group, fronts, delta * minf(store.time_scale, 2.0))
			elif not store.time_paused and _formation_moving(group):
				_face_contact_sectors(group, [{"target": group.global_position + Vector3(sin(float(group.get_meta("march_heading",0.0))),0,cos(float(group.get_meta("march_heading",0.0)))) * 100}], delta * minf(store.time_scale, 2.0))
		var toward_camera: Vector3 = ((map.camera.global_position-group.global_position)*Vector3(1,0,1)).normalized()
		var anchor: Vector3 = group.global_position + toward_camera * 2.7 + Vector3.UP * 0.3
		var badge: Control = badges[id]
		badge.scale = Vector2.ONE * Badge.camera_scale(map.camera.global_position.distance_to(anchor))
		var speech_detail: bool = badge.scale.x >= 0.34
		if badge.speech_visible != speech_detail:
			badge.speech_visible = speech_detail
			badge.queue_redraw()
		badge.visible = not map.camera.is_position_behind(anchor)
		if badge.visible: badge.position = map.camera.unproject_position(anchor) - Vector2(59, 55) * badge.scale
		# Keep individual models hidden at overview distances; badges stay readable.
		group.visible = map.camera.global_position.distance_to(group.global_position) < 550
	if not store.time_paused and not duel_shown: _update_chatter()
	_show_city_volleys()
	combat_effects.end_frame()
	for marker in supply_markers.values():
		var anchor: Vector3 = marker.get_meta("anchor")
		marker.visible = marker.get_meta("known", false) and not map.camera.is_position_behind(anchor)
		if marker.visible:
			var projected: Vector2 = map.camera.unproject_position(anchor)
			# Briefly suppress overlapping supply captions while a duel is shown.
			for duel in combat_effects.duels.values():
				var label_point: Vector2 = map.camera.unproject_position(duel["title"].global_position)
				if absf(projected.x - label_point.x) < 160 and absf(projected.y - label_point.y) < 65: marker.visible = false
			var viewport: Vector2 = get_viewport().get_visible_rect().size
			marker.position = Vector2(clampf(projected.x - marker.size.x / 2, 12, viewport.x - marker.size.x - 12), clampf(projected.y - marker.size.y / 2, 205, viewport.y - 110))
	if presenting: _spawn_loss_floaters()
	_update_display_stats()
	_update_loss_floaters(delta)
	if presenting and presentation_elapsed >= presentation_duration:
		presenting = false
		motion_start.clear()
		refresh()

func _present_new_duel() -> void:
	if not is_instance_valid(duel_presentation) or store == null or store.war == null: return
	if duel_presentation.visible: return
	var records: Array = store.war.state.get("duels", {}).get("records", [])
	for record in records:
		var key := _duel_record_key(record)
		if seen_duel_records.has(key): continue
		seen_duel_records[key] = true
		var player_involved: bool = store.battle_test
		for army in store.war.state.get("armies", {}).values():
			if army.get("officer_id", "") in [record.get("a", ""), record.get("b", "")] and army.get("faction", "") == store.war.state["player_faction"]:
				player_involved = true
		if not player_involved: continue
		var officers: Dictionary = store.war.roster.officers
		var left: Dictionary = officers.get(str(record.get("a", "")), {})
		var right: Dictionary = officers.get(str(record.get("b", "")), {})
		if left.is_empty() or right.is_empty(): continue
		duel_presentation.demo = false
		_bind_duel_positions(record)
		duel_presentation.present_record(record, left, right, _portrait(str(left.get("name", ""))), _portrait(str(right.get("name", ""))))
		break

func _duel_record_key(record: Dictionary) -> String:
	return "%s:%s:%s" % [record.get("tick", -1), record.get("a", ""), record.get("b", "")]

func duel_showing() -> bool:
	return is_instance_valid(duel_presentation) and duel_presentation.visible

func duel_active() -> bool:
	# Drain pending duel results before resuming battle progression.
	_present_new_duel()
	return duel_showing()

func _bind_duel_positions(record: Dictionary) -> void:
	var anchors: Array[Vector3] = []
	for officer_id in [record.get("a", ""), record.get("b", "")]:
		for army in store.war.state.get("armies", {}).values():
			if army.get("officer_id", "") == officer_id:
				anchors.append(formations[army["id"]].global_position if formations.has(army["id"]) else world_position(army["location"]))
				break
	if anchors.size() < 2:
		anchors.clear()
		for formation in formations.values():
			anchors.append(formation.global_position)
			if anchors.size() == 2: break
	if anchors.is_empty(): anchors.append(Vector3.ZERO)
	duel_presentation.source = anchors[0]
	duel_presentation.target = anchors[1] if anchors.size() > 1 else anchors[0] + Vector3(3, 0, 0)

func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F8:
		preview_duel()
		get_viewport().set_input_as_handled()

func preview_duel() -> void:
	if duel_active(): return
	var match_data: Dictionary = preload("res://scripts/war/duel_preview_data.gd").build(store.war)
	duel_presentation.demo = true
	_bind_duel_positions(match_data["record"])
	duel_presentation.present_record(match_data["record"], match_data["left"], match_data["right"], _portrait(match_data["left"]["name"]), _portrait(match_data["right"]["name"]))

func _yaw_between(from: Vector3, to: Vector3) -> float:
	var direction: Vector3 = to - from
	return INF if direction.length_squared() < 0.01 else atan2(direction.x, direction.z)

func _formation_radius(group: Node3D) -> float:
	var radius := 3.3 if str(group.get_meta("troop_kind","infantry")) == "cavalry" else 2.7
	return radius*float(group.get_meta("formation_scale",1.0))

func _combat_fronts(id: String) -> Array:
	var primary: Dictionary = _combat_visual(id)
	if primary.is_empty(): return []
	var fronts: Array = [primary.duplicate()]
	fronts[0]["key"] = id
	if primary["siege"] or primary["ranged"]: return fronts
	var army: Dictionary = store.war.state["armies"].get(id, {})
	if not army.has("tactical"): return fronts
	for enemy_id in formations:
		var enemy: Dictionary = store.war.state["armies"].get(enemy_id, {})
		if enemy.is_empty() or enemy["faction"] == army["faction"] or not enemy.has("tactical"): continue
		if not store.battle_test and enemy["faction"] != store.war.state["player_faction"]:
			var seen: Dictionary = observed_enemies.get(enemy_id, {})
			if int(seen.get("observed_at", -1)) != int(store.war.state["tick"]) or not seen.get("fighting", false): continue
		if int(enemy.get("combat_tick", -1)) != int(store.war.state["tick"]) or enemy["tactical"].get("attack_target", "") != id: continue
		if store.war.Tactical.distance(army, enemy) > 1: continue
		var target: Vector3 = formations[enemy_id].global_position
		var source: Vector3 = formations[id].global_position
		if store.war.Tactical.grid().distance(store.war.Tactical.grid().pick(Vector2(source.x,source.z)),store.war.Tactical.grid().pick(Vector2(target.x,target.z))) != 1: continue
		if target.distance_squared_to(primary["target"]) < 0.01: continue
		fronts.append({"key": id + ":contact:" + enemy_id, "target": target, "siege": false, "ranged": false})
	return fronts

func _face_contact_sectors(group: Node3D, fronts: Array, delta: float = 1.0 / 60.0) -> void:
	var batch: MultiMeshInstance3D = group.get_node_or_null("Soldiers")
	if batch == null: return
	for i in range(batch.multimesh.visible_instance_count):
		var transform := batch.multimesh.get_instance_transform(i)
		var offset := Vector3(transform.origin.x, 0, transform.origin.z)
		var best := -INF
		var heading := Vector3.BACK
		for front in fronts:
			var toward: Vector3 = group.basis.inverse() * (front["target"] - group.global_position)
			toward.y = 0
			toward = toward.normalized()
			var score := offset.normalized().dot(toward)
			if score > best: best = score; heading = toward
		var current := atan2(transform.basis.z.x, transform.basis.z.z)
		var goal := atan2(heading.x, heading.z)
		var turn := clampf(wrapf(goal - current, -PI, PI), -3.5 * delta, 3.5 * delta)
		transform.basis = Basis(Vector3.UP, current + turn).scaled(transform.basis.get_scale())
		batch.multimesh.set_instance_transform(i, transform)
		var data := batch.multimesh.get_instance_custom_data(i)
		data.b = clampf(best, 0.0, 1.0)
		batch.multimesh.set_instance_custom_data(i, data)
	_fit_formation_to_hex(group,_formation_moving(group))

func _combat_visual(id: String) -> Dictionary:
	if presenting and motion_start.has(id) and not _at_display_destination(id): return {}
	var army: Dictionary = store.war.state["armies"].get(id, {})
	if army.is_empty(): return {}
	var observed: bool = observed_enemies.has(id) and not store.battle_test
	if observed:
		var sight: Dictionary = observed_enemies[id]
		if not sight.get("fighting", false) or int(sight.get("observed_at", -1)) != int(store.war.state["tick"]): return {}
	elif int(army.get("combat_tick", -1)) != int(store.war.state["tick"]): return {}
	if store.war.Terrain.entry_factor(army,store.war.rules) <= 0: return {}
	if int(army.get("duel_tick",-1)) == int(store.war.state["tick"]) and formations.has(army.get("duel_opponent","")):
		var opponent: String = army["duel_opponent"]
		var source: Vector3 = formations[id].global_position
		var destination: Vector3 = formations[opponent].global_position
		var shown_gap: int = store.war.Tactical.grid().distance(store.war.Tactical.grid().pick(Vector2(source.x,source.z)),store.war.Tactical.grid().pick(Vector2(destination.x,destination.z)))
		if shown_gap != 1: return {}
		return {"target":formations[army["duel_opponent"]].global_position,"siege":false,"ranged":false,"duel":true}
	if not observed:
		var siege: Dictionary = store.war.state.get("sieges", {}).get(army["target"], {})
		if siege.get("phase", "") == "强攻" and int(siege.get("active_tick", -1)) == int(store.war.state["tick"]) and siege.get("participants", []).has(id):
			var board: Dictionary = store.war.Tactical.board_for(store.war,army)
			var visible_cell: int = store.war.Tactical.grid().pick(Vector2(formations[id].position.x,formations[id].position.z))
			if Fortifications.distance_to_wall(board,str(army["target"]),visible_cell) > store.war.Tactical.attack_range(army): return {}
			var cell: int = store.war.Tactical.board_for(store.war, army).get("objectives", {}).get(army["target"], -1)
			var target := _battle_point(cell) if cell >= 0 else world_position({"node": army["target"], "edge": ""})
			var site := Fortifications.for_city(store,str(army["target"]))
			var outline := Fortifications.footprint(site)
			if not outline.is_empty():
				var origin := Vector2(formations[id].global_position.x,formations[id].global_position.z)
				var closest := Vector2(target.x,target.z)
				for index in range(outline.size()):
					var point := Geometry2D.get_closest_point_to_segment(origin,outline[index],outline[(index+1)%outline.size()])
					if point.distance_squared_to(origin) < closest.distance_squared_to(origin): closest = point
				# Attack the wall immediately in front, not the city center behind it.
				closest += (Vector2(target.x,target.z)-closest).normalized()*0.30
				target = Vector3(closest.x,map.height_at(closest.x,closest.y),closest.y)
			return {"target": target,"target_cell":HexPresentation.cell_at(target), "siege": true, "ranged": preload("res://scripts/war/troop_roles.gd").kind(army) == "archers"}
		var enemy: String = army.get("tactical", {}).get("attack_target", army.get("action", {}).get("enemy", ""))
		if formations.has(enemy):
			if presenting and motion_start.has(enemy) and not _at_display_destination(enemy): return {}
			var target_army: Dictionary = store.war.state["armies"][enemy]
			var reach := 1
			if army.has("tactical") and target_army.has("tactical"):
				reach = store.war.Tactical.attack_range(army)
				if store.war.Tactical.distance(army,target_army) > reach: return {}
			elif army.has("tactical") or target_army.has("tactical"): return {}
			var visible_gap: int = store.war.Tactical.cell_distance(store.war.Tactical.grid().pick(Vector2(formations[id].position.x,formations[id].position.z)),store.war.Tactical.grid().pick(Vector2(formations[enemy].position.x,formations[enemy].position.z)))
			if visible_gap < 1 or visible_gap > reach: return {}
			var target_cell := HexPresentation.cell_at(formations[enemy].global_position)
			if target_army.has("tactical") and target_cell != int(target_army["tactical"]["cell"]): return {}
			return {"target": formations[enemy].global_position,"target_cell":target_cell, "siege": false, "ranged": army.get("tactical", {}).get("phase", "") == "远射"}
	# Seen enemy effects use visible friendly formations, never hidden target cells.
	if observed:
		var nearest := ""
		var distance := 30.0
		for friend in store.war.active_armies(str(store.war.state["player_faction"])):
			if not formations.has(friend["id"]): continue
			var gap: float = formations[id].global_position.distance_to(formations[friend["id"]].global_position)
			if gap < distance: nearest = friend["id"]; distance = gap
		if nearest != "":
			var ranged: bool = formations[id].get_meta("troop_kind","infantry") == "archers"
			var a := Vector2(formations[id].position.x,formations[id].position.z)
			var b := Vector2(formations[nearest].position.x,formations[nearest].position.z)
			var gap: int = store.war.Tactical.grid().distance(store.war.Tactical.grid().pick(a),store.war.Tactical.grid().pick(b))
			if gap < 1 or gap > (2 if ranged else 1): return {}
			return {"target": formations[nearest].global_position, "siege": false, "ranged": ranged and gap == 2}
	return {}

func _city_wall(site: Dictionary, target: Vector3) -> Vector3:
	var point: Vector2 = site["point"]
	var render_id := str(site["render_id"]) if site["native"] else str(site["id"])
	var city_root: Node3D = map.city_nodes.get(render_id)
	var origin := Vector3(point.x, map.height_at(point.x, point.y), point.y) if city_root == null else city_root.global_position
	var direction := target - origin
	var local := direction if city_root == null else city_root.global_basis.inverse() * direction
	var side := ("east" if local.x > 0 else "west") if absf(local.x) > absf(local.z) else ("south" if local.z > 0 else "north")
	var anchor: Dictionary = site.get("wall_anchors", {}).get(side, {})
	var offset := Vector3(float(anchor.get("x", 2.65 if side == "east" else -2.65 if side == "west" else 0.0)), float(anchor.get("y", 3.8)), float(anchor.get("z", 2.65 if side == "south" else -2.65 if side == "north" else 0.0)))
	return origin + offset if city_root == null else city_root.to_global(offset)

func _show_city_volleys() -> void:
	if not presenting: return
	for event in store.war.state.get("city_volleys", []):
		if int(event["tick"]) != int(store.war.state["tick"]) or not formations.has(event["target"]): continue
		var target: Node3D = formations[event["target"]]
		if not target.visible: continue
		var city: Dictionary = store.city_state(str(event["city"]))
		if str(city.get("faction", "")) != str(event["faction"]): continue
		var site := Fortifications.for_city(store, str(event["city"]))
		if site.is_empty(): continue
		var source := _city_wall(site, target.global_position) + Vector3.UP * 0.65
		var target_cell := HexPresentation.cell_at(target.global_position)
		var target_army: Dictionary = store.war.state["armies"].get(event["target"],{})
		if target_army.has("tactical") and target_cell != int(target_army["tactical"]["cell"]): continue
		combat_effects.show_city_volley(str(event["id"]), source, target.global_position, presentation_elapsed,target_cell)


func _update_city_breaches() -> void:
	for node in city_breaches:
		var active: bool = int(store.war.state.get("sieges", {}).get(node, {}).get("breach_cell", -1)) >= 0
		city_breaches[node]["root"].visible = active
		for material in city_breaches[node].get("materials", []): material.set_shader_parameter("breach_open", active)
	for node in store.war.state.get("sieges", {}):
		var siege: Dictionary = store.war.state["sieges"][node]
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

func begin_day(before: Dictionary) -> void:
	for text in loss_floaters: if is_instance_valid(text): text.queue_free()
	loss_floaters.clear()
	loss_contact_since.clear()
	presentation_stats.clear()
	for id in badges:
		presentation_stats[id] = {"strength":badges[id].strength,"morale":badges[id].morale}
	presenting = true
	presentation_elapsed = 0.0
	presentation_duration = DAY_SECONDS
	for army in store.war.state["armies"].values():
		if int(army.get("daily_loss_tick",-1)) == int(store.war.state["tick"]) and int(army.get("daily_loss",0)) > 0:
			presentation_duration += CONTACT_SECONDS
			break
	motion_start.clear()
	motion_locations = before.duplicate(true)
	if not store.battle_test:
		for id in observed_enemies: motion_locations[id] = observed_enemies[id]["location"].duplicate(true)
	for id in formations:
		motion_start[id] = formations[id].position
		formations[id].set_meta("march_layout_scale",formations[id].get_meta("formation_scale",1.0))
	refresh()
	for id in formations:
		if not motion_start.has(id):
			motion_start[id] = world_position(before[id]) if before.has(id) else formations[id].position
		if not destinations.has(id): destinations[id] = formations[id].position
	_present_new_duel()
	_update_display_stats()

func _update_display_stats() -> void:
	if not presenting: return
	for id in presentation_stats:
		if not badges.has(id): continue
		var army: Dictionary = store.war.state["armies"].get(id,{})
		if army.is_empty() or not army.has("tactical") or int(army.get("daily_loss_tick",-1)) != int(store.war.state["tick"]) or int(army.get("daily_loss",0)) <= 0: continue
		if not store.battle_test and army["faction"] != store.war.state["player_faction"]: continue
		var blend := 0.0
		if loss_contact_since.has(id):
			var delay := 0.70 if _loss_contact_mode(id) == "ranged" else 0.20
			blend = smoothstep(0.0,0.35,presentation_elapsed-float(loss_contact_since[id])-delay)
		var strength := roundi(lerpf(float(presentation_stats[id]["strength"]),float(store.war.Combat.strength(army)),blend))
		var morale := lerpf(float(presentation_stats[id]["morale"]),float(army.get("morale",100)),blend)
		if badges[id].strength != strength or not is_equal_approx(badges[id].morale,morale):
			badges[id].strength = strength
			badges[id].morale = morale
			badges[id].queue_redraw()

func _exit_tree() -> void:
	if is_instance_valid(store) and store.war_presentation == self:
		store.war_presentation = null
		store.time_paused = false

func focus_army(id: String) -> void:
	if not formations.has(id): return
	map._clear_selection()
	map.target_goal = destinations[id]
	map.distance_goal = 70
	ui.show_army(id)
	for item in badges:
		badges[item].highlighted = item == id
		badges[item].queue_redraw()

func show_enemy(id: String) -> void:
	var observed: Dictionary = observed_enemies.get(id, {})
	if observed.is_empty(): return
	selected_enemy = id
	ui.reports_view.hide()
	ui._prepare_drawer("enemy")
	ui.page = "enemy"
	ui.heading.text = "敌军侦察情报"
	ui.drawer.show()
	ui._clear()
	if store.battle_test:
		var army: Dictionary = store.war.state["armies"].get(id, {})
		ui.heading.text = str(army.get("name", "敌军")) + "队  测试观察"
		var operation: Dictionary = army.get("operation", {})
		var roles := preload("res://scripts/war/tactical_battlefield.gd").ROLES
		ui.body.add_child(ui._label("职责：%s  阶段：%s\n协同对象：%s  攻击目标：%s" % [roles.get(operation.get("role", ""), "自主行动"), army.get("tactical", {}).get("phase", ""), store.war.state["armies"].get(operation.get("support_id", ""), {}).get("name", "无"), store.war.state["armies"].get(army.get("tactical", {}).get("attack_target", ""), {}).get("name", "未接敌")], 13))
		ui.body.add_child(ui._label("主将判断：" + str(army.get("last_reason", "")), 14))
		for record in army.get("decision_history", []).slice(-5):
			ui.body.add_child(ui._label("第%d日  %s  %s" % [record["tick"], record["source"], record["candidate_id"]], 12))
	ui.body.add_child(ui._label("估计兵力：约 %d\n误差：约 %d 人\n观察位置：%s\n情报距今：%d 日\n状态：%s" % [int(observed["strength_estimate"]), int(observed["uncertainty"]), store.war.graph.name_of(str(observed["location"]["node"])), int(store.war.state["tick"]) - int(observed["observed_at"]), "撤退中" if observed["routing"] else "未见撤退"], 14))

func _refresh_enemy_panel() -> void:
	# The scout panel is built once on click, so after a day advances it kept the
	# old estimate and a frozen "情报距今". Re-render it whenever the campaign moves.
	if selected_enemy == "" or not is_instance_valid(ui) or ui.page != "enemy" or not ui.drawer.visible: return
	if observed_enemies.get(selected_enemy, {}).is_empty():
		ui._clear()
		ui.heading.text = "敌军侦察情报"
		ui.drawer.show()
		ui.body.add_child(ui._label("该部队已脱离视野，现有情报过期，需要重新侦察。", 14))
		return
	show_enemy(selected_enemy)

func deploy_city(city: String) -> void:
	var target: String = str(city_aliases.get(city, ""))
	if target != "":
		if store.city_state(target).get("faction", "") == store.war.state["player_faction"]:
			ui.show_dispatch_from(target)
		else:
			ui.dispatch_home = ""
			ui.show_dispatch(target)
	else:
		# 未接入路网的城：3D 下军情抽屉默认是关的，提示写进去等于没有任何反馈。
		# 先把抽屉打开再写，并让玩家明确看到是哪一个城不可出征。
		ui.show_reports()
		ui.drawer.show()
		ui.heading.text = "此城暂未接入战役路网"
		ui.body.add_child(ui._label("%s 尚未接入战役路网，无法从此城出征。\n请在军情面板中选择已接入路网的城池出征。" % city, 16))

func _build_battle_feedback() -> void:
	advantage_panel = PanelContainer.new()
	advantage_panel.name = "BattleAdvantage"
	advantage_panel.position = Vector2(460, 18)
	advantage_panel.custom_minimum_size = Vector2(430, 58)
	advantage_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08,0.10,0.07,0.88)
	style.set_content_margin_all(8)
	advantage_panel.add_theme_stylebox_override("panel",style)
	var box := VBoxContainer.new()
	advantage_panel.add_child(box)
	advantage_label = preload("res://scripts/city_ui_skin.gd").label("",16)
	advantage_label.add_theme_color_override("font_color", Color("f3e6bf"))
	box.add_child(advantage_label)
	advantage_bar = ProgressBar.new()
	advantage_bar.custom_minimum_size = Vector2(410,12)
	advantage_bar.show_percentage = false
	for setting in [["background",Color("9e4837")],["fill",Color("73904c")]]:
		var bar_style := StyleBoxFlat.new()
		bar_style.bg_color = setting[1]
		advantage_bar.add_theme_stylebox_override(setting[0],bar_style)
	box.add_child(advantage_bar)
	layer.add_child(advantage_panel)
	_refresh_battle_feedback()

func _refresh_battle_feedback() -> void:
	if not is_instance_valid(advantage_panel): return
	advantage_panel.visible = not store.war.active_armies().is_empty()
	var balance := Feedback.visible_advantage(store.war)
	advantage_bar.value = balance["percent"]
	advantage_label.text = "我军 %.0f%%　|　敌军 %.0f%%　%s" % [balance["percent"],100-balance["percent"],"侦察估计" if balance["estimated"] else "战况优势"]

func _at_display_destination(id: String) -> bool:
	if not formations.has(id): return false
	var army: Dictionary = store.war.state["armies"].get(id,{})
	if army.has("tactical") and HexPresentation.cell_at(formations[id].global_position) != int(army["tactical"]["cell"]): return false
	if not destinations.has(id): return true
	var delta: Vector3 = (formations[id].position-destinations[id])*Vector3(1,0,1)
	return delta.length_squared() <= 0.64

func _loss_contact_mode(id: String) -> String:
	if not presenting or not _at_display_destination(id): return ""
	var tick: int = store.war.state["tick"]
	# A defender can take ranged damage without having a legal attack of its own.
	for source in formations:
		if source == id or not _at_display_destination(source): continue
		var army: Dictionary = store.war.state["armies"].get(source,{})
		if int(army.get("combat_tick",-1)) != tick: continue
		if str(army.get("tactical",{}).get("attack_target",army.get("action",{}).get("enemy",""))) != id: continue
		var visual := _combat_visual(source)
		if visual.is_empty() or visual.get("siege",false): continue
		if visual["target"].distance_squared_to(formations[id].global_position) > 0.01: continue
		return "ranged" if visual["ranged"] else "melee"
	for event in store.war.state.get("city_volleys",[]):
		if int(event["tick"]) != tick or str(event["target"]) != id: continue
		var army: Dictionary = store.war.state["armies"].get(id,{})
		var board: Dictionary = store.war.Tactical.board_for(store.war,army)
		if Fortifications.distance_to_wall(board,str(event["city"]),HexPresentation.cell_at(formations[id].global_position)) <= 2: return "ranged"
	var visual := _combat_visual(id)
	if visual.is_empty(): return ""
	if visual["siege"]: return "melee"
	var target: String = store.war.state["armies"].get(id,{}).get("tactical",{}).get("attack_target","")
	if not _at_display_destination(target): return ""
	return "ranged" if visual["ranged"] else "melee"

func _spawn_loss_floaters() -> void:
	var tick: int = store.war.state["tick"]
	if floated_tick != tick:
		floated_tick = tick
		floated_armies.clear()
		loss_contact_since.clear()
	var maximum := int(store.war.rules.get("feedback",{}).get("max_floaters_per_day",6))
	for id in formations:
		if floated_armies.has(id): continue
		var army: Dictionary = store.war.state["armies"].get(id,{})
		if int(army.get("daily_loss_tick",-1)) != tick or int(army.get("daily_loss",0)) <= 0: continue
		if army["faction"] != store.war.state["player_faction"] and not store.battle_test:
			var sight: Dictionary = observed_enemies.get(id,{})
			if int(sight.get("observed_at",-1)) != tick or not sight.get("fighting",false): continue
		var mode := _loss_contact_mode(id)
		if mode == "":
			loss_contact_since.erase(id)
			continue
		if not loss_contact_since.has(id): loss_contact_since[id] = presentation_elapsed
		if presentation_elapsed-float(loss_contact_since[id]) < (0.70 if mode == "ranged" else 0.20): continue
		# The label budget controls visual clutter, not strength-bar timing.
		# Every valid contact still records its hit time and blends its own stats.
		if floated_armies.size() >= maximum: continue
		var text := Label3D.new()
		text.text = "−%d" % int(army["daily_loss"])
		text.font = preload("res://scripts/city_ui_skin.gd").font()
		text.font_size = 36
		text.modulate = Color("ffb49c")
		text.outline_modulate = Color(0.12,0.08,0.05)
		text.outline_size = 8
		text.pixel_size = 0.022
		text.no_depth_test = true
		text.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		text.set_meta("army",id)
		text.set_meta("age",0.0)
		add_child(text)
		loss_floaters.append(text)
		floated_armies[id] = true
		_position_loss_floater(text,id,0.0)

func _position_loss_floater(text: Label3D, id: String, age: float) -> void:
	var side: Vector3 = map.camera.global_basis.x*(_formation_radius(formations[id])+0.8)
	text.global_position = formations[id].global_position+side+Vector3(0,2.4+age,0)

func _update_loss_floaters(delta: float) -> void:
	for text in loss_floaters.duplicate():
		if not is_instance_valid(text): loss_floaters.erase(text); continue
		var id: String = text.get_meta("army")
		var age: float = float(text.get_meta("age")) + (0.0 if store.time_paused else delta * store.time_scale)
		text.set_meta("age",age)
		if age >= DAY_SECONDS or not formations.has(id):
			text.queue_free()
			loss_floaters.erase(text)
			continue
		text.visible = formations[id].visible
		_position_loss_floater(text,id,age)
		text.modulate.a = minf(1,(DAY_SECONDS-age)*2)

func _set_pose(batch: MultiMeshInstance3D, start: int, count: int, rate: float) -> void:
	var old: int = batch.get_meta("pose_start", 0)
	if old == start: return
	if animation_time - float(batch.get_meta("transition_at", -1.0)) < 0.18: return
	var material: ShaderMaterial = batch.material_override
	material.set_shader_parameter("previous_start", old)
	material.set_shader_parameter("previous_count", int(batch.get_meta("pose_count", 1)))
	material.set_shader_parameter("previous_rate", float(batch.get_meta("pose_rate", 0.0)))
	material.set_shader_parameter("transition_at", animation_time)
	material.set_shader_parameter("pose_start", start)
	material.set_shader_parameter("pose_count", count)
	material.set_shader_parameter("pose_rate", rate)
	batch.set_meta("pose_start", start)
	batch.set_meta("pose_count", count)
	batch.set_meta("pose_rate", rate)
	batch.set_meta("transition_at", animation_time)
