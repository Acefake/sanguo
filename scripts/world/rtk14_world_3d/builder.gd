@abstract
class_name Rtk14World3DBuilder
extends "res://scripts/world/rtk14_world_3d/input.gd"
## 3D 大地图·构建：环境光照、镜头、地形分块、水面河流、地物与城池、关隘、植被、选中环和界面，全部在 _ready 时建一次。

func _build_environment() -> void:
	var world := WorldEnvironment.new()
	var environment := Environment.new()
	map_environment = environment
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color("b8b2a6")
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color("dce1e5")
	environment.ambient_light_energy = 0.55
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	environment.tonemap_exposure = 1.05
	environment.ssao_enabled = true
	environment.ssao_radius = 1.1
	environment.ssao_intensity = 1.25
	environment.ssil_enabled = true
	environment.ssil_radius = 3.0
	environment.ssil_intensity = 0.30
	environment.fog_enabled = true
	environment.fog_light_color = Color("c9c0af")
	environment.fog_density = 0.00045
	world.environment = environment
	add_child(world)
	var sun := DirectionalLight3D.new()
	map_sun = sun
	sun.rotation_degrees = Vector3(-48, -38, 0)
	sun.light_color = Color("fff5e2")
	sun.light_energy = 1.4
	sun.light_angular_distance = 0.8
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 180.0
	add_child(sun)

func _build_camera() -> void:
	camera = Camera3D.new()
	camera.fov = 47.0
	camera.near = 0.3
	camera.far = 6000.0
	camera.current = true
	add_child(camera)
	_update_camera()

func _set_map_quality(mode: int) -> void:
	map_quality_mode = mode
	var viewport := get_viewport()
	viewport.msaa_3d = Viewport.MSAA_DISABLED
	viewport.use_taa = true
	viewport.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR
	viewport.scaling_3d_scale = 0.67 if mode == 0 else 1.0
	viewport.fsr_sharpness = 0.3
	if map_environment != null:
		map_environment.ssil_enabled = mode != 0
	for child in get_children():
		if child is DirectionalLight3D:
			child.directional_shadow_max_distance = 110.0 if mode == 0 else 180.0
	for batch in vegetation_batches:
		batch.lod_bias = 0.35 if mode == 0 else 1.0

func _build_terrain() -> void:
	terrain_root = Node3D.new()
	terrain_root.name = "OriginalTerrain"
	add_child(terrain_root)
	var material := _terrain_material(Vector4(0, 0, WORLD_SIZE, WORLD_SIZE))
	# Hash the final heightfield, including local foundations. A changed source
	# map or building footprint cannot reuse a stale mesh cache.
	var hash_context := HashingContext.new()
	hash_context.start(HashingContext.HASH_SHA256)
	hash_context.update(heights.to_byte_array())
	var cache_key := hash_context.finish().hex_encode().substr(0, 16)
	var cache_dir := ASSET_DIR + "terrain/mesh-cache/v1_%d_%s/" % [TERRAIN_STEP, cache_key]
	DirAccess.make_dir_recursive_absolute(cache_dir)
	var generated := 0
	for cz in range(8):
		for cx in range(8):
			var mesh_path := cache_dir + "%d_%d.res" % [cx, cz]
			var mesh: ArrayMesh
			if FileAccess.file_exists(mesh_path):
				mesh = load(mesh_path) as ArrayMesh
			if mesh == null:
				mesh = _terrain_chunk_mesh(cx, cz)
				var save_error := ResourceSaver.save(mesh, mesh_path, ResourceSaver.FLAG_COMPRESS)
				if save_error != OK:
					push_warning("Terrain mesh cache could not be saved: " + mesh_path)
				generated += 1
			var instance := MeshInstance3D.new()
			instance.mesh = mesh
			instance.material_override = material
			instance.name = "Terrain_%d_%d" % [cx, cz]
			terrain_root.add_child(instance)
			chunk_count += 1
	print("SOURCE_TERRAIN_CACHE_OK step_m=", TERRAIN_STEP, " generated=", generated, " reused=", chunk_count - generated)

func _terrain_chunk_mesh(cx: int, cz: int) -> ArrayMesh:
	var side := CHUNK_CELLS + 1
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	for row in range(side):
		for col in range(side):
			var x := float((cx * CHUNK_CELLS + col) * TERRAIN_STEP)
			var z := float((cz * CHUNK_CELLS + row) * TERRAIN_STEP)
			vertices.append(Vector3(x, height_at(x, z), z))
			normals.append(_normal_at(x, z))
			uvs.append(Vector2(x, z) / WORLD_SIZE)
	for row in range(CHUNK_CELLS):
		for col in range(CHUNK_CELLS):
			var a := row * side + col
			indices.append_array(PackedInt32Array([a, a + 1, a + side, a + 1, a + side + 1, a + side]))
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var importer := ImporterMesh.new()
	importer.add_surface(Mesh.PRIMITIVE_TRIANGLES, arrays)
	importer.generate_lods(60.0, 60.0, [])
	return importer.get_mesh()

