extends Node3D

# Native RTK14 geometry, textures and skin weights. Riding/gait/strikes are
# project-authored poses, applied continuously to the recovered skeletons.
const MODEL_ROOT := "res://assets/duel/rtk14/models/"
var saddle_offset := Vector3(0, 0.57, -0.12)
var horse: Node3D
var rider: Node3D
var weapon: Node3D
var horse_rig: Dictionary
var rider_rig: Dictionary
var variant := "407a9723"
var clock := 0.0
var last_rider_pose: Array = []
var last_weapon_transform := Transform3D.IDENTITY
var fall_pose: Array = []
var fall_weapon := Transform3D.IDENTITY

func reset() -> void:
	fall_pose.clear()
	pose(0.0, 0.0, 0.0)

func _ready() -> void:
	horse = _model("cdf4bc12-rig")
	rider = _model(variant + "-rig")
	weapon = _model("26f8ff97")
	horse_rig = _capture(horse)
	rider_rig = _capture(rider)
	if not horse_rig.is_empty() and not rider_rig.is_empty():
		var horse_pelvis: Transform3D = horse_rig["rest"][horse_rig["skeleton"].find_bone("bone_1")]
		var rider_pelvis: Transform3D = rider_rig["rest"][rider_rig["skeleton"].find_bone("bone_2")]
		# Match the rider's pelvis to the horse's spine/saddle height from the
		# source rigs instead of guessing an absolute world-space mount height.
		saddle_offset = Vector3(0.0, horse_pelvis.origin.y - rider_pelvis.origin.y + 0.08, horse_pelvis.origin.z - rider_pelvis.origin.z - 0.12)
	rider.position = saddle_offset
	# The native long saber lies along +X; set its grip just behind the guard.
	for mesh_node in weapon.find_children("*", "MeshInstance3D", true, false):
		var box: AABB = mesh_node.mesh.get_aabb()
		# The narrow handle occupies X=-0.25..0, while the guard is at +0.15.
		mesh_node.position -= Vector3(-0.14, box.get_center().y, box.get_center().z)
	pose(0.0, 0.0, 0.0)

func _model(id: String) -> Node3D:
	var resource: PackedScene = load(MODEL_ROOT + id + ".glb")
	if resource == null:
		push_error("Mounted duel model missing: " + id)
		var empty := Node3D.new()
		add_child(empty)
		return empty
	var model: Node3D = resource.instantiate()
	add_child(model)
	for mesh_node in model.find_children("*", "MeshInstance3D", true, false):
		for surface in range(mesh_node.mesh.get_surface_count()):
			if id == "26f8ff97":
				var saber := ShaderMaterial.new()
				saber.shader = preload("res://shaders/duel_saber.gdshader")
				saber.set_shader_parameter("native_albedo", preload("res://assets/duel/rtk14/textures/62547770.png"))
				saber.set_shader_parameter("native_normal", preload("res://assets/duel/rtk14/textures/99a1887e.png"))
				mesh_node.set_surface_override_material(surface, saber)
				continue
			var original = mesh_node.get_active_material(surface)
			if original is StandardMaterial3D:
				var material: StandardMaterial3D = original.duplicate()
				material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
				if material.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED:
					material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
					material.alpha_scissor_threshold = 0.4
				mesh_node.set_surface_override_material(surface, material)
	return model

func _capture(model: Node3D) -> Dictionary:
	var found := model.find_children("*", "Skeleton3D", true, false)
	if found.is_empty(): return {}
	var skeleton: Skeleton3D = found[0]
	var rest: Array[Transform3D] = []
	var descendants: Array = []
	for i in range(skeleton.get_bone_count()):
		rest.append(skeleton.get_bone_global_rest(i))
		var branch: Array[int] = []
		for j in range(skeleton.get_bone_count()):
			var ancestor := j
			while ancestor >= 0:
				if ancestor == i:
					branch.append(j)
					break
				ancestor = skeleton.get_bone_parent(ancestor)
		descendants.append(branch)
	return {"skeleton": skeleton, "rest": rest, "branches": descendants}

