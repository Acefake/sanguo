extends Node3D

const CampaignUI = preload("res://scripts/war/campaign_ui.gd")
const Badge = preload("res://scripts/war/army_badge.gd")
const MAX_SOLDIERS := 108
const Feedback = preload("res://scripts/war/battle_feedback.gd")
var advantage_panel: PanelContainer
var advantage_label: Label
var advantage_bar: ProgressBar
var loss_floaters: Array[Label3D] = []
var floated_tick := -1
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
var animation_time := 0.0
var portraits: Dictionary = {}
var textures: Dictionary = {}
var army_choice: OptionButton
var ground_timer := 0.0
var observed_enemies: Dictionary = {}
var combat_meshes: Array[Mesh] = []
var combat_effects: Node3D
var pose_material: ShaderMaterial
var presenting := false
var presentation_elapsed := 0.0
var motion_start: Dictionary = {}
const DAY_SECONDS := 2.0

func _ready() -> void:
	store = get_node("/root/GameState")
	store.war_presentation = self
	portraits = JSON.parse_string(FileAccess.get_file_as_string("res://data/officer_portraits.json"))
	var positions: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/war/world_3d_positions.json"))
	for id in positions["positions"]:
		var entry: Dictionary = positions["positions"][id]
		points[id] = Vector2(entry["x"], entry["z"])
	city_aliases = positions["city_aliases"]
	_load_mesh()
	combat_effects = preload("res://scripts/war/combat_effects_3d.gd").new()
	combat_effects.height_at = map.height_at
	combat_effects.camera = map.camera
	add_child(combat_effects)
	layer = CanvasLayer.new()
	layer.layer = 3
	add_child(layer)
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
	map.distance = 160
	map.distance_goal = 160
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
	for i in range(9, meshes.size()): combat_meshes.append(meshes[i].mesh)
	var troop_meshes: Array = [mesh]
	troop_meshes.append_array(march_meshes)
	troop_meshes.append_array(combat_meshes)
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

func world_position(location: Dictionary) -> Vector3:
	var node: String = str(location.get("node", ""))
	var point: Vector2 = points.get(node, Vector2(1024, 1024))
	if str(location.get("edge", "")) != "":
		var a: Vector2 = points.get(str(location.get("from", node)), point)
		var b: Vector2 = points.get(str(location.get("to", node)), point)
		point = a.lerp(b, clampf(float(location.get("progress", 0)), 0, 1))
	else:
		# Stand outside city geometry so troops and badges remain selectable.
		point += Vector2(24, 24)
	return Vector3(point.x, map.height_at(point.x, point.y) + 0.2, point.y)

func _battle_point(cell: int) -> Vector3:
	var point: Vector2 = map.hex_world.grid.center(cell)
	return Vector3(point.x, map.height_at(point.x, point.y) + 0.2, point.y)

func _select_global_cell(cell: int, preview: bool) -> void:
	if preview: return
	for id in formations:
		var army: Dictionary = store.war.state["armies"].get(id, {})
		if not army.has("tactical") or int(army["tactical"]["cell"]) != cell: continue
		if army["faction"] == store.war.state["player_faction"]: ui.show_army(id)
		elif observed_enemies.has(id): show_enemy(id)
		return

