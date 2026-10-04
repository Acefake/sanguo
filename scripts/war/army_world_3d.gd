extends Node3D

const CampaignUI = preload("res://scripts/war/campaign_ui.gd")
const Badge = preload("res://scripts/war/army_badge.gd")
const MAX_SOLDIERS := 108
var map: Node3D
var store: Node
var ui: CanvasLayer
var layer: CanvasLayer
var formations: Dictionary = {}
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
	army_choice.position = Vector2(16, 118)
	army_choice.custom_minimum_size = Vector2(200, 32)
	army_choice.add_theme_font_override("font", preload("res://scripts/city_ui_skin.gd").font())
	army_choice.item_selected.connect(func(index):
		if index > 0: focus_army(str(army_choice.get_item_metadata(index)))
	)
	layer.add_child(army_choice)
	store.campaign_changed.connect(refresh)
	store.city_changed.connect(func(_id):
		if not store.busy: refresh()
	)
	refresh()

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

func refresh() -> void:
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
	for army in entries:
		var id: String = army["id"]
		var enemy: bool = army["faction"] == "observed_enemy"
		active[id] = true
		if not enemy:
			army_choice.add_item(str(army["name"]) + "队" + (" · 撤退" if army["returning"] else ""))
			army_choice.set_item_metadata(army_choice.item_count - 1, id)
		var target: Vector3 = world_position(army["location"])
		if enemy: target += Vector3(8, 0, -6)
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
			badge.portrait = _portrait(str(army["name"]))
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
		if str(army["location"].get("edge", "")) != "":
			var direction: Vector2 = points.get(str(army["location"].get("to", "")), Vector2.ZERO) - points.get(str(army["location"].get("from", "")), Vector2.ZERO)
			if direction.length_squared() > 0.01: formations[id].rotation.y = atan2(direction.x, direction.y)
		badge.strength = int(army["strength_estimate"]) if enemy else store.war.Combat.strength(army)
		badge.estimated = enemy
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
				if not ended.is_empty(): destinations[id] = world_position(ended["location"])
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
	batch.multimesh.mesh = mesh
	batch.multimesh.instance_count = MAX_SOLDIERS
	group.add_child(batch)
	# Small equipment silhouettes make individual troops readable at map scale.
	var helmet := SphereMesh.new()
	helmet.radius = 0.19
	helmet.height = 0.38
	helmet.is_hemisphere = true
	helmet.radial_segments = 8
	helmet.rings = 4
	var equipment := StandardMaterial3D.new()
	equipment.albedo_color = Color("393522")
	equipment.metallic = 0.55
	equipment.roughness = 0.58
	equipment.vertex_color_use_as_albedo = true
	helmet.material = equipment
	var helmets := MultiMeshInstance3D.new()
	helmets.name = "Helmets"
	helmets.multimesh = MultiMesh.new()
	helmets.multimesh.transform_format = MultiMesh.TRANSFORM_3D
	helmets.multimesh.use_colors = true
	helmets.multimesh.mesh = helmet
	helmets.multimesh.instance_count = MAX_SOLDIERS
	group.add_child(helmets)

func _layout_formation(group: Node3D, count: int) -> void:
	var batch: MultiMeshInstance3D = group.get_node("Soldiers")
	var helmets: MultiMeshInstance3D = group.get_node("Helmets")
	helmets.multimesh.visible_instance_count = count
	var random := RandomNumberGenerator.new()
	random.seed = hash(group.name)
	var radius := sqrt(float(count)) * 0.48
	for i in range(count):
		# Sunflower packing fills a rounded silhouette without visible grid rows.
		var angle := float(i) * 2.39996323
		var r := radius * sqrt((float(i) + 0.5) / float(count))
		var offset := Vector3(cos(angle) * r * 1.12, 0, sin(angle) * r * 0.88)
		offset += Vector3(random.randf_range(-0.10, 0.10), 0, random.randf_range(-0.10, 0.10))
		var size_value := random.randf_range(1.12, 1.28)
		var basis := Basis(Vector3.UP, random.randf_range(-0.30, 0.30)).scaled(Vector3.ONE * size_value)
		var world_offset := group.basis * offset
		offset.y = map.height_at(group.position.x + world_offset.x, group.position.z + world_offset.z) - group.position.y + 0.2
		batch.multimesh.set_instance_transform(i, Transform3D(basis, offset))
		helmets.multimesh.set_instance_transform(i, Transform3D(basis, offset) * Transform3D(Basis.IDENTITY, Vector3(0, 1.68, 0)))
		var shade := random.randf_range(0.82, 1.0)
		batch.multimesh.set_instance_color(i, Color(shade, shade * 0.94, shade * 0.82))
		helmets.multimesh.set_instance_color(i, Color(shade, shade * 0.94, shade * 0.82))