func _turn_branch(rig: Dictionary, poses: Array, bone_name: String, axis: Vector3, angle: float) -> void:
	var index: int = rig["skeleton"].find_bone(bone_name)
	if index < 0: return
	var pivot: Vector3 = poses[index].origin
	var rotation := Basis(axis, angle)
	for child in rig["branches"][index]:
		poses[child] = Transform3D(rotation * poses[child].basis, pivot + rotation * (poses[child].origin - pivot))

func _aim(rig: Dictionary, poses: Array, bone_name: String, end_name: String, target: Vector3) -> void:
	var index: int = rig["skeleton"].find_bone(bone_name)
	var end: int = rig["skeleton"].find_bone(end_name)
	if index < 0 or end < 0: return
	var pivot: Vector3 = poses[index].origin
	var source: Vector3 = poses[end].origin - pivot
	var direction := target - pivot
	if source.length_squared() < 0.00001 or direction.length_squared() < 0.00001: return
	var rotation := Basis(Quaternion(source.normalized(), direction.normalized()))
	for child in rig["branches"][index]:
		poses[child] = Transform3D(rotation * poses[child].basis, pivot + rotation * (poses[child].origin - pivot))

func _apply(rig: Dictionary, poses: Array) -> void:
	var skeleton: Skeleton3D = rig["skeleton"]
	for i in range(poses.size()): skeleton.set_bone_global_pose_override(i, poses[i], 1.0, true)

func _arm(poses: Array, upper: String, elbow: String, wrist: String, target: Vector3, pole: Vector3) -> void:
	var sk: Skeleton3D = rider_rig["skeleton"]
	var a: int = sk.find_bone(upper)
	var b: int = sk.find_bone(elbow)
	var c: int = sk.find_bone(wrist)
	var origin: Vector3 = poses[a].origin
	var length_a: float = poses[a].origin.distance_to(poses[b].origin)
	var length_b: float = poses[b].origin.distance_to(poses[c].origin)
	var direction := (target - origin).normalized()
	var distance := clampf(origin.distance_to(target), absf(length_a - length_b) + 0.015, length_a + length_b - 0.025)
	var along := (length_a * length_a - length_b * length_b + distance * distance) / (2.0 * distance)
	var bend := (pole - direction * pole.dot(direction)).normalized()
	var joint := origin + direction * along + bend * sqrt(maxf(0.0, length_a * length_a - along * along))
	_aim(rider_rig, poses, upper, elbow, joint)
	_aim(rider_rig, poses, elbow, wrist, origin + direction * distance)

func _grip(poses: Array, blade: Vector3) -> Vector3:
	var sk: Skeleton3D = rider_rig["skeleton"]
	var wrist: int = sk.find_bone("bone_21")
	var palm := (Vector3.DOWN - blade * blade.dot(Vector3.DOWN)).normalized()
	if palm.length_squared() < 0.1: palm = Vector3.FORWARD
	var across := blade.cross(palm).normalized()
	var hand_basis := Basis((palm + across).normalized(), (across - palm).normalized(), blade)
	var rest_basis: Basis = rider_rig["rest"][wrist].basis
	var rotation: Basis = hand_basis * rest_basis * poses[wrist].basis.inverse()
	var pivot: Vector3 = poses[wrist].origin
	for child in rider_rig["branches"][wrist]:
		poses[child] = Transform3D(rotation * poses[child].basis, pivot + rotation * (poses[child].origin - pivot))
	# Curl the four recovered finger chains around the handle, then oppose thumb.
	for chain in [["bone_56", "bone_58", "bone_60"], ["bone_62", "bone_64", "bone_66"], ["bone_70", "bone_72", "bone_74"], ["bone_76", "bone_78", "bone_80"]]:
		for segment in range(3):
			_turn_branch(rider_rig, poses, chain[segment], across, [1.30, 1.10, 0.80][segment])
	_turn_branch(rider_rig, poses, "bone_50", palm, -0.45)
	_turn_branch(rider_rig, poses, "bone_50", across, 0.55)
	_turn_branch(rider_rig, poses, "bone_52", across, 1.05)
	return pivot + palm * 0.105

