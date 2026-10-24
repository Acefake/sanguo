extends SceneTree
func _initialize() -> void:
	call_deferred("build")
func build() -> void:
	var scene := Node3D.new()
	root.add_child(scene)
	var world := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color("b7b3a8")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("dce4ed")
	env.ambient_light_energy = 0.8
	world.environment = env
	scene.add_child(world)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, -30, 0)
	sun.light_energy = 0.7
	sun.shadow_enabled = true
	scene.add_child(sun)
	var floor_mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(175, 150)
	floor_mesh.mesh = plane
	floor_mesh.position = Vector3(48, -1.0, 32)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color("8f9586")
	floor_mesh.material_override = mat
	scene.add_child(floor_mesh)
	var ids := ["85fe8b84", "85fe8b84", "e39fc3f7", "c0008e34", "e0e163df", "d6302d91", "6c07a9c7", "5d3d3f89", "c765c353"]
	var capture_path := "res://assets/rtk14/city-gallery.png"
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--models="):
			ids.assign(argument.trim_prefix("--models=").split(","))
		if argument.begins_with("--capture="):
			capture_path = argument.trim_prefix("--capture=")
	for i in range(ids.size()):
		var packed: PackedScene = load("res://assets/rtk14/models/" + ids[i] + ".glb")
		var model: Node3D = packed.instantiate()
		model.position = Vector3((i % 4) * 32, 0, (i / 4) * 32)
		scene.add_child(model)
		if i == 1 and ids[i] == "85fe8b84":
			var flags: Node3D = load("res://assets/rtk14/models/e39fc3f7.glb").instantiate()
			flags.position = model.position
			scene.add_child(flags)
		var label := Label3D.new()
		label.text = ids[i]
		label.position = model.position + Vector3(0, 0, 14)
		label.font_size = 40
		label.pixel_size = 0.12
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		scene.add_child(label)
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 105
	camera.position = Vector3(48, 145, 155)
	scene.add_child(camera)
	camera.look_at(Vector3(48, 0, 32))
	camera.current = true
	await create_timer(2.0).timeout
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(capture_path)
	quit()

