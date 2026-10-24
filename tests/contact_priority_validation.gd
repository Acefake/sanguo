extends SceneTree

const World = preload("res://scripts/war/army_world_3d.gd")
class WorldProbe extends "res://scripts/war/army_world_3d.gd":
	func _ready() -> void: pass
class MapStub extends Node3D:
	var camera := Camera3D.new()
	var hex_world := {"grid":preload("res://scripts/rtk14_hex_grid.gd").shared()}
	func height_at(_x: float, _z: float) -> float: return 0.0
var failures: Array[String] = []
func _initialize() -> void: call_deferred("run")
func check(ok: bool, message: String) -> void:
	if not ok: failures.append(message); push_error(message)
func run() -> void:
	var store = root.get_node("GameState")
	store.persist_enabled = false
	store.agent.enabled = false
	store.prepare_battle_test(true,"plains_clash",42)
	store.time_paused = true
	var own: Dictionary = store.war.active_armies("liu_bei")[0]
	var enemy: Dictionary = store.war.active_armies("yuan_shao")[0]
	var world := WorldProbe.new()
	world.store = store
	world.map = MapStub.new()
	root.add_child(world.map)
	world.map.add_child(world.map.camera)
	root.add_child(world)
	world.set_process(false)
	var grid = store.war.Tactical.grid()
	var cell: int = own["tactical"]["cell"]
	var cells: Array = [cell,grid.neighbors(cell)[0]]
	var direction: Vector2 = (grid.center(cells[1])-grid.center(cells[0])).normalized()
	var side := Vector3(-direction.y,0,direction.x)
	world.presenting = true
	world.presentation_duration = world.TACTICAL_MOVE_SECONDS+world.CONTACT_SECONDS
	for i in range(2):
		var army: Dictionary = [own,enemy][i]
		var id: String = army["id"]
		army["tactical"]["cell"] = cells[i]
		army["tactical"]["phase"] = "近战"
		army["tactical"]["attack_target"] = [enemy,own][i]["id"]
		army["tactical"]["move_path"] = [cells[i]]
		army["tactical"].erase("terrain_delay")
		army["combat_tick"] = store.war.state["tick"]
		army["combat_targets"] = [[enemy,own][i]["id"]]
		army["returning"] = false
		army["units"] = {"infantry":6000,"archers":0,"cavalry":0}
		var point: Vector2 = grid.center(cells[i])
		world.destinations[id] = Vector3(point.x,0,point.y)
		var group := Node3D.new()
		world.add_child(group)
		group.set_meta("army_id",id)
		group.position = world.destinations[id]+side*1.4
		world.formations[id] = group
		world.motion_start[id] = group.position
		world.motion_durations[id] = world.TACTICAL_MOVE_SECONDS
	check(not world._at_display_destination(own["id"]) and not world._at_display_destination(enemy["id"]),"Fixture already reached both cell centers")
	check(not world._combat_visual(own["id"]).is_empty() and not world._combat_visual(enemy["id"]).is_empty(),"Touching units wait for cell centers before attacking")
	# A preferred target still arriving must not hide a second current contact.
	var secondary: Dictionary = enemy.duplicate(true)
	secondary["id"] = "contact-priority-secondary"
	store.war.state["armies"][secondary["id"]] = secondary
	var extra := Node3D.new()
	world.add_child(extra)
	extra.position = world.formations[enemy["id"]].position
	world.formations[secondary["id"]] = extra
	world.formations[enemy["id"]].position += side*20
	own["combat_targets"].append(secondary["id"])
	check(world._combat_visual(own["id"]).get("target_id","") == secondary["id"],"Moving preferred target suppresses another contact")
	world.formations[enemy["id"]].position -= side*20
	world.formations.erase(secondary["id"])
	own["combat_targets"].erase(secondary["id"])
	extra.queue_free()
	store.battle_test = false
	world.observed_enemies[enemy["id"]] = {"observed_at":store.war.state["tick"]-1,"fighting":true}
	check(world._combat_visual(enemy["id"]).is_empty() and world._combat_visual(own["id"]).is_empty(),"Stale enemy sight creates combat")
	store.battle_test = true
	enemy["returning"] = true
	check(world._combat_visual(enemy["id"]).is_empty(),"Withdrawal animation replaced by attack")
	enemy["returning"] = false
	if DisplayServer.get_name() != "headless":
		world._load_mesh()
		world.combat_effects = preload("res://scripts/war/combat_effects_3d.gd").new()
		world.add_child(world.combat_effects)
		world.combat_effects.height_at = world.map.height_at
		world.combat_effects.camera = world.map.camera
		world.next_chatter_at = 100000.0
		for army in [own,enemy]:
			var id: String = army["id"]
			var group: Node3D = world.formations[id]
			world._create_formation(group)
			world._layout_formation(group,64)
			group.get_node("Soldiers").multimesh.visible_instance_count = 64
			world._update_special_troops(group,0,0)
			group.get_node("Soldiers").set_meta("pose_start",1)
			group.get_node("Soldiers").set_meta("transition_at",world.animation_time)
			world.badges[id] = preload("res://scripts/war/army_badge.gd").new()
			world.add_child(world.badges[id])
		world.map.camera.position = world.destinations[own["id"]]+Vector3(0,25,25)
		world.map.camera.look_at(world.destinations[own["id"]])
		store.time_paused = false
		store.time_scale = 1
		world._process(0.05)
		for army in [own,enemy]:
			var group: Node3D = world.formations[army["id"]]
			check(group.get_node("Soldiers").get_meta("pose_start") == 9,"Contact does not immediately interrupt walk animation")
			check(not world._formation_moving(group),"Contact still prefers marching")
			check(not world._at_display_destination(army["id"]),"Contact fix teleports unit to cell center")
		var position: Vector3 = world.formations[own["id"]].position
		for frame in range(8): world._process(0.05)
		check(world.formations[own["id"]].position.is_equal_approx(position),"Touching unit keeps sliding along its old march route")
		check(world.combat_effects.contacts.has(own["id"]) and world.combat_effects.contacts.has(enemy["id"]),"Contact effects missing on one side")
		world.presenting = false
		world.motion_start.clear()
		world._process(0.2)
		for army in [own,enemy]:
			check(world.formations[army["id"]].get_node("Soldiers").get_meta("pose_start") == 9,"Touching units go idle between calendar ticks")
			check(world.combat_effects.contacts.has(army["id"]),"Contact effect disappears between calendar ticks")
		check(store.war.Combat.strength(own) == 6000 and store.war.Combat.strength(enemy) == 6000,"Persistent animation applies extra casualties")
		for kind in ["archers","cavalry"]:
			world.presenting = true
			for army in [own,enemy]:
				var group: Node3D = world.formations[army["id"]]
				army["units"] = {"infantry":0,"archers":6000 if kind == "archers" else 0,"cavalry":6000 if kind == "cavalry" else 0}
				group.set_meta("troop_kind",kind)
				group.get_node("Soldiers").multimesh.visible_instance_count = 0
				world._update_special_troops(group,64 if kind == "archers" else 0,36 if kind == "cavalry" else 0)
				var batch: MultiMeshInstance3D = group.get_node("Archers" if kind == "archers" else "Mounted/Cavalry")
				batch.set_meta("pose_start",1)
				batch.set_meta("transition_at",world.animation_time)
				group.set_meta("combat_pose",false)
			world._process(0.01)
			for army in [own,enemy]:
				var batch: MultiMeshInstance3D = world.formations[army["id"]].get_node("Archers" if kind == "archers" else "Mounted/Cavalry")
				check(batch.get_meta("pose_start") == 9 and int(batch.material_override.get_shader_parameter("pose_start")) == 9,"Contact keeps %s in walk animation" % kind)
		store.time_paused = true
		var paused_clock: float = world.animation_time
		world._process(0.2)
		check(world.animation_time == paused_clock and world.formations[own["id"]].position.is_equal_approx(position),"Paused contact keeps animating or moving")
	world.queue_free()
	world.map.queue_free()
	print("CONTACT_PRIORITY_OK" if failures.is_empty() else "CONTACT_PRIORITY_FAILED")
	quit(0 if failures.is_empty() else 1)
