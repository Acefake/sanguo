extends RefCounted
static var flag_anchors: Dictionary = {}

static func add_banner(parent: Node3D, point: Vector3, size := 1.0) -> Node3D:
	var root := Node3D.new()
	root.name = "FactionBanner"
	root.position = point
	root.scale = Vector3.ONE * size
	parent.add_child(root)
	var pole := MeshInstance3D.new()
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = 0.024
	cylinder.bottom_radius = 0.04
	cylinder.height = 2.8
	cylinder.radial_segments = 6
	pole.mesh = cylinder
	pole.position.y = 1.4
	var wood := StandardMaterial3D.new()
	wood.albedo_color = Color("4c3925")
	pole.material_override = wood
	root.add_child(pole)
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	for row in range(5):
		for col in range(13):
			var uv := Vector2(float(col) / 12.0, float(row) / 4.0)
			vertices.append(Vector3(uv.x * 2.05, 2.55 - uv.y * 1.38, 0))
			normals.append(Vector3.FORWARD)
			uvs.append(uv)
	for row in range(4):
		for col in range(12):
			var a := row * 13 + col
			indices.append_array(PackedInt32Array([a, a + 13, a + 1, a + 1, a + 13, a + 14]))
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var cloth := MeshInstance3D.new()
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	cloth.mesh = mesh
	var material := ShaderMaterial.new()
	material.shader = load("res://shaders/rtk14_banner.gdshader")
	material.set_shader_parameter("banner_texture", load("res://assets/rtk14/faction_banner.png"))
	cloth.material_override = material
	root.add_child(cloth)
	return root

static func add_city_banners(parent: Node3D, model_id := "85fe8b84") -> void:
	if flag_anchors.is_empty():
		var data: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://assets/rtk14/city_flag_anchors.json"))
		if data is Dictionary:
			flag_anchors = data
	for point: Array in flag_anchors.get(model_id, []):
		add_banner(parent, Vector3(float(point[0]), float(point[1]), float(point[2])), 0.8)
