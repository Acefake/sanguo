extends Node3D

# Native Godot playback of visually verified RTK14 texture candidates.
# G1E/EFPL emitter parameters are not claimed to have been reconstructed.
const TEXTURES := {
	"slash": preload("res://assets/armies/rtk14/effects/slash.png"),
	"spark": preload("res://assets/armies/rtk14/effects/spark.png"),
	"dust": preload("res://assets/armies/rtk14/effects/dust.png")
}
const MAX_CONTACTS := 24
const MAX_CITY_CONTACTS := 16
const Hex = preload("res://scripts/war/presentation/hex_presentation.gd")
const SiegeVisual = preload("res://scripts/war/presentation/siege_visual.gd")
# Keep the original shaft, head and feathers readable at the map camera scale.
const ARROW_VISUAL_SCALE := Vector3(1.2, 1.2, 1.2)
var duel_started: Dictionary = {}
var duels: Dictionary = {}
var duel_touched: Dictionary = {}
var contacts := {}
# Hidden contact effects kept for reuse instead of freed: a fight flickering in and out of view, or a new day's
# contacts, take one of these rather than building nodes and materials again.
var contact_pool: Array[Dictionary] = []
var touched := {}
var height_at: Callable
var camera: Camera3D
var arrow_scene: PackedScene
var projectiles: Dictionary = {}
var volley_impacts: Dictionary = {}
var target_markers: Dictionary = {}
var marker_touched: Dictionary = {}

func _landing(target: Vector3, index: int, count: int, cell: int) -> Vector3:
	var point := Hex.landing(target,index,count,cell)
	point.y = float(height_at.call(point.x,point.z))+0.65 if height_at.is_valid() else target.y+0.65
	return point

func _impact(key: String, index: int, point: Vector3, elapsed: float, flight: float) -> float:
	if not volley_impacts.has(key):
		volley_impacts[key] = []
		for i in range(12):
			var spark := _quad("spark",0.65)
			spark.hide()
			volley_impacts[key].append(spark)
	var flash := maxf(0.0,1.0-absf(elapsed-flight-0.07)/0.13)
	var spark: MeshInstance3D = volley_impacts[key][index]
	spark.position = point
	spark.scale = Vector3.ONE*(0.6+flash*0.4)
	spark.mesh.material.albedo_color = Color(1.0,0.78,0.35,flash*0.72)
	spark.visible = flash > 0.0
	return flash

func _mark_target(cell: int, time: float, hit: float) -> void:
	if cell < 0: return
	if not target_markers.has(cell):
		var vertices := PackedVector3Array()
		var colors := PackedColorArray()
		var grid = Hex.Grid.shared()
		var center: Vector2 = grid.center(cell)
		var polygon: PackedVector2Array = grid.polygon(cell)
		for i in range(6):
			var a: Vector2 = polygon[i].lerp(center,0.04)
			var b: Vector2 = polygon[(i+1)%6].lerp(center,0.04)
			var inner_a := a.lerp(center,0.045)
			var inner_b := b.lerp(center,0.045)
			for point in [a,b,inner_a,b,inner_b,inner_a,center,inner_a,inner_b]:
				var height := float(height_at.call(point.x,point.y)) if height_at.is_valid() else 0.0
				vertices.append(Vector3(point.x,height+0.14,point.y))
				colors.append(Color(1.0,0.66,0.22,0.12 if vertices.size()%9 in [7,8,0] else 0.85))
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = vertices
		arrays[Mesh.ARRAY_COLOR] = colors
		var material := StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		material.vertex_color_use_as_albedo = true
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
		var shape := ArrayMesh.new()
		shape.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays)
		shape.surface_set_material(0,material)
		var marker := MeshInstance3D.new()
		marker.mesh = shape
		marker.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(marker)
		target_markers[cell] = marker
	var intensity := 0.20+0.05*sin(time*5.0)+hit*0.55
	intensity = maxf(intensity,float(marker_touched.get(cell,0.0)))
	marker_touched[cell] = intensity
	target_markers[cell].mesh.surface_get_material(0).albedo_color = Color(1,1,1,intensity)

