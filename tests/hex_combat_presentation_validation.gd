extends SceneTree

const Hex = preload("res://scripts/war/hex_presentation.gd")
const Effects = preload("res://scripts/war/combat_effects_3d.gd")
const Siege = preload("res://scripts/war/siege_visual.gd")
var failed := false
class WorldProbe extends "res://scripts/war/army_world_3d.gd":
	func _ready() -> void: pass
class MapStub extends Node3D:
	func height_at(_x: float,_z: float) -> float: return 0.0

func _initialize() -> void: call_deferred("run")
func inside(point: Vector3, cell: int, reason: String, overflow: float = 0.0) -> void:
	if Hex.cell_at(point) == cell: return
	if overflow > 0:
		var grid = Hex.Grid.shared()
		var center: Vector2 = grid.center(cell)
		var polygon: PackedVector2Array = grid.polygon(cell)
		var accepted := true
		for i in range(polygon.size()):
			var edge := polygon[(i+1)%polygon.size()]-polygon[i]
			var outward := Vector2(edge.y,-edge.x).normalized()
			if outward.dot(polygon[i]-center) < 0: outward = -outward
			if outward.dot(Vector2(point.x,point.z)-polygon[i]) > overflow+0.001: accepted = false
		if accepted: return
	if not failed: push_error(reason+" point="+str(point))
	failed = true
