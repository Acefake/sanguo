extends Node3D

const VIEW_TARGET := Vector3(0, 0, -3)
const VIEW_DISTANCE := 36.0
const VIEW_YAW := 9.0
const VIEW_PITCH := 24.0
var camera: Camera3D
var scene_manifest := "res://assets/city/luoyang/scene.json"
var view_target := VIEW_TARGET
var view_distance := VIEW_DISTANCE

func _ready() -> void:
	var manifest: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(scene_manifest))
	var model_directory: String = manifest.get("model_directory", "res://assets/city/luoyang/春")
	var cache := {}
	for entry in manifest.placements:
		var path: String = "%s/%s.gltf" % [model_directory, entry.model]
		if not cache.has(path):
			var document := GLTFDocument.new()
			var state := GLTFState.new()
			if document.append_from_file(path, state) == OK:
				cache[path] = document.generate_scene(state)
			else:
				cache[path] = null
		if cache[path] == null:
			continue
		var instance: Node3D = cache[path].duplicate()
		add_child(instance)
		var p: Array = entry.position
		instance.position = Vector3(p[0], p[1], p[2]) * 0.001
		var q: Array = entry.rotation
		instance.quaternion = Quaternion(q[0], q[1], q[2], q[3]).normalized()
		var s: Array = entry.scale
		instance.scale = Vector3(s[0], s[1], s[2]) * 0.001
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color("a6b5bd")
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color.WHITE
	environment.environment.ambient_light_energy = 0.8
	add_child(environment)
	var sunlight := DirectionalLight3D.new()
	sunlight.rotation_degrees = Vector3(-55, -30, 0)
	sunlight.light_energy = 1.0
	add_child(sunlight)
	camera = Camera3D.new()
	camera.name = "LuoyangCamera"
	add_child(camera)
	camera.projection = Camera3D.PROJECTION_PERSPECTIVE
	var view: Dictionary = manifest.get("camera", {})
	var target: Array = view.get("target", [VIEW_TARGET.x, VIEW_TARGET.y, VIEW_TARGET.z])
	view_target = Vector3(target[0], target[1], target[2])
	view_distance = float(view.get("distance", VIEW_DISTANCE))
	camera.fov = float(view.get("fov", 44.0))
	set_view(float(view.get("yaw", VIEW_YAW)), float(view.get("pitch", VIEW_PITCH)))
	camera.current = true
	for template in cache.values():
		if template != null:
			template.free()


func set_view(yaw_degrees: float, pitch_degrees: float) -> void:
	var yaw := deg_to_rad(yaw_degrees)
	var pitch := deg_to_rad(pitch_degrees)
	camera.position = view_target + Vector3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch)) * view_distance
	camera.look_at(view_target)