func arrow_scale(point: Vector3) -> Vector3:
	return ARROW_VISUAL_SCALE

func _flight(arrow: Node3D, origin: Vector3, destination: Vector3, travel: float, rise: float) -> void:
	arrow.position = origin.lerp(destination, travel) + Vector3.UP * sin(travel * PI) * rise
	var tangent := destination-origin + Vector3.UP*cos(travel*PI)*PI*rise
	arrow.basis = Basis.looking_at(-tangent.normalized(),Vector3.UP)*Basis.IDENTITY.scaled(arrow_scale(arrow.position))

func _air_streak(arrow: Node3D, index: int, origin: Vector3, destination: Vector3, travel: float, rise: float) -> void:
	# Short white streaks are interleaved with real arrows, not landing flashes.
	if index % 4 != 0: return
	var streak: MeshInstance3D = arrow.get_node_or_null("AirStreak")
	if streak == null:
		streak = MeshInstance3D.new()
		streak.name = "AirStreak"
		var shape := QuadMesh.new()
		shape.size = Vector2(0.32,1.45)
		var material := ShaderMaterial.new()
		material.shader = preload("res://shaders/arrow_air_streak.gdshader")
		material.set_shader_parameter("image",preload("res://assets/armies/rtk14/effects/arrow-trail.png"))
		shape.material = material
		streak.mesh = shape
		streak.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		arrow.add_child(streak)
	var tangent := (destination-origin+Vector3.UP*cos(travel*PI)*PI*rise).normalized()
	var view := (camera.global_position-arrow.global_position).normalized() if is_instance_valid(camera) else Vector3.UP
	var side := tangent.cross(view).normalized()
	if side.length_squared() < 0.01: side = tangent.cross(Vector3.RIGHT).normalized()
	var normal := side.cross(tangent).normalized()
	streak.global_transform = Transform3D(Basis(side,tangent,normal),arrow.global_position-tangent*0.65)
	streak.mesh.material.set_shader_parameter("opacity",smoothstep(0.02,0.13,travel)*(1.0-smoothstep(0.82,0.98,travel))*0.85)
	streak.visible = arrow.visible and travel > 0.02 and travel < 0.98

func show_archer_volley(id: String, formation: Node3D, target: Vector3, time: float, target_cell: int = -1) -> void:
	var batch: MultiMeshInstance3D = formation.get_node_or_null("Archers")
	if batch == null: return
	var count := batch.multimesh.visible_instance_count
	if count < 0: count = batch.multimesh.instance_count
	if count == 0: return
	var key := "bows:"+id
	if not projectiles.has(key):
		if projectiles.size() >= MAX_CONTACTS: return
		projectiles[key] = []
		for i in range(count): projectiles[key].append(_arrow())
	touched[key] = true
	var cycle := 12.0/6.5
	var impact := 0.0
	if target_cell < 0: target_cell = Hex.cell_at(target)
	for i in range(projectiles[key].size()):
		# Same phase and speed as this soldier's shader; release follows full draw.
		var soldier := i % count
		var phase := batch.multimesh.get_instance_custom_data(soldier).r
		var elapsed := fposmod(time + phase*cycle - cycle*0.70, cycle)
		var arrow: Node3D = projectiles[key][i]
		arrow.visible = elapsed < 1.10
		var origin := batch.global_transform * (batch.multimesh.get_instance_transform(soldier) * Vector3(-0.06,1.25,0.30))
		var destination := _landing(target,i,projectiles[key].size(),target_cell)
		_flight(arrow,origin,destination,clampf(elapsed/1.10,0,1),minf(origin.distance_to(destination)*0.15,2.8))
		arrow.set_meta("landing",destination)
		_air_streak(arrow,i,origin,destination,clampf(elapsed/1.10,0,1),minf(origin.distance_to(destination)*0.15,2.8))
	_mark_target(target_cell,time,impact)

