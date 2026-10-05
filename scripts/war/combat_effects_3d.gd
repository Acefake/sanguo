extends Node3D

# Native Godot playback of visually verified RTK14 texture candidates.
# G1E/EFPL emitter parameters are not claimed to have been reconstructed.
const TEXTURES := {
	"slash": preload("res://assets/armies/rtk14/effects/slash.png"),
	"spark": preload("res://assets/armies/rtk14/effects/spark.png"),
	"dust": preload("res://assets/armies/rtk14/effects/dust.png")
}
const MAX_CONTACTS := 24
var duel_started: Dictionary = {}
var duels: Dictionary = {}
var duel_touched: Dictionary = {}
var contacts := {}
var touched := {}
var height_at: Callable
var camera: Camera3D

func attack_angle(source: Vector3, target: Vector3) -> float:
	var delta := Vector2(target.x - source.x, target.z - source.z)
	if is_instance_valid(camera):
		delta = camera.unproject_position(target) - camera.unproject_position(source)
	return -delta.angle() - PI / 2


func begin_frame() -> void:
	touched.clear()
	duel_touched.clear()

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
	plane.material = material
	instance.mesh = plane
	instance.extra_cull_margin = 8.0
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(instance)
	return instance

func show_contact(id: String, source: Vector3, target: Vector3, time: float, siege: bool = false, ranged: bool = false, formation_radius: float = 3.0, duel: bool = false) -> void:
	if not contacts.has(id):
		if contacts.size() >= MAX_CONTACTS: return
		contacts[id] = {"slash": _quad("slash", 4.6) if ranged else _front_arc(), "ranged": ranged, "spark": _quad("spark", 1.8), "dust": _quad("dust", 3.2), "phase": float(absi(hash(id + ":impact")) % 100) / 100.0}
	touched[id] = true
	var item: Dictionary = contacts[id]
	if bool(item["ranged"]) != ranged:
		item["slash"].queue_free()
		item["slash"] = _quad("slash", 4.6) if ranged else _front_arc()
		item["ranged"] = ranged
	var phase := fposmod(time * 1.35 + float(item["phase"]), 1.0)
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
	if ranged:
		slash.position = source.lerp(target, phase) + Vector3(0, 2, 0)
		slash.rotation = Vector3.ZERO
		slash.scale = Vector3(0.25, 0.1, 1)
		slash.mesh.material.set_shader_parameter("tint", Color(0.75, 0.9, 1, strike * 0.8))
		slash.mesh.material.set_shader_parameter("sweep_angle", attack_angle(source, target))
		slash.mesh.material.set_shader_parameter("root_offset", 0.0)
	else:
		slash.position = source
		slash.rotation.y = atan2(direction.x, direction.z)
		slash.scale = Vector3(radius * 1.45, 1, radius * 1.45)
		slash.mesh.material.set_shader_parameter("phase", phase)
		slash.mesh.material.set_shader_parameter("tint", Color(0.75, 0.9, 1, 0.3 + strike * 0.6))
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
	spark.mesh.material.albedo_color = Color(1, 0.92, 0.65, flash) if duel else Color(0.8, 0.94, 1, flash)
	dust.position = impact + Vector3(0, phase, 0)
	dust.scale = Vector3.ONE * (0.7 + phase * 0.5)
	dust.mesh.material.albedo_color = Color(0.76, 0.69, 0.53, (1 - phase) * 0.18)
	for kind in ["slash", "spark", "dust"]: item[kind].visible = true

func end_frame() -> void:
	for key in duels.keys():
		if duel_touched.has(key): continue
		duels[key]["root"].queue_free()
		duels.erase(key)
	# Clear stale contacts, including casualties, fog changes and idle days.
	for id in contacts.keys():
		if touched.has(id): continue
		for kind in ["slash", "spark", "dust"]: contacts[id][kind].queue_free()
		contacts.erase(id)

# Map-local presentation only; authoritative duel outcomes remain in duel_system.
func show_duel(key: String, source: Vector3, target: Vector3, time: float, left: String, right: String, left_portrait: Texture2D, right_portrait: Texture2D) -> void:
	if duel_started.has(key) and time - float(duel_started[key]) >= 2.0: return
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
		title.font = preload("res://scripts/city_ui_skin.gd").font()
		title.font_size = 32
		title.pixel_size = 0.022
		title.no_depth_test = true
		title.outline_size = 8
		title.modulate = Color(1, 0.87, 0.48)
		title.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		title.text = "单挑 · %s 对 %s" % [left, right]
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
		var blades: Array[MeshInstance3D] = []
		for index in range(2):
			var blade := _quad("slash", 5.0)
			blade.reparent(stage, false)
			blade.mesh.material.set_shader_parameter("image", preload("res://assets/armies/rtk14/effects/duel-flare.png"))
			blade.mesh.material.set_shader_parameter("root_offset", 0.0)
			blades.append(blade)
		var spark := _quad("spark", 3.5)
		spark.reparent(stage, false)
		duels[key] = {"root":stage, "ring":ring, "title":title, "portraits":portraits, "blades":blades, "spark":spark, "started":duel_started[key]}
	var duel: Dictionary = duels[key]
	var center := source.lerp(target, 0.5)
	center.y = float(height_at.call(center.x, center.z)) + 0.35 if height_at.is_valid() else center.y + 0.35
	duel["root"].position = center
	var age := maxf(0, time - float(duel["started"]))
	var fade := smoothstep(0.0, 0.12, age) * (1.0 - smoothstep(1.8, 2.0, age))
	var phase := fposmod(age * 1.5, 1.0)
	var flash := pow(maxf(0, sin(phase * PI)), 6)
	var screen_right := camera.global_basis.x if is_instance_valid(camera) else Vector3.RIGHT
	duel["title"].position = Vector3(0, 5.2, 0)
	duel["title"].modulate.a = fade
	duel["ring"].mesh.material.albedo_color.a = fade * 0.8
	for index in range(2):
		duel["portraits"][index].modulate.a = fade
		duel["portraits"][index].position = screen_right * (float(index) * 2 - 1) * (1.8 - flash * 0.35) + Vector3(0,3.4,0)
		var blade: MeshInstance3D = duel["blades"][index]
		blade.position = Vector3(0,1.5,0) + screen_right * (float(index)*2-1) * (1-phase) * 1.3
		blade.mesh.material.set_shader_parameter("sweep_angle", (0.7 if index == 0 else -0.7))
		blade.mesh.material.set_shader_parameter("tint", Color(1,0.85,0.5,flash * fade))
	duel["spark"].position = Vector3(0,1.5,0)
	duel["spark"].scale = Vector3.ONE * (0.5 + flash)
	duel["spark"].mesh.material.albedo_color = Color(1,0.85,0.45,flash * fade)
	duel["ring"].scale = Vector3.ONE * (1 + flash * 0.1)
