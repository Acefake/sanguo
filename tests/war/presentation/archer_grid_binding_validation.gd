extends SceneTree
class WorldProbe extends "res://scripts/war/presentation/army_world_3d.gd":
	func _ready() -> void: pass
class MapStub extends Node3D:
	func height_at(_x: float,_z: float) -> float: return 0.0
var failures: Array[String] = []
func _initialize() -> void: call_deferred("run")
func check(ok: bool, reason: String) -> void:
	if not ok: failures.append(reason); push_error(reason)
func run() -> void:
	var store = root.get_node("GameState")
	store.persist_enabled = false
	store.agent.enabled = false
	store.prepare_battle_test(true,"plains_clash",42)
	store.time_paused = true
	var war = store.war
	var shooter: Dictionary = war.active_armies("liu_bei")[0]
	var victim: Dictionary = war.active_armies("yuan_shao")[0]
	for army in war.active_armies():
		if army["id"] not in [shooter["id"],victim["id"]]: army["status"] = "ended"
	var grid = war.Tactical.grid()
	var source: int = shooter["tactical"]["cell"]
	var destination := -1
	for adjacent in grid.neighbors(source):
		for candidate in grid.neighbors(adjacent):
			if grid.distance(source,candidate) == 2 and war.Tactical.can_enter(war,victim,candidate) and war.Tactical.Fort.line_of_sight(war.state["battlefield"],source,candidate): destination = candidate; break
		if destination >= 0: break
	check(destination >= 0,"No legal ranged fixture")
	if destination < 0: quit(1); return
	shooter["units"] = {"infantry":0,"archers":6000,"cavalry":0}
	victim["units"] = {"infantry":6000,"archers":0,"cavalry":0}
	victim["tactical"]["cell"] = destination
	for army in [shooter,victim]:
		army["returning"] = false
		army["action"] = {"type":"hold"}
	war._observe_all()
	war.Tactical.resolve(war)
	check(shooter.get("combat_tick",-1) == war.state["tick"] and shooter["tactical"].get("phase","") == "远射","Archer did not resolve legal shot")
	var world := WorldProbe.new()
	world.store = store
	world.map = MapStub.new()
	root.add_child(world)
	world.set_process(false)
	world.presenting = true
	var direction: Vector2 = (grid.center(destination)-grid.center(source)).normalized()
	var side := Vector3(-direction.y,0,direction.x)*1.4
	for army in [shooter,victim]:
		var id: String = army["id"]
		var point: Vector2 = grid.center(int(army["tactical"]["cell"]))
		world.destinations[id] = Vector3(point.x,0,point.y)
		var group := Node3D.new()
		world.add_child(group)
		group.position = world.destinations[id]+side
		world.formations[id] = group
		world.motion_start[id] = group.position
	check(not world._at_display_destination(shooter["id"]) and not world._at_display_destination(victim["id"]),"Fixture has already reached centers")
	check(world._combat_visual(shooter["id"]).get("ranged",false),"Legal shot blocked by display interpolation")
	var saved_status: String = victim["status"]
	victim["status"] = "ended"
	check(world._combat_visual(shooter["id"]).is_empty(),"Ended target remains shootable")
	victim["status"] = saved_status
	var saved_units: Dictionary = victim["units"]
	victim["units"] = {"infantry":0,"archers":0,"cavalry":0}
	check(world._combat_visual(shooter["id"]).is_empty(),"Dead target remains shootable")
	victim["units"] = saved_units
	var saved_orders: Dictionary = shooter.get("orders",{}).duplicate(true)
	shooter["orders"] = {"engage":false}
	check(world._combat_visual(shooter["id"]).is_empty(),"No-engage order ignored")
	shooter["orders"] = saved_orders
	var terrain_rules: Dictionary = war.rules["terrain"]
	terrain_rules["archer_test_delay"] = {"entry_attack":0}
	shooter["tactical"]["terrain_delay"] = "archer_test_delay"
	check(world._combat_visual(shooter["id"]).is_empty(),"Terrain entry delay ignored")
	shooter["tactical"].erase("terrain_delay")
	terrain_rules.erase("archer_test_delay")
	var fortifications: Dictionary = war.state["battlefield"].get("fortifications",{})
	var middle: int = grid.pick(grid.center(source).lerp(grid.center(destination),0.5))
	fortifications["archer-test-blocker"] = {"id":"archer-test-blocker","cells":[middle]}
	war.state["battlefield"]["fortifications"] = fortifications
	check(world._combat_visual(shooter["id"]).is_empty(),"Obstructed line of sight ignored")
	fortifications.erase("archer-test-blocker")
	shooter["combat_targets"] = []
	check(world._combat_visual(shooter["id"]).is_empty(),"Only receiving damage creates false shot")
	shooter["combat_targets"] = [victim["id"]]
	shooter["action"] = {"type":"evade"}
	check(world._combat_visual(shooter["id"]).is_empty(),"Evade command ignored")
	shooter["action"] = {"type":"hold"}
	shooter["returning"] = true
	check(world._combat_visual(shooter["id"]).is_empty(),"Withdrawal ignored")
	shooter["returning"] = false
	shooter["combat_tick"] = int(war.state["tick"])-1
	check(world._combat_visual(shooter["id"]).is_empty(),"Stale shot replayed")
	shooter["tactical"]["cell"] = source
	victim["tactical"]["cell"] = source
	war.Tactical.migrate_positions(war)
	check(shooter["tactical"]["cell"] != victim["tactical"]["cell"],"Duplicate occupancy retained")
	victim["tactical"]["cell"] = -1
	war.Tactical.migrate_positions(war)
	check(war.Tactical.can_enter(war,victim,int(victim["tactical"]["cell"])),"Negative index not recovered")
	victim["tactical"]["cell"] = 999999
	war.Tactical.migrate_positions(war)
	check(war.Tactical.can_enter(war,victim,int(victim["tactical"]["cell"])),"Overflow index not recovered")
	var blocked: int = victim["tactical"]["cell"]
	war.state["battlefield"]["blocked"].append(blocked)
	war.Tactical.migrate_positions(war)
	check(victim["tactical"]["cell"] != blocked and war.Tactical.can_enter(war,victim,int(victim["tactical"]["cell"])),"Obstacle occupancy not recovered")
	for army in [shooter,victim]:
		var cell: int = army["tactical"]["cell"]
		check(grid.pick(grid.center(cell)) == cell,"Coordinate/index roundtrip mismatch")
	var board: Dictionary = war.state["battlefield"]
	var saved_blocked: Array = board["blocked"].duplicate()
	var saved_strength: int = war.Combat.strength(victim)
	war._observe_all()
	war.Tactical.clear_target_cache()
	war.Tactical.targets(war,shooter)
	for q in range(int(board["min_column"]),int(board["max_column"])+1):
		for r in range(int(board["min_row"]),int(board["max_row"])+1): board["blocked"].append(war.Tactical.cell_at(q,r))
	war.Tactical.migrate_positions(war)
	check(victim["tactical"].get("placement_invalid",false) and not war.Tactical.can_attack(war,victim),"Full board did not isolate invalid placement")
	check(war.Tactical.targets(war,shooter).is_empty(),"Cached targets retain invalid ghost placement")
	check(war.Combat.strength(victim) == saved_strength,"Full board discarded soldiers")
	board["blocked"] = saved_blocked
	war.Tactical.migrate_positions(war)
	check(not victim["tactical"].get("placement_invalid",false),"Placement did not recover when a cell became free")
	world.map.free()
	print("ARCHER_GRID_BINDING_OK" if failures.is_empty() else "ARCHER_GRID_BINDING_FAILED "+str(failures))
	quit(0 if failures.is_empty() else 1)