func _motion(phase: float, style: int, guarding: bool) -> Dictionary:
	var ready := Vector3(0.30, 1.33, 0.45)
	var windups := [Vector3(0.28, 1.78, 0.22), Vector3(0.56, 1.57, 0.17), Vector3(0.05, 1.47, 0.25)]
	var finishes := [Vector3(0.30, 1.12, 0.72), Vector3(0.09, 1.20, 0.70), Vector3(0.55, 1.29, 0.66)]
	var ready_blade := Vector3(0.02, 0.34, 0.94).normalized()
	var raised := [Vector3(0.03, 0.97, 0.23), Vector3(0.64, 0.71, 0.29), Vector3(-0.72, 0.28, 0.64)]
	var lowered := [Vector3(0.02, -0.52, 0.85), Vector3(-0.40, -0.30, 0.86), Vector3(0.52, -0.02, 0.85)]
	var hand: Vector3
	var blade: Vector3
	var twist: float
	if phase < 0.25:
		var weight := smoothstep(0.0, 0.25, phase)
		hand = ready.lerp(windups[style], weight)
		blade = ready_blade.slerp(raised[style].normalized(), weight)
		twist = -0.16 * weight
	elif phase < 0.48:
		var weight := smoothstep(0.25, 0.48, phase)
		hand = windups[style].lerp(finishes[style], weight)
		blade = raised[style].normalized().slerp(lowered[style].normalized(), weight)
		twist = lerpf(-0.16, 0.20, weight)
	else:
		var weight := smoothstep(0.48, 1.0, phase)
		hand = finishes[style].lerp(ready, weight)
		blade = lowered[style].normalized().slerp(ready_blade, weight)
		twist = 0.20 * (1.0 - weight)
	if guarding:
		hand = ready.lerp(hand, 0.48)
		blade = ready_blade.slerp(blade, 0.58)
		twist *= -0.45
	return {"hand":hand, "blade":blade, "twist":twist}