func _terrain_material(bounds: Vector4) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = load("res://shaders/rtk14_terrain.gdshader")
	material.set_shader_parameter("world_albedo", load(ASSET_DIR + "terrain/source_albedo.png"))
	material.set_shader_parameter("world_normal_texture", load(ASSET_DIR + "terrain/source_normal.png"))
	material.set_shader_parameter("world_parameters", load(ASSET_DIR + "terrain/source_parameters.png"))
	material.set_shader_parameter("land_control", load(ASSET_DIR + "terrain/source_control.png"))
	var layer_loader = preload("res://scripts/world/rtk14_terrain_layers.gd")
	material.set_shader_parameter("terrain_albedo", layer_loader.load_layers("albedo"))
	material.set_shader_parameter("terrain_normal", layer_loader.load_layers("normal"))
	material.set_shader_parameter("terrain_parameters", layer_loader.load_layers("parameters"))
	var native: Dictionary = _read_json(ASSET_DIR + "terrain/native_materials.json", {})
	material.set_shader_parameter("bilinear_rate", float(native["bilinear_rate"]))
	var palette := PackedVector4Array()
	for entry in native["materials"]:
		palette.append(Vector4(entry["texture_layer"], entry["scale_u"], entry["scale_v"], entry["blend_sharpness"]))
	material.set_shader_parameter("palette", palette)
	var start := float(native["near_far_blending_offset"])
	material.set_shader_parameter("near_far_blending", Vector2(start, start + float(native["near_far_blending_range"])))
	material.set_shader_parameter("map_bounds", bounds)
	return material

func _build_water() -> void:
	var mesh := PlaneMesh.new()
	mesh.size = Vector2(WORLD_SIZE + 600, WORLD_SIZE + 600)
	mesh.subdivide_width = 48
	mesh.subdivide_depth = 48
	var material := ShaderMaterial.new()
	material.shader = load("res://shaders/rtk14_native_water.gdshader")
	material.set_shader_parameter("wave_normal_0", load(ASSET_DIR + "water/4cf245dc.png"))
	material.set_shader_parameter("wave_normal_1", load(ASSET_DIR + "water/a41036bb.png"))
	material.set_shader_parameter("shore_texture", load(ASSET_DIR + "world_water_mask.png"))
	var ocean := MeshInstance3D.new()
	ocean.name = "Water"
	ocean.mesh = mesh
	ocean.material_override = material
	ocean.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ocean.position = Vector3(WORLD_SIZE / 2, WATER_LEVEL, WORLD_SIZE / 2)
	add_child(ocean)
	_build_rivers(material)

func _build_rivers(material: Material) -> void:
	var path := ASSET_DIR + "water/river_mesh.bin"
	if not FileAccess.file_exists(path):
		push_error("Source-sampled river mesh missing; run tools/assets/build_rtk14_water_mesh.py")
		return
	var file := FileAccess.open(path, FileAccess.READ)
	if file.get_buffer(8).get_string_from_ascii() != "RTKWTR01":
		push_error("Invalid source-sampled river mesh")
		return
	var manifest: Dictionary = _read_json(ASSET_DIR + "water/river_mesh.json", {})
	var cache_dir := ASSET_DIR + "water/mesh-cache/v1_" + str(manifest["sha256"]).substr(0, 16) + "/"
	DirAccess.make_dir_recursive_absolute(cache_dir)
	var river_material := material.duplicate() as ShaderMaterial
	river_material.set_shader_parameter("clip_to_shore", true)
	var rivers := Node3D.new()
	rivers.name = "FullMapRiversAndLakes"
	rivers.set_meta("source_sampling", manifest)
	add_child(rivers)
	var count := file.get_32()
	var generated := 0
	for block in range(count):
		var cx := file.get_32()
		var cz := file.get_32()
		var vertex_count := file.get_32()
		var index_count := file.get_32()
		var cache_path := cache_dir + "%d_%d.res" % [cx, cz]
		var mesh: ArrayMesh
		if ResourceLoader.exists(cache_path):
			mesh = load(cache_path) as ArrayMesh
			file.seek(file.get_position() + vertex_count * 12 + index_count * 4)
		else:
			var vertices := file.get_buffer(vertex_count * 12).to_vector3_array()
			var indices := file.get_buffer(index_count * 4).to_int32_array()
			var normals := PackedVector3Array()
			normals.resize(vertex_count)
			normals.fill(Vector3.UP)
			var arrays: Array = []
			arrays.resize(Mesh.ARRAY_MAX)
			arrays[Mesh.ARRAY_VERTEX] = vertices
			arrays[Mesh.ARRAY_NORMAL] = normals
			arrays[Mesh.ARRAY_INDEX] = indices
			var importer := ImporterMesh.new()
			importer.add_surface(Mesh.PRIMITIVE_TRIANGLES, arrays)
			importer.generate_lods(60.0, 60.0, [])
			mesh = importer.get_mesh()
			var error := ResourceSaver.save(mesh, cache_path, ResourceSaver.FLAG_COMPRESS)
			if error != OK:
				push_warning("River mesh cache write failed: " + cache_path)
			generated += 1
		var tile := MeshInstance3D.new()
		tile.name = "River_%d_%d" % [cx, cz]
		tile.mesh = mesh
		tile.material_override = river_material
		tile.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		rivers.add_child(tile)
	print("SOURCE_WATER_CACHE_OK blocks=%d generated=%d reused=%d" % [count, generated, count - generated])

