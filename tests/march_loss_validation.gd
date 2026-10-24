extends SceneTree

const Hex = preload("res://scripts/war/hex_presentation.gd")
class WorldProbe extends "res://scripts/war/army_world_3d.gd":
	func _ready() -> void: pass
class MapStub extends Node3D:
	var camera := Camera3D.new()
	func height_at(_x: float,_z: float) -> float: return 0.0
func _initialize() -> void: call_deferred("run")
func run() -> void:
	if DisplayServer.get_name() == "headless": quit(1); return
	var store = root.get_node("GameState")
	store.persist_enabled = false
	store.agent.enabled = false
	store.prepare_battle_test(true,"plains_clash",42)
	var world := WorldProbe.new()
	world.store = store
	world.map = MapStub.new()
	root.add_child(world.map)
	world.map.add_child(world.map.camera)
	root.add_child(world)
	world.set_process(false)
	world._load_mesh()
	var armies: Array = [store.war.active_armies("liu_bei")[0],store.war.active_armies("yuan_shao")[0]]
	var grid = Hex.Grid.shared()
	var cell: int = armies[0]["tactical"]["cell"]
	var center: Vector2 = grid.center(cell)
	var adjacent: Vector2 = grid.center(grid.neighbors(cell)[0])
	var group := Node3D.new()
	world.add_child(group)
	world._create_formation(group)
	world._layout_formation(group,64)
	for kind in ["infantry","archers","cavalry"]:
		group.get_node("Soldiers").multimesh.visible_instance_count = 64 if kind == "infantry" else 0
		world._update_special_troops(group,64 if kind == "archers" else 0,36 if kind == "cavalry" else 0)
		group.position = Vector3(center.x,0,center.y)
		group.basis = Basis.IDENTITY
		world._fit_formation_to_hex(group)
		var size: float = group.get_meta("formation_scale")
		group.set_meta("march_layout_scale",size)
		var batch: MultiMeshInstance3D = group.get_node({"infantry":"Soldiers","archers":"Archers","cavalry":"Mounted/Cavalry"}[kind])
		var previous := Vector3.ZERO
		for step in range(161):
			var point: Vector2 = center.lerp(adjacent,float(step)/160)
			group.position = Vector3(point.x,0,point.y)
			group.basis = Basis(Vector3.UP,0.3*float(step)/160)
			world._fit_formation_to_hex(group,true)
			assert(is_equal_approx(group.get_meta("formation_scale"),size),"Marching soldiers change scale")
			var position := batch.global_transform*batch.multimesh.get_instance_transform(0).origin
			if step > 0: assert(position.distance_to(previous) < 0.2,"Formation snaps across hex boundary")
			previous = position
			var bounds: AABB = world.troop_pose_bounds[kind]
			var culling: AABB = batch.multimesh.custom_aabb
			for corner in range(8): assert(culling.has_point(batch.multimesh.get_instance_transform(0)*bounds.get_endpoint(corner)),"Animated soldier leaves culling bounds")
		print("MARCH_CONTINUITY_OK ",kind)
	group.queue_free()
	for army in armies:
		var formation := Node3D.new()
		world.add_child(formation)
		world.formations[army["id"]] = formation
		army["combat_tick"] = store.war.state["tick"]
		army["daily_loss_tick"] = store.war.state["tick"]
		army["daily_loss"] = 123
		army["units"] = {"infantry":3000,"cavalry":0,"archers":0}
	world.presenting = true
	for ranged in [false,true]:
		for label in world.loss_floaters: label.free()
		world.loss_floaters.clear()
		world.floated_armies.clear()
		world.loss_contact_since.clear()
		world.floated_tick = store.war.state["tick"]
		armies[0]["units"] = {"infantry":0 if ranged else 3000,"archers":3000 if ranged else 0,"cavalry":0}
		armies[0]["tactical"]["cell"] = cell
		armies[1]["tactical"]["cell"] = cell+2 if ranged else cell+1
		armies[0]["tactical"]["attack_target"] = armies[1]["id"]
		armies[0]["tactical"]["phase"] = "远射" if ranged else "交战"
		armies[1]["tactical"]["attack_target"] = armies[0]["id"]
		for army in armies:
			var p: Vector2 = grid.center(army["tactical"]["cell"])
			world.destinations[army["id"]] = Vector3(p.x,0,p.y)
			world.formations[army["id"]].position = Vector3(p.x+40,0,p.y)
		world.presentation_elapsed = 0
		world._spawn_loss_floaters()
		world.presentation_elapsed = 3
		world._spawn_loss_floaters()
		assert(world.loss_floaters.is_empty(),"Damage labels appear before arrival")
		for army in armies: world.formations[army["id"]].position = world.destinations[army["id"]]
		world._spawn_loss_floaters()
		assert(world.loss_floaters.is_empty(),"Damage labels appear before strike delay")
		world.presentation_elapsed = 3.8
		world._spawn_loss_floaters()
		assert(not world.loss_floaters.is_empty(),"Legal contact has no damage label")
		for label in world.loss_floaters:
			assert(label is Label3D and label.font_size == 36 and is_equal_approx(label.pixel_size,0.022),"Old damage style was not restored")
		var count := world.loss_floaters.size()
		world._spawn_loss_floaters()
		assert(world.loss_floaters.size() == count,"Duplicate damage labels")
		var label := world.loss_floaters[0]
		var id: String = label.get_meta("army")
		var delay := 0.70 if world._loss_contact_mode(id) == "ranged" else 0.20
		var hit_at: float = world.loss_contact_since[id]+delay
		var badge := preload("res://scripts/war/army_badge.gd").new()
		world.add_child(badge)
		world.badges[id] = badge
		world.presentation_stats[id] = {"strength":3123,"morale":100.0}
		var previous_loss := -1
		for step in range(11):
			world.presentation_elapsed = hit_at+world.LOSS_COUNT_SECONDS*float(step)/10
			world._update_display_stats()
			world._update_loss_floaters(0)
			var loss := int(label.text.trim_prefix("−"))
			assert(loss >= previous_loss and loss <= 123,"Dynamic loss counter overshoots or reverses")
			assert(badge.strength+loss == 3123,"Remaining strength and dynamic loss disagree")
			if step == 5: assert(loss > 0 and loss < 123,"Loss counter jumps directly to final total")
			previous_loss = loss
		assert(label.text == "−123" and badge.strength == 3000,"Dynamic counter misses settled total")
		world.badges.erase(id)
		badge.queue_free()
		store.time_paused = true
		world._update_loss_floaters(1)
		assert(world.loss_floaters[0].get_meta("age") == 0.0,"Paused damage label advances")
		store.time_paused = false
		world._update_loss_floaters(world.DAY_SECONDS)
		assert(world.loss_floaters.is_empty(),"Expired damage labels remain")
		print("LOSS_CONTACT_OK ranged=",ranged)
	print("MARCH_LOSS PASS")
	quit()