func show_siege_projectiles(id: String, equipment: Node3D, target: Vector3, time: float, target_cell: int = -1) -> void:
	if equipment == null: return
	SiegeVisual.aim(equipment,target)
	for engine in equipment.get_children():
		# A ram makes contact with its beam; only the catapult launches stones.
		if engine.get_meta("kind","") != "catapult": continue
		var key := "stone:"+id+":"+str(engine.get_index())
		if not projectiles.has(key):
			if projectiles.size() >= MAX_CONTACTS: return
			var stone := MeshInstance3D.new()
			var sphere := SphereMesh.new()
			sphere.radius = 0.28
			sphere.height = 0.56
			sphere.radial_segments = 10
			sphere.rings = 6
			var material := StandardMaterial3D.new()
			material.albedo_color = Color(0.32,0.28,0.22)
			material.roughness = 1.0
			sphere.material = material
			stone.mesh = sphere
			add_child(stone)
			projectiles[key] = [stone,_quad("dust",3.2)]
		touched[key] = true
		var elapsed := fposmod(time+engine.get_index()*0.16-SiegeVisual.RELEASE_TIME,2.0)
		var stone: MeshInstance3D = projectiles[key][0]
		var dust: MeshInstance3D = projectiles[key][1]
		var origin: Vector3 = engine.to_global(SiegeVisual.launch_socket(engine))
		var destination := target + Vector3.UP*1.4
		var travel := clampf(elapsed/SiegeVisual.FLIGHT_TIME,0,1)
		stone.visible = elapsed < SiegeVisual.FLIGHT_TIME
		stone.position = origin.lerp(destination,travel)+Vector3.UP*sin(travel*PI)*minf(6.0,origin.distance_to(destination)*0.22)
		stone.scale = Vector3.ONE
		stone.set_meta("landing",destination)
		dust.position = destination
		dust.visible = elapsed >= SiegeVisual.FLIGHT_TIME and elapsed < 1.35
		dust.scale = Vector3.ONE*(1.0+maxf(0,elapsed-SiegeVisual.FLIGHT_TIME)*2.0)
		dust.mesh.material.albedo_color = Color(0.65,0.56,0.40,clampf((1.35-elapsed)*1.3,0,0.65))
		_mark_target(target_cell if target_cell >= 0 else Hex.cell_at(target),time,1.0 if dust.visible else 0.0)

func _arrow() -> Node3D:
	if arrow_scene == null:
		var document := GLTFDocument.new()
		var state := GLTFState.new()
		if document.append_from_file("res://assets/armies/rtk14/models/arrow.glb",state) == OK:
			var model := document.generate_scene(state)
			arrow_scene = PackedScene.new()
			arrow_scene.pack(model)
			model.free()
	if arrow_scene != null:
		var native: Node3D = arrow_scene.instantiate()
		for part in native.find_children("*", "MeshInstance3D", true, false):
			part.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			# Original textured feathers and shaft retain contrast above busy terrain.
			for surface in range(part.mesh.get_surface_count()):
				var material = part.mesh.surface_get_material(surface).duplicate()
				material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
				part.set_surface_override_material(surface,material)
		add_child(native)
		return native
	var arrow := Node3D.new()
	var shaft := MeshInstance3D.new()
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = 0.022
	cylinder.bottom_radius = 0.022
	cylinder.height = 0.95
	var wood := StandardMaterial3D.new()
	wood.albedo_color = Color(0.38,0.23,0.10)
	cylinder.material = wood
	shaft.mesh = cylinder
	shaft.rotation.x = PI/2
	arrow.add_child(shaft)
	var tip := MeshInstance3D.new()
	var cone := CylinderMesh.new()
	cone.top_radius = 0.0
	cone.bottom_radius = 0.065
	cone.height = 0.20
	var steel := StandardMaterial3D.new()
	steel.albedo_color = Color(0.55,0.58,0.60)
	cone.material = steel
	tip.mesh = cone
	tip.rotation.x = PI/2
	tip.position.z = 0.57
	arrow.add_child(tip)
	add_child(arrow)
	return arrow

func attack_angle(source: Vector3, target: Vector3) -> float:
	var delta := Vector2(target.x - source.x, target.z - source.z)
	if is_instance_valid(camera):
		delta = camera.unproject_position(target) - camera.unproject_position(source)
	return -delta.angle() - PI / 2


