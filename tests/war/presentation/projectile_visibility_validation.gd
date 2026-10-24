extends SceneTree
const Effects = preload("res://scripts/war/presentation/combat_effects_3d.gd")
const Siege = preload("res://scripts/war/presentation/siege_visual.gd")
func _initialize() -> void: call_deferred("run")
func run() -> void:
	var effects := Effects.new()
	root.add_child(effects)
	var camera := Camera3D.new()
	root.add_child(camera)
	effects.camera = camera
	camera.position = Vector3(0,20,30)
	var close := effects.arrow_scale(Vector3.ZERO)
	camera.position = Vector3(0,70,110)
	assert(effects.arrow_scale(Vector3.ZERO) == close,"Distant arrows must retain normal model size")
	var formation := Node3D.new()
	root.add_child(formation)
	var bows := MultiMeshInstance3D.new()
	bows.name = "Archers"
	bows.multimesh = MultiMesh.new()
	bows.multimesh.transform_format = MultiMesh.TRANSFORM_3D
	bows.multimesh.use_custom_data = true
	bows.multimesh.mesh = BoxMesh.new()
	bows.multimesh.instance_count = 64
	for i in range(64):
		bows.multimesh.set_instance_transform(i,Transform3D(Basis.IDENTITY,Vector3(i%8,0,i/8)))
		bows.multimesh.set_instance_custom_data(i,Color(float(i%12)/12,0.5,1,1))
	formation.add_child(bows)
	effects.begin_frame()
	effects.show_archer_volley("a",formation,Vector3(0,0,14),1.4)
	var arrow: Node3D = effects.projectiles["bows:a"][0]
	assert(arrow.visible and arrow.position.z > 0.36,"Draw release did not emit an arrow")
	var first := arrow.transform
	effects.show_archer_volley("a",formation,Vector3(0,0,14),1.4)
	assert(first == arrow.transform,"Paused arrow moves")
	effects.show_archer_volley("a",formation,Vector3(0,0,14),1.5)
	assert(arrow.position.z > first.origin.z,"Arrow does not fly toward target")
	var equipment := Node3D.new()
	root.add_child(equipment)
	equipment.add_child(Siege.create("catapult"))
	equipment.add_child(Siege.create("ram"))
	effects.show_siege_projectiles("s",equipment,Vector3(0,0,14),0.6)
	assert(effects.projectiles.has("stone:s:0") and not effects.projectiles.has("stone:s:1"),"Wrong weapon emits stones")
	assert(effects.projectiles["stone:s:0"][0].visible)
	effects.show_siege_projectiles("s",equipment,Vector3(0,0,14),1.45)
	assert(not effects.projectiles["stone:s:0"][0].visible and effects.projectiles["stone:s:0"][1].visible,"Stone impact is missing")
	effects.show_city_volley("c",Vector3(0,8,-14),Vector3.ZERO,0.8)
	assert(effects.contacts["city:c"]["arrows"].size() == 96)
	assert(effects.projectiles["bows:a"].size() == 64)
	effects.begin_frame()
	effects.end_frame()
	assert(effects.projectiles.is_empty() and effects.contacts.is_empty(),"Idle effects keep firing")
	print("PROJECTILE_VISIBILITY_VALIDATION PASS bow release, flight, pause, catapult impact, ram exclusion, city detail and cleanup")
	quit()
