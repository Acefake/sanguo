extends RefCounted

# Preserve each source surface's UV and texture binding while drawing one surface.
static func build(parts: Array) -> Dictionary:
	var colors: Array[Image] = []
	var normals: Array[Image] = []
	var bindings: Dictionary = {}
	var surface_bindings: Dictionary = {}
	for part in parts:
		var mesh: Mesh = part["mesh"]
		var layers: Array[Vector2] = []
		for surface in range(mesh.get_surface_count()):
			var material := mesh.surface_get_material(surface) as StandardMaterial3D
			assert(material != null and material.albedo_texture != null)
			var key := str(material.albedo_texture.get_instance_id()) + ":" + str(material.normal_texture.get_instance_id() if material.normal_texture != null else 0)
			if not bindings.has(key):
				bindings[key] = colors.size()
				colors.append(_image(material.albedo_texture, Color.WHITE))
				normals.append(_image(material.normal_texture, Color(0.5,0.5,1)))
			layers.append(Vector2(bindings[key], 1.0 if material.normal_texture != null else 0.0))
		surface_bindings[mesh.get_instance_id()] = layers
	var color_array := Texture2DArray.new()
	var normal_array := Texture2DArray.new()
	assert(color_array.create_from_images(colors) == OK)
	assert(normal_array.create_from_images(normals) == OK)
	var shared := ShaderMaterial.new()
	shared.shader = load("res://shaders/rtk14_foliage_array.gdshader")
	shared.set_shader_parameter("albedo_layers", color_array)
	shared.set_shader_parameter("normal_layers", normal_array)
	shared.set_shader_parameter("layer_count", float(colors.size()))
	var result: Dictionary = {}
	for part in parts:
		var source: Mesh = part["mesh"]
		if result.has(source.get_instance_id()):
			continue
		var vertices := PackedVector3Array()
		var directions := PackedVector3Array()
		var tangents := PackedFloat32Array()
		var uv := PackedVector2Array()
		var uv2 := PackedVector2Array()
		var indices := PackedInt32Array()
		for surface in range(source.get_surface_count()):
			var arrays := source.surface_get_arrays(surface)
			var base := vertices.size()
			var count: int = arrays[Mesh.ARRAY_VERTEX].size()
			vertices.append_array(arrays[Mesh.ARRAY_VERTEX])
			directions.append_array(arrays[Mesh.ARRAY_NORMAL])
			uv.append_array(arrays[Mesh.ARRAY_TEX_UV])
			if arrays[Mesh.ARRAY_TANGENT] != null:
				tangents.append_array(arrays[Mesh.ARRAY_TANGENT])
			else:
				for vertex in range(count):
					tangents.append_array(PackedFloat32Array([1,0,0,1]))
			for vertex in range(count):
				var binding: Vector2 = surface_bindings[source.get_instance_id()][surface]
				uv2.append(Vector2(binding.x / maxf(1.0, colors.size() - 1.0), binding.y))
			for index: int in arrays[Mesh.ARRAY_INDEX]:
				indices.append(base + index)
		var merged: Array = []
		merged.resize(Mesh.ARRAY_MAX)
		merged[Mesh.ARRAY_VERTEX] = vertices
		merged[Mesh.ARRAY_NORMAL] = directions
		merged[Mesh.ARRAY_TANGENT] = tangents
		merged[Mesh.ARRAY_TEX_UV] = uv
		merged[Mesh.ARRAY_TEX_UV2] = uv2
		merged[Mesh.ARRAY_INDEX] = indices
		var importer := ImporterMesh.new()
		importer.add_surface(Mesh.PRIMITIVE_TRIANGLES, merged, [], {}, shared)
		importer.generate_lods(60.0,60.0,[])
		var baked := importer.get_mesh()
		baked.set_meta("source_texture_layers", surface_bindings[source.get_instance_id()])
		baked.set_meta("source_vertex_count", vertices.size())
		baked.set_meta("source_index_count", indices.size())
		result[source.get_instance_id()] = baked
	print("FOLIAGE_SURFACE_BATCH_OK meshes=",result.size()," texture_layers=",colors.size())
	return result

static func _image(texture: Texture2D, fallback: Color) -> Image:
	var image: Image
	if texture != null:
		image = texture.get_image().duplicate()
		if image.is_compressed():
			image.decompress()
		image.convert(Image.FORMAT_RGBA8)
		image.resize(512,512,Image.INTERPOLATE_LANCZOS)
	else:
		image = Image.create(512,512,false,Image.FORMAT_RGBA8)
		image.fill(fallback)
	image.generate_mipmaps()
	return image