func begin_frame() -> void:
	touched.clear()
	duel_touched.clear()
	marker_touched.clear()

func _quad(kind: String, size: float) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE * size
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD if kind != "dust" else BaseMaterial3D.BLEND_MODE_MIX
	material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	material.albedo_texture = TEXTURES[kind]
	material.no_depth_test = false
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	if kind == "slash":
		var sweep := ShaderMaterial.new()
		sweep.shader = preload("res://shaders/combat_sweep.gdshader")
		sweep.set_shader_parameter("image", TEXTURES[kind])
		quad.material = sweep
	else: quad.material = material
	instance.mesh = quad
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(instance)
	return instance

func _front_arc() -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(2, 2)
	plane.subdivide_width = 8
	plane.subdivide_depth = 8
	var material := ShaderMaterial.new()
	material.shader = preload("res://shaders/combat_front_arc.gdshader")
	material.set_shader_parameter("image", TEXTURES["slash"])
	plane.material = material
	instance.mesh = plane
	instance.extra_cull_margin = 8.0
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(instance)
	return instance

func show_contact(id: String, source: Vector3, target: Vector3, time: float, siege: bool = false, ranged: bool = false, formation_radius: float = 3.0, duel: bool = false, source_lift: float = 1.55, target_cell: int = -1) -> void:
	if not contacts.has(id):
		# City volleys have their own bounded allocation; a busy field battle must
		# not consume every effect slot and silently hide the city's other targets.
		var city_contact := id.begins_with("city:")
		var allocated := 0
		for key in contacts:
			if str(key).begins_with("city:") == city_contact: allocated += 1
		if allocated >= (MAX_CITY_CONTACTS if city_contact else MAX_CONTACTS): return
		contacts[id] = _take_contact(id, ranged)
	touched[id] = true
	var item: Dictionary = contacts[id]
	if ranged:
		if not item.has("arrows"):
			item["arrows"] = []
			for i in range(96 if id.begins_with("city:") else 64): item["arrows"].append(_arrow())
		var forward := ((target-source)*Vector3(1,0,1)).normalized()
		var across := Vector3(-forward.z,0,forward.x)
		var city_shot := id.begins_with("city:")
		var cycle := fposmod(time / 2.4 + float(item["phase"]), 1.0)
		var active := cycle >= 0.25 and cycle < 0.70
		var impact := 0.0
		if target_cell < 0: target_cell = Hex.cell_at(target)
		for i in range(item["arrows"].size()):
			var arrow: Node3D = item["arrows"][i]
			var travel := clampf((cycle - 0.25) / 0.45, 0.0, 1.0)
			var visible := active
			var elapsed := (cycle-0.25)*2.4
			if city_shot:
				# Two slower staggered flights replay a single settled volley.
				elapsed = time - 0.28 - float(i % 12) * 0.025 - float(i / 12) * 0.012
				var wave := floori(elapsed / 1.45)
				travel = clampf(fposmod(elapsed, 1.45) / 1.10, 0.0, 1.0)
				visible = elapsed >= 0.0 and wave < 2 and fposmod(elapsed, 1.45) < 1.10
				elapsed = fposmod(elapsed,1.45) if elapsed >= 0.0 and wave < 2 else -1.0
			var lane := across * (float(i % 12) - 5.5) * 0.28
			var origin := source + lane + Vector3.UP * source_lift
			var destination := _landing(target,i,item["arrows"].size(),target_cell)
			var rise := minf(source.distance_to(target) * (0.10 if city_shot else 0.15), 1.6 if city_shot else 2.8)
			_flight(arrow,origin,destination,travel,rise)
			arrow.visible = visible
			arrow.set_meta("landing",destination)
			_air_streak(arrow,i,origin,destination,travel,rise)
		_mark_target(target_cell,time,impact)
		item["spark"].hide()
		item["dust"].hide()
		item["slash"].hide()
		return
	for arrow in item.get("arrows",[]): arrow.hide()
	for spark in volley_impacts.get(id,[]): spark.hide()
	if bool(item["ranged"]) != ranged:
		item["slash"].queue_free()
		item["slash"] = _quad("slash", 4.6) if ranged else _front_arc()
		item["ranged"] = ranged
		item["sent"] = {}
		item.erase("terrain_patch")
	var phase := fposmod(time / 1.85 + float(item["phase"]), 1.0)
	var direction := ((target - source) * Vector3(1, 0, 1)).normalized()
	var side := Vector3(-direction.z, 0, direction.x)
	var radius := clampf(formation_radius, 0.8, 8.0)
	var impact := source.lerp(target, 0.85) if siege else source + direction * radius * 1.08
	impact.y = float(height_at.call(impact.x, impact.z)) + 1.2 if height_at.is_valid() else impact.y + 1.2
	var strike := sin(clampf(phase / 0.65, 0, 1) * PI)
	var flash := maxf(0, 1.0 - absf(phase - 0.4) / 0.16)
	var slash: MeshInstance3D = item["slash"]
	var spark: MeshInstance3D = item["spark"]
	var dust: MeshInstance3D = item["dust"]
	slash.position = source
	slash.rotation.y = atan2(direction.x, direction.z)
	slash.scale = Vector3(radius * 1.15, 1, radius * 1.15)
	_set_param(item, slash.mesh.material, &"phase", phase)
	_set_param(item, slash.mesh.material, &"tint", Color(0.95, 0.98, 1, 0.32 + strike * 0.6))
	# Cache terrain sampling until the formation's position or heading changes.
	var patch := Transform3D(slash.basis, slash.position)
	if height_at.is_valid() and item.get("terrain_patch", Transform3D()) != patch:
		var heights := Vector4.ZERO
		var corners := [Vector3(-1,0,-1), Vector3(1,0,-1), Vector3(-1,0,1), Vector3(1,0,1)]
		for index in range(4):
			var point: Vector3 = patch * corners[index]
			heights[index] = float(height_at.call(point.x, point.z)) - source.y
		slash.mesh.material.set_shader_parameter("ground_heights", heights)
		item["terrain_patch"] = patch
	spark.position = impact + side * sin(time * 7 + float(item["phase"])) * radius * 0.45
	spark.scale = Vector3.ONE * (0.6 + flash * 0.7) * (1.45 if duel else 1.0)
	var spark_color := Color(1, 0.92, 0.65, flash) if duel else Color(0.94, 0.98, 1, flash)
	if spark.mesh.material.albedo_color != spark_color: spark.mesh.material.albedo_color = spark_color
	dust.position = impact + Vector3(0, phase, 0)
	dust.scale = Vector3.ONE * (0.7 + phase * 0.5)
	var dust_color := Color(0.76, 0.69, 0.53, (1 - phase) * 0.18)
	if dust.mesh.material.albedo_color != dust_color: dust.mesh.material.albedo_color = dust_color
	for kind in ["slash", "spark", "dust"]: item[kind].visible = true

