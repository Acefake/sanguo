extends SceneTree

func _initialize() -> void: call_deferred("run")

func collect(node: Node, transform: Transform3D, boxes: Array, faces: Array) -> void:
	if node is Node3D: transform = transform * node.transform
	if node is MeshInstance3D and node.mesh != null:
		boxes.append(transform * node.mesh.get_aabb())
		for point in node.mesh.get_faces(): faces.append(transform * point)
	for child in node.get_children(): collect(child, transform, boxes, faces)

func hit(source: Vector3, direction: Vector3, faces: Array) -> Variant:
	var nearest: Variant = null
	var distance := INF
	for index in range(0, faces.size(), 3):
		var point: Variant = Geometry3D.ray_intersects_triangle(source, direction, faces[index], faces[index + 1], faces[index + 2])
		if point != null and source.distance_to(point) < distance: nearest = point; distance = source.distance_to(point)
	return nearest

func run() -> void:
	var library: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://assets/rtk14/models.json"))
	var entries: Array = JSON.parse_string(FileAccess.get_file_as_string("res://assets/rtk14/cities_map.json"))
	entries.append_array(JSON.parse_string(FileAccess.get_file_as_string("res://assets/rtk14/source_gates.json")))
	var models := {}
	for entry in entries:
		var id := str(entry["model"])
		if models.has(id): continue
		var scene: PackedScene = load(library[id]["path"])
		var node := scene.instantiate()
		var boxes: Array = []
		var faces: Array = []
		collect(node, Transform3D.IDENTITY, boxes, faces)
		var bounds: AABB = boxes[0]
		for box in boxes: bounds = bounds.merge(box)
		models[id] = {"min_x": bounds.position.x, "max_x": bounds.end.x, "min_z": bounds.position.z, "max_z": bounds.end.z, "min_y": bounds.position.y, "max_y": bounds.end.y}
		var anchors := {}
		for spec in [["east", Vector3.RIGHT], ["west", Vector3.LEFT], ["south", Vector3.BACK], ["north", Vector3.FORWARD]]:
			var direction: Vector3 = spec[1]
			var face: Variant = hit(direction * 50 + Vector3.UP * 1.5, -direction, faces)
			if face == null: continue
			var wall: Vector3 = face - direction * 0.18
			var height := INF
			for offset in [-4, -2, 0, 2, 4]:
				var top: Variant = hit(wall + Vector3.UP * 15 + direction.cross(Vector3.UP) * offset, Vector3.DOWN, faces)
				if top != null and top.y > 1.2: height = minf(height, top.y)
			anchors[spec[0]] = {"x": wall.x, "y": height if not is_inf(height) else 2.5, "z": wall.z}
		models[id]["wall_anchors"] = anchors
		# Sample actual exterior walls above the foundation slab, including angled
		# corners. A rectangular bounds box over-blocked the outside corner hexes.
		var perimeter := PackedVector2Array()
		var center := Vector3(bounds.get_center().x,1.5,bounds.get_center().z)
		for index in range(32):
			var direction := Vector3(cos(float(index)*TAU/32),0,sin(float(index)*TAU/32))
			var point: Variant = hit(center+direction*50,-direction,faces)
			if point != null: perimeter.append(Vector2(point.x,point.z))
		var hull := Geometry2D.convex_hull(perimeter)
		if hull.size() > 3:
			hull.resize(hull.size()-1)
			models[id]["wall_outline"] = Array(hull).map(func(p): return [p.x,p.y])
		node.free()
	var file := FileAccess.open("res://data/war/city_geometry.json", FileAccess.WRITE)
	file.store_string(JSON.stringify({"source": "native imported GLB bounds, exterior wall rays at height 1.5 and convex wall perimeter at scale 1", "models": models}, "\t"))
	print("CITY_GEOMETRY_EXPORTED ", models.size())
	quit()