func _build_world_districts() -> void:
	var root := Node3D.new()
	root.name = "AllCityHinterlands"
	add_child(root)
	var soil := StandardMaterial3D.new()
	soil.albedo_color = Color("746744")
	soil.albedo_texture = load(ASSET_DIR + "textures/5fa8dd9d.png")
	var crop := StandardMaterial3D.new()
	crop.albedo_color = Color("637446")
	for entry in _read_json(ASSET_DIR + "world_layout.json", []):
		if entry["kind"] != "village":
			continue
		var site := Node3D.new()
		site.name = str(entry["city"]) + "_" + str(entry["kind"])
		site.set_meta("city_id", str(entry["city"]))
		site.position = Vector3(entry["x"], height_at(entry["x"], entry["z"]) + 0.05, entry["z"])
		site.rotation.y = entry["rotation"]
		root.add_child(site)
		if entry["kind"] == "village":
			var model: Node3D = (load(str(model_library["5816f8ce"]["path"])) as PackedScene).instantiate()
			model.scale = Vector3.ONE * 0.8
			model.position.y = 0.95
			site.add_child(model)

func _model_meshes(model_id: String) -> Array:
	if mesh_library.has(model_id):
		return mesh_library[model_id]
	if not model_library.has(model_id):
		return []
	var packed: PackedScene = load(str(model_library[model_id]["path"]))
	if packed == null:
		return []
	var node := packed.instantiate()
	var found: Array = []
	_collect_meshes(node, Transform3D.IDENTITY, found)
	node.free()
	mesh_library[model_id] = found
	return found

func _collect_meshes(node: Node, transform: Transform3D, found: Array) -> void:
	var current := transform
	if node is Node3D:
		current = transform * node.transform
	if node is MeshInstance3D:
		found.append({"mesh": node.mesh, "transform": current})
	for child in node.get_children():
		_collect_meshes(child, current, found)

func _build_landscape() -> void:
	landscape_root = Node3D.new()
	landscape_root.name = "NativeStaticLandscapeObjects"
	add_child(landscape_root)
	var groups: Dictionary = {}
	var placements: Array = _read_json(ASSET_DIR + "placements.json", [])
	var source_visibility: Dictionary = _read_json(ASSET_DIR + "stage_visibility.json", {})
	var listed_instances: Dictionary = {}
	for identifier in source_visibility.get("visible_instances", []):
		listed_instances[str(identifier)] = true
	landscape_root.set_meta("source_visibility", source_visibility)
	for record in placements:
		static_source_count += 1
		# Negative PreviewVisibilitySet inherits the default-visible stage state.
		# Only objects assigned to a positive set need a stage visibility override.
		if int(record.get("preview_visibility_set", -1)) >= 0 \
			and not listed_instances.has(str(record["instance"])):
			continue
		var model_id := str(record["model"])
		if str(record["name"]).contains("ocean"):
			continue
		if not groups.has(model_id):
			groups[model_id] = []
		var p: Array = record["position"]
		var q: Array = record["rotation"]
		var s: Array = record["scale"]
		var rotation := Quaternion(float(q[0]), float(q[1]), float(q[2]), float(q[3])).normalized()
		var basis := Basis(rotation).scaled_local(Vector3(float(s[0]), float(s[1]), float(s[2])))
		var pose := Transform3D(basis, Vector3(float(p[0]), float(p[1]), float(p[2])) * HEIGHT_SCALE)
		# Preserve every source transform, including Y and original overlaps.
		groups[model_id].append(pose)
		static_instance_count += 1
	for model_id in groups:
		_add_multimeshes(landscape_root, str(model_id), groups[model_id])