func run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("This model-envelope test requires the GPU MultiMesh implementation")
		quit(1)
		return
	var store = root.get_node("GameState")
	store.persist_enabled = false
	store.agent.enabled = false
	store.prepare_battle_test(true,"plains_clash",42)
	var world := WorldProbe.new()
	world.store = store
	world.map = MapStub.new()
	root.add_child(world)
	world.set_process(false)
	world._load_mesh()
	var grid = Hex.Grid.shared()
	var cell: int = store.war.active_armies()[0]["tactical"]["cell"]
	var center: Vector2 = grid.center(cell)
	var group := Node3D.new()
	world.add_child(group)
	world._create_formation(group)
	world._layout_formation(group,world.MAX_SOLDIERS)
	var checked := 0
	for kind in ["infantry","archers","cavalry","cavalry_partial","engines"]:
		group.get_node("Soldiers").multimesh.visible_instance_count = world.MAX_SOLDIERS if kind in ["infantry","engines"] else 0
		world._update_special_troops(group,world.MAX_SOLDIERS if kind == "archers" else 0,world.CAVALRY_MODELS if kind == "cavalry" else 36 if kind == "cavalry_partial" else 0)
		world._update_siege_engines(group,{"siege_engines":4 if kind == "engines" else 0,"units":{"infantry":3000}})
		for side in range(12):
			group.position = Vector3(center.x+2.8 if side%2 else center.x,0,center.y)
			group.basis = Basis(Vector3.UP,TAU*side/12.0)
			world._fit_formation_to_hex(group)
			for spec in [["Soldiers","infantry"],["Archers","archers"],["Mounted/Cavalry","cavalry"]]:
				var batch: MultiMeshInstance3D = group.get_node(spec[0])
				var bounds: AABB = world.troop_pose_bounds[spec[1]]
				var standing_center := Vector3.ZERO
				for i in range(batch.multimesh.visible_instance_count):
					standing_center += batch.global_transform*(batch.multimesh.get_instance_transform(i)*world.troop_ground_centers[spec[1]])
					for corner in range(8):
						inside(batch.global_transform*(batch.multimesh.get_instance_transform(i)*bounds.get_endpoint(corner)),cell,"Soldier attack envelope crosses assigned hex: "+kind)
						checked += 1
				if batch.multimesh.visible_instance_count > 0:
					standing_center /= batch.multimesh.visible_instance_count
					# Thinned formations deliberately keep the front ranks filled.
					# Their visible centroid shifts, but every foot remains in the hex.
					inside(standing_center,cell,"Visible formation centroid crosses hex: "+kind)
					if batch.multimesh.visible_instance_count == batch.multimesh.instance_count:
						assert(Vector2(standing_center.x,standing_center.z).distance_to(center) < 0.001,"Full formation is not centered in the hex: "+kind)
			var target := group.global_position+Vector3(cos(side),0,sin(side))*15
			var equipment: Node3D = group.get_node("SiegeEngines")
			Siege.aim(equipment,target)
			for engine in equipment.get_children():
				assert(engine.global_basis.z.normalized().dot(((target-engine.global_position)*Vector3(1,0,1)).normalized()) > 0.999,"Mechanism aims backwards")
				var bounds := Siege.pose_bounds(str(engine.get_meta("kind")))
				for corner in range(8):
					inside(engine.to_global(bounds.get_endpoint(corner)),cell,"Aimed engine crosses hex")
		print("HEX_ENVELOPE_OK ",kind," fit=",group.get_meta("formation_scale"))
		if failed: quit(1); return
	group.get_node("Soldiers").multimesh.visible_instance_count = 64
	world._update_special_troops(group,0,0)
	world._update_siege_engines(group,{"siege_engines":0,"units":{"infantry":3000}})
	var adjacent: Vector2 = grid.center(grid.neighbors(cell)[0])
	group.position = Vector3(center.x,0,center.y)
	world._fit_formation_to_hex(group)
	group.set_meta("march_layout_scale",group.get_meta("formation_scale"))
	var last := Vector3.ZERO
	for step in range(81):
		var location: Vector2 = center.lerp(adjacent,float(step)/80)
		group.position = Vector3(location.x,0,location.y)
		world._fit_formation_to_hex(group,true)
		var batch: MultiMeshInstance3D = group.get_node("Soldiers")
		var current := batch.global_transform*batch.multimesh.get_instance_transform(0).origin
		if step > 0: assert(current.distance_to(last) < 0.3,"March layout snaps at hex boundary")
		last = current
	if failed: quit(1); return
	group.position = Vector3(center.x,0,center.y)
	group.basis = Basis.IDENTITY
	group.get_node("Soldiers").multimesh.visible_instance_count = 0
	world._update_special_troops(group,64,0)
	world._fit_formation_to_hex(group)
	var target_cell: int = grid.neighbors(cell)[0]
	var point: Vector2 = grid.center(target_cell)
	var target := Vector3(point.x+2.0,0,point.y)
	var effects := Effects.new()
	root.add_child(effects)
	effects.begin_frame()
	effects.show_archer_volley("hex",group,target,1.4,target_cell)
	var streaks: Array = []
	for arrow in effects.projectiles["bows:hex"]:
		var streak: MeshInstance3D = arrow.get_node_or_null("AirStreak")
		if streak == null: continue
		streaks.append(streak)
		assert(streak.global_basis.y.dot(arrow.global_basis.z.normalized()) > 0.999,"White arrow streak points away from flight direction")
		assert(absf(streak.global_position.distance_to(arrow.global_position)-0.65) < 0.001,"White streak detached from flying arrow")
	assert(streaks.size() == 16,"White streaks are not interleaved among arrows")
	assert(streaks.any(func(streak): return streak.visible and streak.get_parent().visible),"No white streak appears in flight")
	for arrow in effects.projectiles["bows:hex"]: inside(arrow.get_meta("landing"),target_cell,"Field arrow spills into another hex")
	effects.show_city_volley("hex",group.position+Vector3.UP*4,target,0.9,target_cell)
	assert(effects.contacts["city:hex"]["arrows"].filter(func(arrow): return arrow.has_node("AirStreak")).size() == 24,"City volley has no interleaved white streaks")
	assert(not effects.contacts["city:hex"]["spark"].visible and not effects.contacts["city:hex"]["dust"].visible,"City white effect still appears on ground")
	for arrow in effects.contacts["city:hex"]["arrows"]: inside(arrow.get_meta("landing"),target_cell,"City arrow spills into another hex")
	assert(effects.target_markers.size() == 1,"Same target hex creates duplicate glows")
	var marker_alpha: float = effects.target_markers[target_cell].mesh.surface_get_material(0).albedo_color.a
	effects.show_archer_volley("hex",group,target,1.4,target_cell)
	assert(effects.target_markers[target_cell].mesh.surface_get_material(0).albedo_color.a == marker_alpha,"Paused target glow changes")
	effects.show_contact("switch",group.position,target,1.45,false,true,3.0,false,1.55,target_cell)
	effects.show_contact("switch",group.position,target,1.45)
	assert(effects.volley_impacts.is_empty(),"Ranged attack still creates landing flashes")
	effects.begin_frame()
	effects.end_frame()
	assert(effects.target_markers.is_empty() and effects.volley_impacts.is_empty(),"Idle target still glows")
	await process_frame
	assert(streaks.all(func(streak): return not is_instance_valid(streak)),"White streaks remain after volley cleanup")
	print("HEX_COMBAT_PRESENTATION PASS checked=",checked," pose bounds and 81 moving positions; 64/96 arrow landings, normal size, directional mechanisms, shared target glow and cleanup")
	world.map.free()
	quit()