func show_city_volley(id: String, wall_anchor: Vector3, target: Vector3, elapsed: float, target_cell: int = -1) -> void:
	show_contact("city:" + id, wall_anchor, target, elapsed, false, true, 3.0, false, 0.0,target_cell)

func end_frame() -> void:
	for cell in target_markers.keys():
		if marker_touched.has(cell): continue
		target_markers[cell].queue_free()
		target_markers.erase(cell)
	for key in volley_impacts.keys():
		if touched.has(key): continue
		for spark in volley_impacts[key]: spark.queue_free()
		volley_impacts.erase(key)
	for id in projectiles.keys():
		if touched.has(id): continue
		for part in projectiles[id]: part.queue_free()
		projectiles.erase(id)
	# Duel controllers remove their effects explicitly while battle frames continue.
	# Clear stale contacts, including casualties, fog changes and idle days.
	for id in contacts.keys():
		if touched.has(id): continue
		var item: Dictionary = contacts[id]
		for kind in ["slash", "spark", "dust"]: item[kind].hide()
		for arrow in item.get("arrows",[]): arrow.hide()
		contact_pool.append(item)
		contacts.erase(id)

# A pooled contact of the same shape (melee/ranged, field/city), or a new one.
func _take_contact(id: String, ranged: bool) -> Dictionary:
	var city := id.begins_with("city:")
	var phase := float(absi(hash(id + ":impact")) % 100) / 100.0
	for index in range(contact_pool.size()):
		var item: Dictionary = contact_pool[index]
		if bool(item["ranged"]) != ranged or bool(item["city"]) != city: continue
		contact_pool.remove_at(index)
		item["phase"] = phase
		item.erase("terrain_patch")
		return item
	return {"slash": _quad("slash", 4.6) if ranged else _front_arc(), "ranged": ranged, "city": city, "spark": _quad("spark", 1.8), "dust": _quad("dust", 3.2), "phase": phase, "sent": {}}

