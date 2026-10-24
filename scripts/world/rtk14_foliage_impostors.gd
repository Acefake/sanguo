extends RefCounted

# Render the source geometry to transparent foliage silhouettes for map overview.
# One sprite remains at every original generated placement; no density reduction.
static func build(world: Node) -> Dictionary:
	var cache_dir := "user://rtk14-overview-foliage-v2"
	DirAccess.make_dir_recursive_absolute(cache_dir)
	var output: Dictionary = {}
	for id in world.vegetation_model_ids:
		var path: String = world.model_library[id]["path"]
		var revision := FileAccess.get_modified_time(path)
		var bounds := AABB()
		var first := true
		for part in world._model_meshes(id):
			var box: AABB = part["transform"] * part["mesh"].get_aabb()
			bounds = box if first else bounds.merge(box)
			first = false
			for surface in range(part["mesh"].get_surface_count()):
				var mat := part["mesh"].surface_get_material(surface) as StandardMaterial3D
				revision = maxi(revision, FileAccess.get_modified_time(mat.albedo_texture.resource_path))
		var cache_path: String = cache_dir + "/" + str(id) + "-" + str(revision) + ".png"
		var image: Image
		var extent := maxf(bounds.size.x, bounds.size.y) * 1.12
		if FileAccess.file_exists(cache_path):
			image = Image.load_from_file(cache_path)
		else:
			var viewport := SubViewport.new()
			viewport.size = Vector2i(256,256)
			viewport.transparent_bg = true
			viewport.own_world_3d = true
			viewport.mesh_lod_threshold = 0.0
			viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
			world.add_child(viewport)
			var model: Node3D = (load(path) as PackedScene).instantiate()
			viewport.add_child(model)
			_unlit(model)
			var camera := Camera3D.new()
			camera.projection = Camera3D.PROJECTION_ORTHOGONAL
			camera.size = extent
			camera.current = true
			viewport.add_child(camera)
			camera.position = bounds.get_center() + Vector3(0,sin(deg_to_rad(75)),cos(deg_to_rad(75))) * 50.0
			camera.look_at(bounds.get_center(), Vector3.UP)
			await world.get_tree().process_frame
			await world.get_tree().process_frame
			await RenderingServer.frame_post_draw
			image = viewport.get_texture().get_image()
			image.save_png(cache_path)
			viewport.queue_free()
		image.generate_mipmaps()
		var material := StandardMaterial3D.new()
		material.albedo_texture = ImageTexture.create_from_image(image)
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
		material.alpha_scissor_threshold = 0.18
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
		material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		material.billboard_keep_scale = true
		material.roughness = 0.9
		var quad := QuadMesh.new()
		quad.size = Vector2.ONE * extent
		var projected_y := bounds.get_center().y * cos(deg_to_rad(75)) - bounds.get_center().z * sin(deg_to_rad(75))
		quad.center_offset = Vector3(bounds.get_center().x, projected_y, 0)
		quad.material = material
		output[id] = quad
	return output

static func _unlit(node: Node) -> void:
	if node is MeshInstance3D:
		for surface in range(node.mesh.get_surface_count()):
			var material := node.mesh.surface_get_material(surface).duplicate() as StandardMaterial3D
			material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			node.set_surface_override_material(surface, material)
	for child in node.get_children():
		_unlit(child)