func _create_supply_markers() -> void:
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
	_refresh_battle_feedback()
	_refresh_supplies()
	var active: Dictionary = {}
	army_choice.clear()
	army_choice.add_item("前往在外军队")
	var entries: Array = store.war.active_armies(str(store.war.state["player_faction"]))
	observed_enemies.clear()
	for army in entries:
		for id in army["intel"]["enemies"]:
			var observed: Dictionary = army["intel"]["enemies"][id]
			if not observed_enemies.has(id) or int(observed["observed_at"]) > int(observed_enemies[id]["observed_at"]): observed_enemies[id] = observed
	for observed in observed_enemies.values():
		entries.append({"id": observed["id"], "name": "敌军", "faction": "observed_enemy", "location": observed["location"], "strength_estimate": observed["strength_estimate"], "morale": 0, "returning": observed["routing"]})
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
			army_choice.add_item(str(army["name"]) + "队" + (" · 撤退" if army["returning"] else ""))
			army_choice.set_item_metadata(army_choice.item_count - 1, id)
		var target: Vector3 = world_position(army["location"])
		if army.has("tactical"): target = _battle_point(int(army["tactical"]["cell"]))
		elif store.battle_test: target += store.battle_offsets.get(id, Vector3.ZERO)
		elif enemy: target += Vector3(8, 0, -6)
		destinations[id] = target
		if not formations.has(id):
			var group := Node3D.new()
			group.name = "Formation_" + id
			add_child(group)
			group.position = target
			formations[id] = group
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
		badge.scale = Vector2.ONE * (0.65 if store.battle_test else 1.0)
		if str(army["location"].get("edge", "")) != "":
			var direction: Vector2 = points.get(str(army["location"].get("to", "")), Vector2.ZERO) - points.get(str(army["location"].get("from", "")), Vector2.ZERO)
			if direction.length_squared() > 0.01: formations[id].set_meta("march_heading", atan2(direction.x, direction.y))
		if army.has("tactical"):
			var direction: Vector3 = target - formations[id].position
			if direction.length_squared() > 0.01: formations[id].set_meta("march_heading", atan2(direction.x, direction.z))
		var operation: Dictionary = army.get("operation", {})
		badge.tooltip_text = "%s · %s\n%s" % [army["name"], preload("res://scripts/war/tactical_battlefield.gd").ROLES.get(operation.get("role", ""), "自主行动"), army.get("tactical", {}).get("phase", "")]
		badge.strength = int(army["strength_estimate"]) if enemy else int(army.get("display_strength", store.war.Combat.strength(army)))
		badge.estimated = enemy and not store.battle_test
		badge.morale = float(army["morale"])
		badge.faction_color = Color("c86650") if enemy else Color(str(store.scenario["factions"].get(army["faction"], {}).get("color", "#8ac56b")))
		badge.queue_redraw()
		var batch: MultiMeshInstance3D = formations[id].get_node_or_null("Soldiers")
		if batch != null:
			var count := clampi(int(ceil(sqrt(float(badge.strength)) * 2.2)), 1, MAX_SOLDIERS)
			batch.multimesh.visible_instance_count = count
			_layout_formation(formations[id], count)
	for id in formations.keys():
		if not active.has(id):
			if presenting:
				var ended: Dictionary = store.war.state["armies"].get(id, {})
				if not ended.is_empty(): destinations[id] = _battle_point(int(ended["tactical"]["cell"])) if ended.has("tactical") else world_position(ended["location"])
				continue
			formations[id].queue_free()
			badges[id].queue_free()
			formations.erase(id)
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

func _layout_formation(group: Node3D, count: int) -> void:
	var batch: MultiMeshInstance3D = group.get_node("Soldiers")
	var previous_count: int = group.get_meta("layout_count", 0)
	if previous_count == count: return
	group.set_meta("layout_count", count)
	var random := RandomNumberGenerator.new()
	random.seed = hash(group.name)
	var radius := sqrt(float(count)) * (0.26 if store.battle_test else 0.48)
	for i in range(count):
		# Sunflower packing fills a rounded silhouette without visible grid rows.
		var angle := float(i) * 2.39996323
		var r := radius * sqrt((float(i) + 0.5) / float(count))
		var offset := Vector3(cos(angle) * r * 1.12, 0, sin(angle) * r * 0.88)
		offset += Vector3(random.randf_range(-0.10, 0.10), 0, random.randf_range(-0.10, 0.10))
		var size_value := random.randf_range(1.12, 1.28)
		var basis := Basis(Vector3.UP, random.randf_range(-0.30, 0.30)).scaled(Vector3.ONE * size_value)
		if i < previous_count: basis = batch.multimesh.get_instance_transform(i).basis
		var world_offset := group.basis * offset
		offset.y = map.height_at(group.position.x + world_offset.x, group.position.z + world_offset.z) - group.position.y + 0.2
		batch.multimesh.set_instance_transform(i, Transform3D(basis, offset))
		var custom := Color(random.randf(), random.randf(), clampf((offset.z / maxf(radius, 0.1) + 0.25) * 1.5, 0, 1), 1)
		if i < previous_count: custom = batch.multimesh.get_instance_custom_data(i)
		batch.multimesh.set_instance_custom_data(i, custom)
		var shade := random.randf_range(0.82, 1.0)
		batch.multimesh.set_instance_color(i, Color(shade, shade * 0.94, shade * 0.82))


