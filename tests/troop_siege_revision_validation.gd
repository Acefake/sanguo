extends SceneTree
const Siege = preload("res://scripts/war/siege_visual.gd")
func _initialize() -> void: call_deferred("run")
func run() -> void:
	for kind in ["catapult","ram"]:
		var frames := Siege.frames(kind)
		var changed := 0.0
		for surface in range(frames[0].get_surface_count()):
			var material = frames[0].surface_get_material(surface)
			assert(material.albedo_texture != null and material.normal_texture != null)
			var start = frames[0].surface_get_arrays(surface)[Mesh.ARRAY_VERTEX]
			for pose in frames:
				var points = pose.surface_get_arrays(surface)[Mesh.ARRAY_VERTEX]
				assert(points.size() == start.size(),"Native mechanism topology changed")
				for i in range(points.size()):
					assert(points[i].is_finite())
					changed = maxf(changed,start[i].distance_to(points[i]))
		assert(changed > 0.5,"Native siege mechanism does not move")
		var equipment := Node3D.new()
		var engine := Siege.create(kind)
		equipment.add_child(engine)
		Siege.animate(equipment,0.8,true,false)
		assert(engine.get_node("Mechanism").mesh == frames[13])
		Siege.animate(equipment,0.8,false,false)
		assert(engine.get_node("Mechanism").mesh == frames[0],"Idle weapon keeps attacking")
		equipment.free()
		print("SIEGE_NATIVE_ACTION_OK ",kind," displacement=",changed)
	var world := preload("res://scripts/war/army_world_3d.gd").new()
	world._load_mesh()
	assert(world.archer_mesh.surface_get_arrays(0)[Mesh.ARRAY_COLOR].size() > 0,"Archer reference uniform missing")
	assert(world.archer_material.get_shader_parameter("reference_archer"))
	var cavalry = world.cavalry_mesh.surface_get_arrays(0)
	var top := 0.0
	var visible_body := 0
	for i in range(cavalry[Mesh.ARRAY_VERTEX].size()):
		if cavalry[Mesh.ARRAY_TEX_UV][i].x >= 0.5 and cavalry[Mesh.ARRAY_TEX_UV][i].y >= 0.5:
			top = maxf(top,cavalry[Mesh.ARRAY_VERTEX][i].y)
			if cavalry[Mesh.ARRAY_VERTEX][i].y > 2.45 and absf(cavalry[Mesh.ARRAY_VERTEX][i].x) < 0.2: visible_body += 1
	assert(top > 2.7,"Rider is hidden inside horse")
	assert(visible_body > 40,"Only the rider weapon is above the horse")
	world.free()
	print("TROOP_SIEGE_REVISION_VALIDATION PASS rider upper-body vertices=",visible_body)
	quit()
