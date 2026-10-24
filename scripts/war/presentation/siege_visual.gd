extends RefCounted

static var banks: Dictionary = {}
static var bounds: Dictionary = {}
static var sockets: Dictionary = {}
const KINDS := ["catapult", "ram"]
const RELEASE_TIME := 0.50
const FLIGHT_TIME := 0.85

static func pose_bounds(kind: String) -> AABB:
	if not bounds.has(kind):
		var bank := frames(kind)
		var extent: AABB = bank[0].get_aabb()
		for frame in bank: extent = extent.merge(frame.get_aabb())
		bounds[kind] = extent
	return bounds[kind]

static func launch_socket(engine: Node3D) -> Vector3:
	var kind: String = engine.get_meta("kind","catapult")
	if not sockets.has(kind):
		# Native action reaches the sling's release at one quarter of its cycle.
		var frame: Mesh = frames(kind)[12]
		var top := frame.get_aabb().end.y
		var total := Vector3.ZERO
		var count := 0
		for surface in range(frame.get_surface_count()):
			for point in frame.surface_get_arrays(surface)[Mesh.ARRAY_VERTEX]:
				if point.y < top-0.15: continue
				total += point
				count += 1
		sockets[kind] = total/maxi(count,1)
	return sockets[kind]

static func aim(equipment: Node3D, target: Vector3) -> void:
	if equipment == null: return
	for engine in equipment.get_children():
		var local: Vector3 = equipment.to_local(target)-engine.position
		if Vector2(local.x,local.z).length_squared() < 0.01: continue
		engine.basis = Basis(Vector3.UP,atan2(local.x,local.z)).scaled(engine.basis.get_scale())

static func frames(kind: String) -> Array:
	if banks.has(kind): return banks[kind]
	var document := GLTFDocument.new()
	var state := GLTFState.new()
	assert(document.append_from_file("res://assets/armies/rtk14/models/siege-%s-poses.glb" % kind,state) == OK)
	var source := document.generate_scene(state)
	var meshes: Array = []
	for part in source.find_children("*","MeshInstance3D",true,false): meshes.append(part.mesh)
	assert(meshes.size() == 29)
	banks[kind] = meshes
	source.free()
	return meshes

static func create(kind: String) -> Node3D:
	var engine := Node3D.new()
	engine.set_meta("kind",kind)
	var body := MeshInstance3D.new()
	body.name = "Mechanism"
	body.mesh = frames(kind)[0]
	engine.add_child(body)
	var extent := body.get_aabb().size
	# A ram stays low; scaling it to a tower's height made it unnaturally huge.
	var size := 3.2 / maxf(extent.y,0.01) if kind != "ram" else 0.75
	engine.scale = Vector3.ONE * size
	engine.set_meta("native_scale",size)
	# Both actions advance along +Z: ram thrust and catapult sling release.
	engine.rotation.y = 0.0
	return engine

static func animate(equipment: Node3D, time: float, attacking: bool, marching: bool) -> void:
	if equipment == null: return
	for engine in equipment.get_children():
		var kind: String = engine.get_meta("kind","tower")
		var index := 0
		# Match the original ~2 second action, stagger engines within one volley.
		var phase := time + engine.get_index() * 0.16
		if kind != "tower":
			if attacking: index = 9 + posmod(floori(phase*6.0),12)
			elif marching: index = 1 + posmod(floori(phase*4.0),8)
		engine.get_node("Mechanism").mesh = frames(kind)[index]