func _portrait(name: String) -> Texture2D:
	if textures.has(name): return textures[name]
	var path: String = str(portraits.get(name, {}).get("thumbnail", ""))
	var texture: Texture2D = null
	if FileAccess.file_exists(path): texture = load(path)
	textures[name] = texture
	return texture

func _process(delta: float) -> void:
	if map == null or map.camera == null: return
	ground_timer += delta
	if presenting and not store.time_paused:
		animation_time += delta * store.time_scale
		presentation_elapsed += delta * store.time_scale
	var update_ground: bool = ground_timer >= 0.15
	if update_ground: ground_timer = 0.0
	for id in formations:
		var group: Node3D = formations[id]
		if presenting and motion_start.has(id):
			group.position = motion_start[id].lerp(destinations[id], clampf(presentation_elapsed / DAY_SECONDS, 0, 1))
		group.position.y = map.height_at(group.position.x, group.position.z) + 0.2
		if update_ground:
			var batch: MultiMeshInstance3D = group.get_node_or_null("Soldiers")
			if batch != null:
				var army: Dictionary = {} if observed_enemies.has(id) else store.war.state["armies"].get(id, {})
				if observed_enemies.has(id):
					var observed: Dictionary = observed_enemies[id]
					army = {"location": observed["location"], "combat_tick": int(store.war.state["tick"]) if observed.get("fighting", false) else -1, "action": {"type": "continue" if observed["routing"] else "hold"}}
				var marching: bool = str(army.get("location", {}).get("edge", "")) != "" and str(army.get("action", {}).get("type", "")) in ["march", "continue", "withdraw"]
				var fighting: bool = int(army.get("combat_tick", -1)) == int(store.war.state["tick"])
				if presenting and fighting and not combat_meshes.is_empty():
					batch.multimesh.mesh = combat_meshes[int(animation_time * 12) % combat_meshes.size()]
				elif presenting and marching and not march_meshes.is_empty():
					batch.multimesh.mesh = march_meshes[int(animation_time * 8) % march_meshes.size()]
				else:
					batch.multimesh.mesh = mesh
				for i in range(batch.multimesh.visible_instance_count):
					var transform: Transform3D = batch.multimesh.get_instance_transform(i)
					var offset: Vector3 = group.basis * Vector3(transform.origin.x, 0, transform.origin.z)
					transform.origin.y = map.height_at(group.position.x + offset.x, group.position.z + offset.z) - group.position.y + 0.2
					batch.multimesh.set_instance_transform(i, transform)
					var helmets: MultiMeshInstance3D = group.get_node("Helmets")
					helmets.multimesh.set_instance_transform(i, transform * Transform3D(Basis.IDENTITY, Vector3(0, 1.68, 0)))
		var anchor: Vector3 = group.global_position + Vector3(0, 1.7, 0)
		var badge: Control = badges[id]
		badge.visible = not map.camera.is_position_behind(anchor)
		if badge.visible: badge.position = map.camera.unproject_position(anchor) - Vector2(42, 80)
		# Keep individual models hidden at overview distances; badges stay readable.
		group.visible = map.camera.global_position.distance_to(group.global_position) < 550
	if presenting and presentation_elapsed >= DAY_SECONDS:
		presenting = false
		motion_start.clear()
		refresh()

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
