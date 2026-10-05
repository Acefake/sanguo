extends SceneTree
var failures: Array[String] = []
func _initialize(): call_deferred("run")
func run():
 var world = preload("res://scripts/war/army_world_3d.gd").new()
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
 troop.material_override.set_shader_parameter("pose_start",9)
 troop.material_override.set_shader_parameter("pose_count",12)
 troop.material_override.set_shader_parameter("pose_rate",12.0)
 DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://docs/validation/army-assets/soldier-motion"))
 var images: Array[Image] = []
 for i in range(12):
  troop.material_override.set_shader_parameter("animation_clock",float(i)/12)
  await process_frame
  await RenderingServer.frame_post_draw
  var image := root.get_texture().get_image()
  image.save_png(ProjectSettings.globalize_path("res://docs/validation/army-assets/soldier-motion/%02d.png" % i))
  images.append(image)
 var changed := 0
 for y in range(images[0].get_height()):
  for x in range(images[0].get_width()):
   if images[0].get_pixel(x,y) != images[5].get_pixel(x,y): changed += 1
 if changed < 500: failures.append("真实GPU小兵没有可见刺击动作")
 print("ARMY_ANIMATION_RENDER changed_pixels=",changed)
 stage.queue_free()
 world.free()
 await process_frame
 quit(0 if failures.is_empty() else 1)