func _portrait(name: String) -> Texture2D:
	if textures.has(name): return textures[name]
	var path: String = str(portraits.get(name, {}).get("thumbnail", ""))
	var texture: Texture2D = null
	if FileAccess.file_exists(path): texture = load(path)
	textures[name] = texture
	return texture

func _process(delta: float) -> void:
	_update_loss_floaters(delta)
	if map == null or map.camera == null: return
	ground_timer += delta
	if not store.time_paused:
		animation_time += delta * store.time_scale
		if presenting: presentation_elapsed += delta * store.time_scale
	var update_ground: bool = ground_timer >= 0.15
	if update_ground: ground_timer = 0.0
	combat_effects.begin_frame()
	for id in formations:
		var group: Node3D = formations[id]
		if presenting and motion_start.has(id):
			group.position = motion_start[id].lerp(destinations[id], clampf(presentation_elapsed / DAY_SECONDS, 0, 1))
		group.position.y = map.height_at(group.position.x, group.position.z) + 0.2
		var pose_batch: MultiMeshInstance3D = group.get_node_or_null("Soldiers")
		if pose_batch != null: pose_batch.material_override.set_shader_parameter("animation_clock", animation_time)
		if update_ground and not store.time_paused:
			var batch: MultiMeshInstance3D = group.get_node_or_null("Soldiers")
			if batch != null:
				var army: Dictionary = {} if observed_enemies.has(id) and not store.battle_test else store.war.state["armies"].get(id, {})
				if observed_enemies.has(id) and not store.battle_test:
					var observed: Dictionary = observed_enemies[id]
					army = {"location": observed["location"], "combat_tick": int(store.war.state["tick"]) if observed.get("fighting", false) else -1, "action": {"type": "continue" if observed["routing"] else "hold"}}
				var marching: bool = str(army.get("location", {}).get("edge", "")) != "" and str(army.get("action", {}).get("type", "")) in ["march", "continue", "withdraw"]
				if army.has("tactical") and motion_start.has(id):
					marching = motion_start[id].distance_squared_to(destinations[id]) > 0.01
				var fighting: bool = int(army.get("combat_tick", -1)) == int(store.war.state["tick"]) and not army.get("formation_locked",false) and store.war.Terrain.entry_factor(army,store.war.rules) > 0
				if presenting and fighting and not combat_meshes.is_empty():
					_set_pose(batch, 9, combat_meshes.size(), 12.0)
				elif presenting and marching and not march_meshes.is_empty():
					_set_pose(batch, 1, march_meshes.size(), 8.0)
				else:
					_set_pose(batch, 0, 1, 0.0)
				for i in range(batch.multimesh.visible_instance_count):
					var transform: Transform3D = batch.multimesh.get_instance_transform(i)
					var offset: Vector3 = group.basis * Vector3(transform.origin.x, 0, transform.origin.z)
					transform.origin.y = map.height_at(group.position.x + offset.x, group.position.z + offset.z) - group.position.y + 0.2
					batch.multimesh.set_instance_transform(i, transform)

		if presenting and group.visible:
			var visual: Dictionary = _combat_visual(id)
			if not visual.is_empty():
				if visual.get("duel", false):
					var army: Dictionary = store.war.state["armies"][id]
					var opponent: String = army.get("duel_opponent", "")
					var other: Dictionary = store.war.state["armies"].get(opponent, {})
					# Stable pair key prevents two effects for the same duel.
					if id < opponent and (store.battle_test or other.get("faction", "") == store.war.state["player_faction"] or int(observed_enemies.get(opponent, {}).get("observed_at", -1)) == int(store.war.state["tick"])):
						combat_effects.show_duel("%s:%s:%d" % [id, opponent, store.war.state["tick"]], group.global_position, visual["target"], animation_time, str(store.war.roster.officers.get(army["officer_id"], {}).get("name", army["name"])), str(store.war.roster.officers.get(other.get("officer_id", ""), {}).get("name", "敌将")), _portrait(str(store.war.roster.officers.get(army["officer_id"], {}).get("name", army["name"]))), _portrait(str(store.war.roster.officers.get(other.get("officer_id", ""), {}).get("name", ""))))
				var fronts: Array = _combat_fronts(id)
				for front in fronts:
					combat_effects.show_contact(front["key"], group.global_position, front["target"], animation_time, front["siege"], front["ranged"], _formation_radius(group), front.get("duel",false))
				if not store.time_paused: _face_contact_sectors(group, fronts, delta * minf(store.time_scale, 2.0))
			elif not store.time_paused and motion_start.has(id) and motion_start[id].distance_squared_to(destinations[id]) > 0.01:
				_face_contact_sectors(group, [{"target": group.global_position + Vector3(sin(float(group.get_meta("march_heading",0.0))),0,cos(float(group.get_meta("march_heading",0.0)))) * 100}], delta * minf(store.time_scale, 2.0))
		var anchor: Vector3 = group.global_position + Vector3(0, 1.7, 0)
		var badge: Control = badges[id]
		badge.visible = not map.camera.is_position_behind(anchor)
		if badge.visible: badge.position = map.camera.unproject_position(anchor) - Vector2(42, 80) * badge.scale
		# Keep individual models hidden at overview distances; badges stay readable.
		group.visible = map.camera.global_position.distance_to(group.global_position) < 550
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
	if presenting and presentation_elapsed >= DAY_SECONDS:
		presenting = false
		motion_start.clear()
		refresh()