# set_shader_parameter only when the value differs from what this contact last sent (a paused or
# repeated frame sends nothing).
func _set_param(item: Dictionary, material: ShaderMaterial, name: StringName, value: Variant) -> void:
	var sent: Dictionary = item["sent"]
	if sent.has(name) and sent[name] == value: return
	sent[name] = value
	material.set_shader_parameter(name, value)

# Map-local presentation only; authoritative duel outcomes remain in duel_system.
func show_duel(key: String, source: Vector3, target: Vector3, time: float, left: String, right: String, left_portrait: Texture2D, right_portrait: Texture2D, duration: float = 11.0, outcome: Dictionary = {}, result_at: float = 8.0) -> void:
	if duel_started.has(key) and time - float(duel_started[key]) >= duration: return
	duel_touched[key] = true
	if not duels.has(key):
		if duels.size() >= 3: return
		if not duel_started.has(key): duel_started[key] = time
		if duel_started.size() > 256: duel_started.erase(duel_started.keys()[0])
		var stage := Node3D.new()
		add_child(stage)
		var ring := MeshInstance3D.new()
		var torus := TorusMesh.new()
		torus.inner_radius = 2.9
		torus.outer_radius = 3.0
		torus.rings = 32
		torus.ring_segments = 8
		var gold := StandardMaterial3D.new()
		gold.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		gold.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		gold.albedo_color = Color(1.0, 0.72, 0.25, 0.8)
		torus.material = gold
		ring.mesh = torus
		ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		stage.add_child(ring)
		var title := Label3D.new()
		title.font = preload("res://scripts/ui/city_ui_skin.gd").font()
		title.font_size = 48
		title.pixel_size = 0.026
		title.no_depth_test = true
		title.outline_size = 8
		title.modulate = Color(1, 0.87, 0.48)
		title.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		title.text = "单挑  %s 对 %s" % [left, right]
		stage.add_child(title)
		var portraits: Array[Sprite3D] = []
		for texture in [left_portrait, right_portrait]:
			var portrait := Sprite3D.new()
			portrait.texture = texture
			portrait.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			portrait.shaded = false
			portrait.pixel_size = 1.6 / maxf(texture.get_width() if texture != null else 1, 1)
			stage.add_child(portrait)
			portraits.append(portrait)
		var health_labels: Array[Label3D] = []
		var health_bars: Array[Sprite3D] = []
		for index in range(2):
			var label := Label3D.new()
			label.font = title.font
			label.font_size = 38
			label.pixel_size = 0.022
			label.outline_size = 8
			label.no_depth_test = true
			label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			stage.add_child(label)
			health_labels.append(label)
			var bar := Sprite3D.new()
			var texture := GradientTexture2D.new()
			texture.width = 128
			texture.height = 8
			texture.gradient = Gradient.new()
			texture.gradient.colors = PackedColorArray([Color.WHITE, Color.WHITE])
			bar.texture = texture
			bar.pixel_size = 0.025
			bar.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			bar.no_depth_test = true
			stage.add_child(bar)
			health_bars.append(bar)
		var blades: Array[MeshInstance3D] = []
		for index in range(2):
			var blade := _quad("slash", 5.0)
			blade.reparent(stage, false)
			blade.mesh.material.set_shader_parameter("image", preload("res://assets/armies/rtk14/effects/duel-flare.png"))
			blade.mesh.material.set_shader_parameter("root_offset", 0.0)
			blades.append(blade)
		var spark := _quad("spark", 3.5)
		spark.reparent(stage, false)
		duels[key] = {"root":stage, "ring":ring, "title":title, "portraits":portraits, "health_labels":health_labels, "health_bars":health_bars, "blades":blades, "spark":spark, "started":duel_started[key]}
	var duel: Dictionary = duels[key]
	var center := source.lerp(target, 0.5)
	center.y = float(height_at.call(center.x, center.z)) + 0.35 if height_at.is_valid() else center.y + 0.35
	duel["root"].position = center
	var age := maxf(0, time - float(duel["started"]))
	var fade := smoothstep(0.0, 0.25, age) * (1.0 - smoothstep(duration - 0.5, duration, age))
	var phase := fposmod(age * 1.5, 1.0)
	var flash := pow(maxf(0, sin(phase * PI)), 6)
	var screen_right := camera.global_basis.x if is_instance_valid(camera) else Vector3.RIGHT
	var screen_up := camera.global_basis.y if is_instance_valid(camera) else Vector3.UP
	duel["title"].position = screen_up * 7.5
	duel["title"].modulate.a = fade
	if age >= result_at and not outcome.is_empty():
		var winner := int(outcome.get("winner", -1))
		duel["title"].text = "平手  %s 与 %s" % [left, right] if winner < 0 else "胜方：%s\n负方：%s" % [left if winner == 0 else right, right if winner == 0 else left]
	var rounds: Array = outcome.get("rounds", [])
	var progress := clampf(age / result_at, 0.0, 1.0) * rounds.size()
	var completed := mini(int(progress), rounds.size())
	var fraction := progress - completed
	for index in range(2):
		var field := "hp_a" if index == 0 else "hp_b"
		var previous := 100.0 if completed == 0 else float(rounds[completed - 1].get(field, 100.0))
		var next := float(rounds[completed].get(field, previous)) if completed < rounds.size() else previous
		var health := lerpf(previous, next, fraction)
		var label: Label3D = duel["health_labels"][index]
		label.text = "%s\n体力 %d / 100" % [left if index == 0 else right, ceili(health)]
		label.position = screen_right * (float(index) * 2 - 1) * 3.0 + screen_up * 5.0
		label.modulate = Color(1, 0.87, 0.48, fade) if health > 25 else Color(1, 0.4, 0.3, fade)
		var bar: Sprite3D = duel["health_bars"][index]
		bar.position = screen_right * ((float(index) * 2 - 1) * 3.0 - 1.6 * (1.0 - health / 100.0)) + screen_up * 3.9
		bar.scale.x = maxf(health / 100.0, 0.001)
		bar.modulate = label.modulate

	duel["ring"].mesh.material.albedo_color.a = fade * 0.8
	for index in range(2):
		duel["portraits"][index].modulate.a = fade
		if age >= result_at and not outcome.is_empty():
			var winner := int(outcome.get("winner", -1))
			duel["portraits"][index].modulate = Color(1, 0.87, 0.48, fade) if winner == index else Color(0.58, 0.58, 0.58, fade) if winner >= 0 else Color(1, 1, 1, fade)
		duel["portraits"][index].position = screen_right * (float(index) * 2 - 1) * (1.8 - flash * 0.35) + screen_up * 2.5
		var blade: MeshInstance3D = duel["blades"][index]
		blade.position = Vector3(0,1.5,0) + screen_right * (float(index)*2-1) * (1-phase) * 1.3
		blade.mesh.material.set_shader_parameter("sweep_angle", (0.7 if index == 0 else -0.7))
		blade.mesh.material.set_shader_parameter("tint", Color(1,0.85,0.5,flash * fade))
	duel["spark"].position = Vector3(0,1.5,0)
	duel["spark"].scale = Vector3.ONE * (0.5 + flash)
	duel["spark"].mesh.material.albedo_color = Color(1,0.85,0.45,flash * fade)
	duel["ring"].scale = Vector3.ONE * (1 + flash * 0.1)

func remove_duel(key: String) -> void:
	if duels.has(key):
		duels[key]["root"].queue_free()
		duels.erase(key)
	duel_started.erase(key)
	duel_touched.erase(key)