func _add_multimeshes(parent: Node3D, model_id: String, transforms: Array, partition := true) -> void:
	if parent == vegetation_root and foliage_mesh_library.is_empty():
		var plant_parts: Array = []
		for plant in vegetation_model_ids:
			plant_parts.append_array(_model_meshes(plant))
		foliage_mesh_library = preload("res://scripts/world/rtk14_foliage_batch.gd").build(plant_parts)

	if parent == vegetation_root and partition:
		var tiles: Dictionary = {}
		for transform: Transform3D in transforms:
			var tile := Vector2i(int(transform.origin.x / 64.0), int(transform.origin.z / 64.0))
			if not tiles.has(tile):
				tiles[tile] = []
			tiles[tile].append(transform)
		for tile in tiles:
			_add_multimeshes(parent, model_id, tiles[tile], false)
		return
	if parent == landscape_root and partition:
		var tiles: Dictionary = {}
		for transform: Transform3D in transforms:
			var tile := Vector2i(floori(transform.origin.x / STATIC_PLACEMENT_CHUNK_SIZE),
				floori(transform.origin.z / STATIC_PLACEMENT_CHUNK_SIZE))
			if not tiles.has(tile):
				tiles[tile] = []
			tiles[tile].append(transform)
		for tile in tiles:
			_add_multimeshes(parent, model_id, tiles[tile], false)
		return
	for part in _model_meshes(model_id):
		var multimesh := MultiMesh.new()
		multimesh.transform_format = MultiMesh.TRANSFORM_3D
		multimesh.mesh = part["mesh"]
		if parent == vegetation_root:
			multimesh.mesh = foliage_mesh_library[part["mesh"].get_instance_id()]
		multimesh.instance_count = transforms.size()
		for index in range(transforms.size()):
			multimesh.set_instance_transform(index, transforms[index] * part["transform"])
		var instance := MultiMeshInstance3D.new()
		instance.multimesh = multimesh
		instance.name = model_id
		instance.set_meta("source_model_id", model_id)
		parent.add_child(instance)
		if parent == landscape_root:
			instance.set_meta("source_poses", transforms)
			if model_id in ["14d3de0c", "4b17a777", "5b5c506d", "beaceb35", "84e24956", "ce4b6bab"]:
				var mountain_mesh := (part["mesh"] as ArrayMesh).duplicate() as ArrayMesh
				multimesh.mesh = mountain_mesh
				var bindings: Dictionary = _read_json(ASSET_DIR + "native-recovery/model-materials.json", {})
				var native_materials: Array = bindings.get(model_id, {}).get("materials", [])
				for surface in range(part["mesh"].get_surface_count()):
					var source := part["mesh"].surface_get_material(surface) as StandardMaterial3D
					var stone := ShaderMaterial.new()
					stone.shader = load("res://shaders/rtk14_mountain.gdshader")
					stone.set_shader_parameter("source_albedo", source.albedo_texture)
					stone.set_shader_parameter("has_normal", source.normal_texture != null)
					if source.normal_texture != null:
						stone.set_shader_parameter("source_normal", source.normal_texture)
					if surface < native_materials.size():
						for texture in native_materials[surface]["textures"]:
							if int(texture["usage"]) == 2:
								stone.set_shader_parameter("source_parameters", load(ASSET_DIR + "textures/" + str(texture["texture_id"]) + ".png"))
								stone.set_shader_parameter("has_parameters", true)
					mountain_mesh.surface_set_material(surface, stone)
		if parent == vegetation_root:
			instance.lod_bias = 0.35
			instance.set_meta("ground_cover", model_id in vegetation_ground_ids)
			var centres := PackedVector3Array()
			var center := Vector3.ZERO
			for transform: Transform3D in transforms:
				centres.append(transform.origin)
				center += transform.origin
			instance.set_meta("placement_centres", centres)
			instance.set_meta("batch_center", center / maxf(1.0, transforms.size()))
			vegetation_batches.append(instance)

