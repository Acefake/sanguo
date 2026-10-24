extends SceneTree
class WorldProbe extends "res://scripts/war/presentation/army_world_3d.gd":
	func _ready() -> void: pass
	func refresh() -> void: pass
	func _battle_point(cell: int) -> Vector3:
		var point: Vector2 = store.war.Tactical.grid().center(cell)
		return Vector3(point.x,0,point.y)
var failures: Array[String] = []
func _initialize() -> void: call_deferred("run")
func check(ok: bool, message: String) -> void:
	if not ok: failures.append(message); push_error(message)
func run() -> void:
	var store = root.get_node("GameState")
	store.persist_enabled = false
	store.prepare_battle_test(true,"plains_clash",42)
	var world := WorldProbe.new()
	world.store = store
	root.add_child(world)
	world.set_process(false)
	var army: Dictionary = store.war.active_armies("liu_bei")[0]
	var id: String = army["id"]
	var grid = store.war.Tactical.grid()
	var a: int = army["tactical"]["cell"]
	var b: int = grid.neighbors(a)[0]
	var incoming: Vector2 = (grid.center(b)-grid.center(a)).normalized()
	var c: int = Array(grid.neighbors(b)).filter(func(cell):
		var alignment := incoming.dot((grid.center(cell)-grid.center(b)).normalized())
		return alignment > 0.2 and alignment < 0.9)[0]
	var start: Vector2 = grid.center(a)
	var end: Vector2 = grid.center(b)
	world.motion_start[id] = Vector3(start.x,0,start.y)
	world.destinations[id] = Vector3(end.x,0,end.y)
	army["tactical"]["move_path"] = [a,b]
	army["tactical"]["previous_goal"] = c
	world._build_march_route(id)
	check(world.march_routes.has(id),"Route missing")
	var first := world._march_position(id,0.999)
	var arrival := world._march_position(id,1.0)
	var heading := (arrival-first).normalized()
	var minimum := INF
	var maximum := 0.0
	var previous := world._march_position(id,0.0)
	for sample in range(1,101):
		var point := world._march_position(id,float(sample)/100)
		check(grid.pick(Vector2(point.x,point.z)) in [a,b],"Curve leaves legal movement cells")
		var distance := point.distance_to(previous)
		minimum = minf(minimum,distance)
		maximum = maxf(maximum,distance)
		previous = point
	check(minimum > 0.0 and maximum/minimum < 1.05,"March stops or changes speed at route samples")
	world.motion_start[id] = arrival
	end = grid.center(c)
	world.destinations[id] = Vector3(end.x,0,end.y)
	army["tactical"]["move_path"] = [b,c]
	army["tactical"]["previous_goal"] = c
	world._build_march_route(id)
	check(world._march_position(id,0.0).is_equal_approx(arrival),"Position jumps at daily boundary")
	var departure := (world._march_position(id,0.001)-arrival).normalized()
	check(heading.dot(departure) > 0.99,"Heading snaps at daily boundary")
	# A marching unit keeps moving while a different unit finishes its contact.
	var fighter: Dictionary = store.war.active_armies("yuan_shao")[0]
	fighter["combat_tick"] = store.war.state["tick"]
	fighter["daily_loss_tick"] = store.war.state["tick"]
	fighter["daily_loss"] = 100
	army["combat_tick"] = -1
	army["daily_loss_tick"] = -1
	for unit in [army,fighter]:
		var group := Node3D.new()
		world.add_child(group)
		group.set_meta("army_id",unit["id"])
		group.position = Vector3(start.x,0,start.y)
		world.formations[unit["id"]] = group
		world.destinations[unit["id"]] = Vector3(end.x,0,end.y)
	world.begin_day({})
	check(world.presentation_duration > world.TACTICAL_MOVE_SECONDS,"Fixture has no contact tail")
	world.presentation_elapsed = world.TACTICAL_MOVE_SECONDS+0.1
	check(world._formation_moving(world.formations[id]),"Unrelated combat interrupts marching")
	check(world._march_position(id,world.presentation_elapsed/world._march_seconds(id)).distance_to(world.destinations[id]) > 0.01,"March arrives early and waits at a hex center")
	for group in world.formations.values(): group.free()
	world.free()
	print("CONTINUOUS_MARCH_OK" if failures.is_empty() else "CONTINUOUS_MARCH_FAILED")
	quit(0 if failures.is_empty() else 1)