func pose(time: float, gallop: float, strike: float, style: int = 0, cut_phase: float = -1.0, guarding: bool = false) -> void:
	clock = time
	weapon.show()
	rider.rotation = Vector3.ZERO
	var phase := time * 9.0
	var breathe := sin(time * 2.2) * 0.004
	var bounce := sin(phase * 2.0) * 0.035 * gallop + breathe
	horse.position.y = bounce
	rider.position = saddle_offset + Vector3.UP * bounce
	if not horse_rig.is_empty():
		var hp: Array = horse_rig["rest"].duplicate()
		for row in [["bone_23", 0.0], ["bone_27", PI], ["bone_12", PI], ["bone_13", 0.0]]:
			_turn_branch(horse_rig, hp, row[0], Vector3.RIGHT, sin(phase + row[1]) * 0.30 * gallop)
		for row in [["bone_41", 0.0], ["bone_42", PI], ["bone_38", PI], ["bone_40", 0.0]]:
			_turn_branch(horse_rig, hp, row[0], Vector3.RIGHT, maxf(0.0, sin(phase + row[1])) * 0.50 * gallop)
		_turn_branch(horse_rig, hp, "bone_6", Vector3.RIGHT, sin(time * 2.2) * 0.016 + sin(phase * 0.5) * 0.06 * gallop)
		_turn_branch(horse_rig, hp, "bone_1", Vector3.RIGHT, sin(phase * 2.0) * 0.018 * gallop)
		_turn_branch(horse_rig, hp, "bone_14", Vector3.UP, sin(time * 5.0) * 0.10)
		_apply(horse_rig, hp)
	if rider_rig.is_empty(): return
	var rp: Array = rider_rig["rest"].duplicate()
	# Spread thighs around the saddle, bend knees and keep boots at stirrup level.
	_aim(rider_rig, rp, "bone_7", "bone_9", Vector3(0.40, 0.90, 0.34))
	_aim(rider_rig, rp, "bone_9", "bone_11", Vector3(0.42, 0.44, 0.31))
	_aim(rider_rig, rp, "bone_8", "bone_10", Vector3(-0.40, 0.90, 0.34))
	_aim(rider_rig, rp, "bone_10", "bone_12", Vector3(-0.42, 0.44, 0.31))
	var motion := _motion(cut_phase if cut_phase >= 0.0 else strike * 0.48, posmod(style, 3), guarding)
	_turn_branch(rider_rig, rp, "bone_4", Vector3.RIGHT, -sin(phase * 2.0) * 0.025 * gallop + sin(time * 2.2) * 0.008 + strike * 0.10)
	_turn_branch(rider_rig, rp, "bone_4", Vector3.UP, float(motion["twist"]))
	_arm(rp, "bone_17", "bone_19", "bone_21", motion["hand"], Vector3(1, -0.25, -0.2))
	_aim(rider_rig, rp, "bone_18", "bone_20", Vector3(-0.31, 1.27, 0.31))
	_aim(rider_rig, rp, "bone_20", "bone_22", Vector3(-0.16, 1.20, 0.64))
	var blade_axis: Vector3 = motion["blade"]
	var grip := _grip(rp, blade_axis)
	_apply(rider_rig, rp)
	last_rider_pose = rp.duplicate()
	var wrist: int = rider_rig["skeleton"].find_bone("bone_21")
	if wrist >= 0:
		var skeleton: Skeleton3D = rider_rig["skeleton"]
		weapon.position = to_local(skeleton.to_global(grip))
		var up_axis := (Vector3.UP - blade_axis * blade_axis.dot(Vector3.UP)).normalized()
		var side_axis := blade_axis.cross(up_axis).normalized()
		# Native Y is blade thickness; keep the broad cutting face upright.
		weapon.basis = Basis(blade_axis, side_axis, -up_axis).scaled(Vector3.ONE * 1.20)
		last_weapon_transform = weapon.transform

func knock_down(progress: float = 1.0) -> void:
	if fall_pose.is_empty():
		fall_pose = last_rider_pose.duplicate()
		fall_weapon = last_weapon_transform
	var t := clampf(progress, 0.0, 1.0)
	var release := smoothstep(0.05, 0.78, t)
	var pelvis: Vector3 = rider_rig["rest"][rider_rig["skeleton"].find_bone("bone_2")].origin
	var start := saddle_offset + pelvis
	var center := start.lerp(Vector3(1.25, 0.29, saddle_offset.z - 0.20), release)
	center.y += sin(PI * release) * 0.15
	rider.rotation = Vector3(-0.12 * release, 0.12 * release, -PI * 0.48 * release)
	rider.position = center - rider.basis * pelvis
	if not fall_pose.is_empty():
		var fallen := fall_pose.duplicate()
		_turn_branch(rider_rig, fallen, "bone_4", Vector3.RIGHT, 0.22 * release)
		_turn_branch(rider_rig, fallen, "bone_7", Vector3.RIGHT, -0.25 * release)
		_turn_branch(rider_rig, fallen, "bone_8", Vector3.RIGHT, 0.15 * release)
		_apply(rider_rig, fallen)
	weapon.visible = t < 0.95
	var drop := smoothstep(0.12, 0.80, t)
	var flat := Basis(Vector3.UP, 0.65)
	weapon.basis = Basis(fall_weapon.basis.orthonormalized().get_rotation_quaternion().slerp(flat.get_rotation_quaternion(), drop)).scaled(Vector3.ONE * 1.20)
	weapon.position = fall_weapon.origin.lerp(Vector3(0.70, 0.055, 0.55), drop)