func _build_cities() -> void:
	cities_root = Node3D.new()
	cities_root.name = "CompleteCities"
	add_child(cities_root)
	for city in city_data:
		var model_id := str(city["model"])
		if not model_library.has(model_id):
			continue
		var x := float(city["x"])
		var z := float(city["z"])
		# Keep the source city-cell position. Do not silently move cities to nearby terrain.
		var point := Vector2(x, z)
		city["x"] = point.x
		city["z"] = point.y
		var foundation: Dictionary = city_foundations[str(city["id"])]
		var y := float(foundation["height"]) - float(foundation["bottom"])
		var city_root := Node3D.new()
		city_root.name = str(city["id"])
		city_root.position = Vector3(point.x, y + 0.03, point.y)
		cities_root.add_child(city_root)
		var packed: PackedScene = load(str(model_library[model_id]["path"]))
		var model := packed.instantiate()
		model.scale = Vector3.ONE
		city_root.add_child(model)
		city_nodes[str(city["id"])] = city_root
		preload("res://scripts/world/rtk14_details.gd").add_city_banners(city_root, model_id)
		city_pick_positions[str(city["id"])] = city_root.position + Vector3(0, 12, 0)
		var badge := preload("res://scripts/world/world_city_badge.gd").new()
		badge.name = "CityBadge_" + str(city["id"])
		badge.city_name = str(city["name"])
		badge.scale = Vector2.ONE * CITY_BADGE_SCALE
		badge.chosen.connect(_select_city.bind(str(city["id"])))
		badge_layer.add_child(badge)
		badge_layer.move_child(city_popup, -1)
		city_badges[str(city["id"])] = badge

func _build_campaign_city_markers() -> void:
	var sites: Dictionary = preload("res://scripts/war/battle/city_fortifications.gd").sites(GameState)
	for site in sites.values():
		if site["native"]: continue
		var id := str(site["id"])
		var point: Vector2 = site["point"]
		var y := height_at(point.x, point.y)
		var root := Node3D.new()
		root.name = id
		root.position = Vector3(point.x, y, point.y)
		root.set_meta("visual_source", "campaign_fallback_fort")
		cities_root.add_child(root)
		var stone := StandardMaterial3D.new()
		stone.albedo_color = Color("948473")
		for index in range(4):
			var wall := MeshInstance3D.new()
			var box := BoxMesh.new()
			box.size = Vector3(6, 3.8, 0.55)
			box.material = stone
			wall.mesh = box
			wall.rotation.y = index * PI / 2
			wall.position = Vector3(sin(index * PI / 2) * 2.8, 1.9, cos(index * PI / 2) * 2.8)
			root.add_child(wall)
		for x in [-2.8, 2.8]:
			for z in [-2.8, 2.8]:
				var tower := MeshInstance3D.new()
				var cylinder := CylinderMesh.new()
				cylinder.top_radius = 0.7
				cylinder.bottom_radius = 0.7
				cylinder.height = 4.5
				cylinder.material = stone
				tower.mesh = cylinder
				tower.position = Vector3(x, 2.25, z)
				root.add_child(tower)
		city_nodes[id] = root
		city_foundations[id] = {"height": y, "bottom": 0.0, "selection_radius": 7.0}
		city_pick_positions[id] = root.position + Vector3.UP * 12
		var name: String = GameState.war.graph.name_of(id)
		city_data.append({"id": id, "name": name, "x": point.x, "z": point.y, "cells": site["cells"], "model": "campaign_fallback"})
		var badge := preload("res://scripts/world/world_city_badge.gd").new()
		badge.city_name = name
		badge.scale = Vector2.ONE * CITY_BADGE_SCALE
		badge.chosen.connect(_select_city.bind(id))
		badge_layer.add_child(badge)
		badge_layer.move_child(city_popup, -1)
		city_badges[id] = badge

func _build_gates() -> void:
	var root := Node3D.new()
	root.name = "SourceMapGates"
	add_child(root)
	var model_id := "90ca3c38"
	var bounds := AABB()
	var first := true
	for part in _model_meshes(model_id):
		var box: AABB = part["transform"] * part["mesh"].get_aabb()
		bounds = box if first else bounds.merge(box)
		first = false
	for gate in _read_json(ASSET_DIR + "source_gates.json", []):
		var x := float(gate["x"])
		var z := float(gate["z"])
		var level := maxf(height_at(x, z), WATER_LEVEL + 0.6)
		var model_scale := float(gate["model_scale"])
		var scaled_bounds := AABB(bounds.position * model_scale, bounds.size * model_scale)
		var gate_basis := Basis(Vector3.UP, float(gate["rotation"]))
		var inverse_basis := gate_basis.inverse()
		var world_bounds := Transform3D(gate_basis, Vector3(x, 0, z)) * scaled_bounds
		var filled_samples := 0
		for iz in range(maxi(0, int(world_bounds.position.z) - 3), mini(HEIGHT_SIZE, int(world_bounds.end.z) + 4)):
			for ix in range(maxi(0, int(world_bounds.position.x) - 3), mini(HEIGHT_SIZE, int(world_bounds.end.x) + 4)):
				var local := inverse_basis * Vector3(ix - x, 0, iz - z)
				var outside := maxf(maxf(scaled_bounds.position.x - local.x, local.x - scaled_bounds.end.x),
					maxf(scaled_bounds.position.z - local.z, local.z - scaled_bounds.end.z))
				var weight := 1.0 - smoothstep(0.0, 3.0, maxf(0.0, outside))
				var index := iz * HEIGHT_SIZE + ix
				var original := heights[index]
				# Fill small wall-foot gaps. Never excavate the surrounding mountains.
				heights[index] = maxf(original, lerpf(original, level / HEIGHT_SCALE, weight))
				if heights[index] - original > 0.001:
					filled_samples += 1
		var node := Node3D.new()
		node.name = str(gate["id"])
		node.position = Vector3(x, level - scaled_bounds.position.y + 0.03, z)
		node.rotation.y = float(gate["rotation"])
		node.set_meta("source_cells", gate["cells"])
		node.set_meta("model_bounds", scaled_bounds)
		node.set_meta("source_footprint_width", gate["footprint_width"])
		node.set_meta("foundation_mode", "rotated_wall_footprint_fill_only")
		node.set_meta("filled_samples", filled_samples)
		root.add_child(node)
		var model := (load(str(model_library[model_id]["path"])) as PackedScene).instantiate()
		model.scale = Vector3.ONE * model_scale
		node.add_child(model)
		gate_nodes[str(gate["id"])] = node

