extends SceneTree
var failures: Array[String] = []
func _initialize(): call_deferred("run")

func _capture(troop: MultiMeshInstance3D, start: int, count: int, rate: float, folder: String) -> Array:
	troop.material_override.set_shader_parameter("pose_start",start)
	troop.material_override.set_shader_parameter("pose_count",count)
	troop.material_override.set_shader_parameter("pose_rate",rate)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://docs/validation/army-assets/" + folder))
	var images: Array = []
	for i in range(count):
		troop.material_override.set_shader_parameter("animation_clock",float(i) / rate)
		await process_frame
		await RenderingServer.frame_post_draw
		var image := root.get_texture().get_image()
		image.save_png(ProjectSettings.globalize_path("res://docs/validation/army-assets/%s/%02d.png" % [folder,i]))
		images.append(image)
	return images

func _changed(a: Image, b: Image) -> int:
	var changed := 0
	for y in range(a.get_height()):
		for x in range(a.get_width()):
			if a.get_pixel(x,y) != b.get_pixel(x,y): changed += 1
	return changed

func run():
	var world = preload("res://scripts/war/presentation/army_world_3d.gd").new()
	world._load_mesh()
	var stage := Node3D.new()
	root.add_child(stage)
	var camera := Camera3D.new()
	stage.add_child(camera)
	camera.position = Vector3(5, 3, 6)
	camera.look_at(Vector3(0, 0.8, 0.5))
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 4.0
	camera.current = true
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color(0.18,0.20,0.22)
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color.WHITE
	environment.environment.ambient_light_energy = 0.7
	stage.add_child(environment)
	var sun := DirectionalLight3D.new()
	stage.add_child(sun)
	sun.rotation_degrees = Vector3(-50,-30,0)
	var troop := MultiMeshInstance3D.new()
	stage.add_child(troop)
	troop.multimesh = MultiMesh.new()
	troop.multimesh.transform_format = MultiMesh.TRANSFORM_3D
	troop.multimesh.use_custom_data = true
	troop.multimesh.instance_count = 1
	troop.multimesh.mesh = world.mesh
	troop.multimesh.set_instance_transform(0,Transform3D.IDENTITY)
	troop.multimesh.set_instance_custom_data(0, Color(0,0.5,1,1))
	troop.material_override = world.pose_material.duplicate()
	var combat: Array = await _capture(troop,9,12,6.5,"soldier-motion")
	var strike := _changed(combat[0],combat[5])
	if strike < 500: failures.append("真实GPU小兵没有可见刺击动作")
	var idle_start: int = 1 + world.march_meshes.size() + world.combat_meshes.size()
	var idle: Array = await _capture(troop,idle_start,world.idle_meshes.size(),2.2,"soldier-idle")
	var breathing := _changed(idle[0],idle[2])
	if breathing < 150: failures.append("真实GPU小兵没有可见待机动作")
	print("ARMY_ANIMATION_RENDER strike_pixels=",strike," idle_pixels=",breathing)
	stage.queue_free()
	world.free()
	await process_frame
	quit(0 if failures.is_empty() else 1)