func _formation_radius(group: Node3D) -> float:
	var batch: MultiMeshInstance3D = group.get_node_or_null("Soldiers")
	var count := MAX_SOLDIERS if batch == null else batch.multimesh.visible_instance_count
	if count < 0: count = MAX_SOLDIERS
	return sqrt(float(maxi(count, 1))) * (0.26 if store.battle_test else 0.48) * 1.12

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

func _combat_visual(id: String) -> Dictionary:
	var army: Dictionary = store.war.state["armies"].get(id, {})
	if army.is_empty(): return {}
	var observed: bool = observed_enemies.has(id) and not store.battle_test
	if observed:
		var sight: Dictionary = observed_enemies[id]
		if not sight.get("fighting", false) or int(sight.get("observed_at", -1)) != int(store.war.state["tick"]): return {}
	elif int(army.get("combat_tick", -1)) != int(store.war.state["tick"]): return {}
	if army.get("formation_locked",false) or store.war.Terrain.entry_factor(army,store.war.rules) <= 0: return {}
	if int(army.get("duel_tick",-1)) == int(store.war.state["tick"]) and formations.has(army.get("duel_opponent","")):
		return {"target":formations[army["duel_opponent"]].global_position,"siege":false,"ranged":false,"duel":true}
	if not observed:
		var siege: Dictionary = store.war.state.get("sieges", {}).get(army["target"], {})
		if siege.get("phase", "") == "强攻" and int(siege.get("active_tick", -1)) == int(store.war.state["tick"]) and siege.get("participants", []).has(id):
			var cell: int = store.war.state.get("battlefield", {}).get("objectives", {}).get(army["target"], -1)
			var target := _battle_point(cell) if cell >= 0 else world_position({"node": army["target"], "edge": ""})
			return {"target": target, "siege": true, "ranged": false}
		var enemy: String = army.get("tactical", {}).get("attack_target", army.get("action", {}).get("enemy", ""))
		if formations.has(enemy):
			return {"target": formations[enemy].global_position, "siege": false, "ranged": army.get("tactical", {}).get("phase", "") == "远射"}
	# Seen enemy effects use visible friendly formations, never hidden target cells.
	if observed:
		var nearest := ""
		var distance := 30.0
		for friend in store.war.active_armies(str(store.war.state["player_faction"])):
			if not formations.has(friend["id"]): continue
			var gap: float = formations[id].global_position.distance_to(formations[friend["id"]].global_position)
			if gap < distance: nearest = friend["id"]; distance = gap
		if nearest != "": return {"target": formations[nearest].global_position, "siege": false, "ranged": false}
	return {}