func _prepare_city_sites() -> void:
	for city in city_data:
		var bounds := AABB()
		var first := true
		for part in _model_meshes(str(city["model"])):
			var mesh: Mesh = part["mesh"]
			var transform: Transform3D = part["transform"]
			var box := transform * mesh.get_aabb()
			bounds = box if first else bounds.merge(box)
			first = false
		var x := float(city["x"])
		var z := float(city["z"])
		var level := maxf(height_at(x, z), WATER_LEVEL + 0.6)
		city_foundations[str(city["id"])] = {"height": level, "bottom": bounds.position.y, "bounds": bounds, "selection_radius": maxf(bounds.size.x, bounds.size.z) * 0.62}
		var min_x := x + bounds.position.x - 1.0
		var max_x := x + bounds.end.x + 1.0
		var min_z := z + bounds.position.z - 1.0
		var max_z := z + bounds.end.z + 1.0
		# Grade only the model footprint and blend its shoulder into the original terrain.
		for iz in range(maxi(0, int(min_z) - 8), mini(HEIGHT_SIZE, int(max_z) + 9)):
			for ix in range(maxi(0, int(min_x) - 8), mini(HEIGHT_SIZE, int(max_x) + 9)):
				var outside := maxf(maxf(min_x - ix, ix - max_x), maxf(min_z - iz, iz - max_z))
				var weight := 1.0 - smoothstep(0.0, 8.0, maxf(0.0, outside))
				var index := iz * HEIGHT_SIZE + ix
				heights[index] = lerpf(heights[index], level / HEIGHT_SCALE, weight)

func _city_ground(point: Vector2) -> Vector2:
	var best := point
	var best_score := INF
	for dz in range(-20, 21, 4):
		for dx in range(-20, 21, 4):
			var p := point + Vector2(dx, dz)
			var height := height_at(p.x, p.y)
			if height < WATER_LEVEL + 1.0:
				continue
			var slope := 1.0 - _normal_at(p.x, p.y).y
			var score := slope * 140.0 + float(dx * dx + dz * dz) * 0.005
			if score < best_score:
				best_score = score
				best = p
	return best

func _build_vegetation() -> void:
	var file := FileAccess.open(ASSET_DIR + "autumn_vegetation.bin", FileAccess.READ)
	if file == null or file.get_buffer(8).get_string_from_ascii() != "RTKPLT02":
		_generate_vegetation()
		return
	var count := file.get_32()
	var records := file.get_buffer(file.get_length() - 12).to_float32_array()
	if records.size() != count * 6:
		push_error("Invalid autumn vegetation cache")
		_generate_vegetation()
		return
	vegetation_root = Node3D.new()
	vegetation_root.name = "NativePaintedAutumnVegetation"
	add_child(vegetation_root)
	var planting: Dictionary = _read_json(ASSET_DIR + "autumn_vegetation.json", {})
	vegetation_model_ids = planting["model_ids"]
	vegetation_ground_ids = planting["ground_cover_models"]
	var ids := vegetation_model_ids
	var groups: Dictionary = {}
	for id in ids:
		groups[id] = []
	for i in range(count):
		var offset := i * 6
		var kind := int(records[offset])
		var x := records[offset + 1]
		var z := records[offset + 2]
		if _inside_gate_footprint(Vector3(x, 0, z)):
			continue
		var size := records[offset + 3]
		var basis := Basis(Vector3.UP, records[offset + 4]).scaled(Vector3.ONE * size)
		groups[ids[kind]].append(Transform3D(basis, Vector3(x, height_at(x, z) + records[offset + 5], z)))
		if ids[kind] in vegetation_ground_ids:
			ground_cover_count += 1
		else:
			vegetation_count += 1
	for id in groups:
		_add_multimeshes(vegetation_root, id, groups[id])
	await _build_overview_vegetation(groups)

func _build_overview_vegetation(groups: Dictionary) -> void:
	var sprites: Dictionary = {}
	if DisplayServer.get_name() != "headless":
		sprites = await preload("res://scripts/world/rtk14_foliage_impostors.gd").build(self)
	vegetation_overview_root = Node3D.new()
	vegetation_overview_root.name = "SamePlacementsOverviewBatches"
	vegetation_root.add_child(vegetation_overview_root)
	vegetation_overview_root.visible = false
	for id in groups:
		for part in _model_meshes(id):
			var mesh := MultiMesh.new()
			mesh.transform_format = MultiMesh.TRANSFORM_3D
			mesh.mesh = sprites[id] if sprites.has(id) else foliage_mesh_library[part["mesh"].get_instance_id()]
			mesh.instance_count = groups[id].size()
			for index in range(groups[id].size()):
				mesh.set_instance_transform(index, groups[id][index] * part["transform"])
			var batch := MultiMeshInstance3D.new()
			batch.name = id
			batch.multimesh = mesh
			batch.lod_bias = 0.35
			batch.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			vegetation_overview_root.add_child(batch)
			overview_vegetation_batches.append(batch)

func _inside_gate_footprint(point: Vector3) -> bool:
	for gate: Node3D in gate_nodes.values():
		var local := gate.transform.affine_inverse() * point
		var bounds: AABB = gate.get_meta("model_bounds")
		if local.x > bounds.position.x - 1.5 and local.x < bounds.end.x + 1.5 and local.z > bounds.position.z - 1.5 and local.z < bounds.end.z + 1.5:
			return true
	return false

func _generate_vegetation() -> void:
	vegetation_root = Node3D.new()
	vegetation_root.name = "TerrainVegetation"
	add_child(vegetation_root)
	var tree_ids := ["c0008e34", "5d3d3f89", "6c07a9c7", "e0e163df", "c765c353", "d6302d91"]
	world_splat = (load(ASSET_DIR + "world_splat.png") as Texture2D).get_image()
	var grass_ids := ["32779e6d", "5d20da2c", "4108f1af"]
	var groups: Dictionary = {}
	for id in tree_ids:
		groups[id] = []
	for id in grass_ids:
		groups[id] = []
	var rng := RandomNumberGenerator.new()
	rng.seed = 14142049
	var occupied: Dictionary = {}
	for index in range(85000):
		var x := rng.randf_range(100, 1990)
		var z := rng.randf_range(60, 1990)
		var y := height_at(x, z)
		var column := int(round((x - float(grid_transform[2])) / float(grid_transform[0])))
		var row := int(round((z - float(grid_transform[3])) / float(grid_transform[1]) - (column % 2) * 0.5))
		if column < 0 or column >= 220 or row < 0 or row >= 220:
			continue
		var cell := (row * 220 + column) * 4
		if map_cells.size() <= cell + 1:
			continue
		var terrain := map_cells[cell + 1] & 255
		var region := map_cells[cell + 1] >> 16
		if region == 0 or terrain not in [2, 3, 5]:
			continue
		if y < WATER_LEVEL + 1.2 or y > 45 or _normal_at(x, z).y < 0.95:
			continue
		var patch := (sin(x * 0.061 + sin(z * 0.033)) * cos(z * 0.057) + 1.0) * 0.5
		if patch < (0.35 if terrain == 3 else 0.94):
			continue
		var occupancy := Vector2i(int(x / 3.5), int(z / 3.5))
		if occupied.has(occupancy):
			continue
		var near_city := false
		for city in city_data:
			if Vector2(x, z).distance_squared_to(Vector2(float(city["x"]), float(city["z"]))) < 24 * 24:
				near_city = true
				break
		if near_city:
			continue
		if world_splat.get_pixel(clampi(int(x), 0, 2047), clampi(int(z), 0, 2047)).r > 0.18:
			continue
		occupied[occupancy] = true
		var suitable_trees: Array = [tree_ids[0], tree_ids[1], tree_ids[2], tree_ids[4]] if z < 1100.0 or y > 23.0 else tree_ids
		var model_id: String = suitable_trees[rng.randi_range(0, suitable_trees.size() - 1)]
		var size := rng.randf_range(0.20, 0.30)
		var basis := Basis(Vector3.UP, rng.randf_range(0, TAU)).scaled(Vector3.ONE * size)
		groups[model_id].append(Transform3D(basis, Vector3(x, y + size * 0.4, z)))
		vegetation_count += 1
		if rng.randf() < 0.35:
			var grass_id: String = grass_ids[rng.randi_range(0, grass_ids.size() - 1)]
			var grass_basis := Basis(Vector3.UP, rng.randf_range(0, TAU)).scaled(Vector3.ONE * rng.randf_range(0.25, 0.42))
			groups[grass_id].append(Transform3D(grass_basis, Vector3(x, y + 0.03, z)))
			ground_cover_count += 1
	for model_id in groups:
		_add_multimeshes(vegetation_root, str(model_id), groups[model_id])