func begin_day(before: Dictionary) -> void:
	presenting = true
	presentation_elapsed = 0.0
	motion_start.clear()
	for id in formations: motion_start[id] = formations[id].position
	refresh()
	for id in formations:
		if not motion_start.has(id):
			motion_start[id] = world_position(before[id]) if before.has(id) else formations[id].position
		if not destinations.has(id): destinations[id] = formations[id].position
	_spawn_loss_floaters()

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
	ui.page = "enemy"
	ui.heading.text = "敌军侦察情报"
	ui.drawer.show()
	ui._clear()
	if store.battle_test:
		var army: Dictionary = store.war.state["armies"].get(id, {})
		ui.heading.text = str(army.get("name", "敌军")) + "队 · 测试观察"
		var operation: Dictionary = army.get("operation", {})
		var roles := preload("res://scripts/war/tactical_battlefield.gd").ROLES
		ui.body.add_child(ui._label("职责：%s · 阶段：%s\n协同对象：%s · 攻击目标：%s" % [roles.get(operation.get("role", ""), "自主行动"), army.get("tactical", {}).get("phase", ""), store.war.state["armies"].get(operation.get("support_id", ""), {}).get("name", "无"), store.war.state["armies"].get(army.get("tactical", {}).get("attack_target", ""), {}).get("name", "未接敌")], 16))
		ui.body.add_child(ui._label("主将判断：" + str(army.get("last_reason", "")), 18))
		for record in army.get("decision_history", []).slice(-5):
			ui.body.add_child(ui._label("第%d日 · %s · %s" % [record["tick"], record["source"], record["candidate_id"]], 15))
	ui.body.add_child(ui._label("估计兵力：约 %d\n误差：约 %d 人\n观察位置：%s\n情报距今：%d 日\n状态：%s" % [int(observed["strength_estimate"]), int(observed["uncertainty"]), store.war.graph.name_of(str(observed["location"]["node"])), int(store.war.state["tick"]) - int(observed["observed_at"]), "撤退中" if observed["routing"] else "未见撤退"], 19))

func deploy_city(city: String) -> void:
	var target: String = str(city_aliases.get(city, ""))
	if target != "":
		if store.city_state(target).get("faction", "") == store.war.state["player_faction"]:
			ui.show_dispatch_from(target)
		else:
			ui.dispatch_home = ""
			ui.show_dispatch(target)
	else:
		ui.show_reports()
		ui.body.add_child(ui._label("此城暂未接入战役路网，请选择军情面板或其他城池出征。", 16))

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

func _spawn_loss_floaters() -> void:
	var tick: int = store.war.state["tick"]
	if floated_tick == tick: return
	floated_tick = tick
	var count := 0
	for id in formations:
		var army: Dictionary = store.war.state["armies"].get(id,{})
		if int(army.get("daily_loss_tick",-1)) != tick or int(army.get("daily_loss",0)) <= 0: continue
		if army["faction"] != store.war.state["player_faction"] and not store.battle_test:
			var sight: Dictionary = observed_enemies.get(id,{})
			if int(sight.get("observed_at",-1)) != tick or not sight.get("fighting",false): continue
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
		count += 1
		if count >= int(store.war.rules.get("feedback",{}).get("max_floaters_per_day",6)): break

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
		var side: Vector3 = map.camera.global_basis.x * (_formation_radius(formations[id])+0.8)
		text.position = formations[id].position + side + Vector3(0,2.4+age,0)
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