func _build_selection_ring() -> void:
	selected_ring = MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 12.0
	torus.outer_radius = 12.4
	torus.rings = 48
	torus.ring_segments = 8
	selected_ring.mesh = torus
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.45, 0.38, 0.20, 0.50)
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	selected_ring.material_override = material
	selected_ring.visible = false
	add_child(selected_ring)

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var hud := preload("res://scripts/world/world_map_hud.gd").new()
	hud.map = self
	layer.layer = 10
	layer.add_child(hud)
	status = Label.new()
	status.hide()
	layer.add_child(status)
	# Map tools remain available inside the upper-right tools menu.
	vegetation_button = _button("植被：开", _toggle_vegetation)
	labels_button = _button("城名：开", _toggle_labels)
	city_button = _button("城池：开", _toggle_cities)
	hud.add_tool(vegetation_button)
	hud.add_tool(labels_button)
	hud.add_tool(city_button)
	hud.add_tool(_button("全国视野  F", _show_overview))
	hud.add_tool(_button("返回洛阳", func() -> void: focus_city("luoyang")))
	hud.add_tool(_button("查看林地", _focus_forest))
	var cities := OptionButton.new()
	cities.add_item("前往城池")
	var data: Array = _read_json(ASSET_DIR + "cities_map.json", [])
	for city in data: cities.add_item(str(city["name"]))
	cities.item_selected.connect(func(index: int) -> void:
		if index > 0: focus_city(str(data[index - 1]["id"])))
	hud.add_tool(cities)
	var gates := OptionButton.new()
	gates.add_item("前往关口")
	var gate_data: Array = _read_json(ASSET_DIR + "source_gates.json", [])
	for gate in gate_data: gates.add_item("关口 %s" % str(gate["region"]))
	gates.item_selected.connect(func(index: int) -> void:
		if index > 0: focus_gate(str(gate_data[index - 1]["id"])))
	hud.add_tool(gates)
	var quality := OptionButton.new()
	quality.add_item("画质：流畅")
	quality.add_item("画质：精细")
	quality.item_selected.connect(_set_map_quality)
	hud.add_tool(quality)
	hud.add_tool(_button("切换2D地图", func() -> void: get_tree().change_scene_to_file("res://scenes/map_slice.tscn")))
	badge_layer = CanvasLayer.new()
	badge_layer.layer = 1
	add_child(badge_layer)
	city_popup = PanelContainer.new()
	city_popup.name = "CityCommandMenu"
	city_popup.scale = Vector2.ONE * 0.49
	city_popup.custom_minimum_size.x = 190
	city_popup.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	badge_layer.add_child(city_popup)
	var commands := VBoxContainer.new()
	commands.add_theme_constant_override("separation", 5)
	city_popup.add_child(commands)
	for spec in [{"text": "出阵", "callback": _deploy_selected_city}, {"text": "进入", "callback": _enter_selected_city}]:
		var button := _button(spec.text, spec.callback)
		button.custom_minimum_size = Vector2(190, 46)
		button.add_theme_font_override("font", CitySkin.font())
		button.add_theme_font_size_override("font_size", 28)
		button.add_theme_color_override("font_color", Color("423f31"))
		button.add_theme_color_override("font_hover_color", Color("423f31"))
		CitySkin.style_button(button)
		commands.add_child(button)
	city_popup.hide()

func _label(text: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	return label

func _button(text: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = text
	CitySkin.style_button(button)
	button.add_theme_font_size_override("font_size", 14)
	button.pressed.connect(callback)
	return button

func _panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.10, 0.14, 0.11, 0.93)
	style.corner_radius_top_left = 6
	style.corner_radius_top_right = 6
	style.corner_radius_bottom_left = 6
	style.corner_radius_bottom_right = 6
	style.content_margin_left = 14
	style.content_margin_right = 14
	style.content_margin_top = 10
	style.content_margin_bottom = 10
	return style
