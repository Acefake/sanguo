extends SceneTree
const T = preload("res://scripts/war/battle/tactical_battlefield.gd")
const Roles = preload("res://scripts/war/battle/troop_roles.gd")
const Fort = preload("res://scripts/war/battle/city_fortifications.gd")
var store
var failures: Array[String] = []
class WorldProbe extends "res://scripts/war/presentation/army_world_3d.gd":
	func _ready() -> void: pass
func _initialize() -> void: call_deferred("run")
func check(ok: bool, message: String) -> void:
	if not ok: failures.append(message); push_error(message)
func fixture(kind: String, gap: int) -> Array:
	store.prepare_battle_test(true,"plains_clash",42)
	var war = store.war
	var own: Dictionary = war.active_armies("liu_bei")[0]
	var enemy: Dictionary = war.active_armies("yuan_shao")[0]
	for army in war.active_armies():
		if army["id"] not in [own["id"],enemy["id"]]: army["status"] = "ended"
	var board: Dictionary = war.state["battlefield"]
	var legal := Fort.movement_board(war,board,"liu_bei")
	var corridor: Array = []
	for row in range(int(board["min_row"])+2,int(board["max_row"])-2):
		for column in range(int(board["min_column"])+1,int(board["max_column"])-8):
			var cells: Array = []
			for i in range(8): cells.append(T.cell_at(column+i,row))
			if not cells.all(func(c): return T.in_battlefield(legal,c) and T.terrain_class(c) == "plains"): continue
			var cursor: int = cells[0]
			var flat := true
			for step in range(4):
				cursor = T._path_step(cursor,cells[7],{},legal,1)
				if T.terrain_class(cursor) != "plains": flat = false
			if flat: corridor = cells; break
		if not corridor.is_empty(): break
	assert(not corridor.is_empty(),"Fixture needs a clear plains corridor")
	own["units"] = {"infantry":0,"cavalry":0,"archers":0}
	own["units"][kind] = 3000
	enemy["units"] = {"infantry":3000,"cavalry":0,"archers":0}
	own["tactical"]["cell"] = corridor[0]
	enemy["tactical"]["cell"] = corridor[gap]
	own["tactical"]["role"] = "flank"
	own["tactical"]["lane"] = T.column_of(corridor[0])
	own["operation"]["role"] = "flank"
	own["corps_task"]["type"] = "flank"
	own["action"] = {"type":"engage","enemy":enemy["id"]}
	enemy["action"] = {"type":"hold"}
	war._observe_all()
	T.clear_target_cache()
	return [own,enemy]
func run() -> void:
	store = root.get_node("GameState")
	store.persist_enabled = false
	store.agent.enabled = false
	for kind in ["infantry","cavalry","archers"]:
		var pair := fixture(kind,3)
		var before: int = store.war.Combat.strength(pair[1])
		store.war._resolve_contacts({})
		check(store.war.Combat.strength(pair[1]) == before,"Three-hex attack: "+kind)
	for kind in ["infantry","cavalry","archers"]:
		var pair := fixture(kind,2)
		if kind == "archers": pair[0]["action"] = {"type":"hold"}
		var before: int = store.war.Combat.strength(pair[1])
		store.war._resolve_contacts({})
		check((store.war.Combat.strength(pair[1]) < before) == (kind == "archers"),"Two-hex range: "+kind)
	var pair := fixture("infantry",1)
	pair[0]["action"] = {"type":"request_support"}
	T.move(store.war)
	check(pair[0]["action"]["type"] == "engage" and pair[0]["tactical"]["attack_target"] == pair[1]["id"],"AI ignored adjacent enemy commander")
	var before: int = store.war.Combat.strength(pair[1])
	store.war._resolve_contacts({})
	check(store.war.Combat.strength(pair[1]) < before,"Adjacent commander not attacked")
	var world := WorldProbe.new()
	world.store = store
	root.add_child(world)
	for army in pair:
		var group := Node3D.new()
		world.add_child(group)
		world.formations[army["id"]] = group
		var point: Vector2 = T.grid().center(int(army["tactical"]["cell"]))
		group.position = Vector3(point.x,0,point.y)
	pair[0]["combat_tick"] = store.war.state["tick"]
	check(not world._combat_visual(pair[0]["id"]).is_empty(),"Adjacent rendered contact missing")
	var target_group: Node3D = world.formations[pair[1]["id"]]
	var settled := target_group.position
	var distant: Vector2 = T.grid().center(T.cell_at(T.column_of(pair[1]["tactical"]["cell"])+4,T.row_of(pair[1]["tactical"]["cell"])))
	target_group.position = Vector3(distant.x,0,distant.y)
	check(world._combat_visual(pair[0]["id"]).is_empty(),"Melee effect plays before formation reaches adjacent hex")
	target_group.position = settled
	world.free()
	var travel := {}
	for kind in ["infantry","cavalry"]:
		pair = fixture(kind,7)
		var start: int = pair[0]["tactical"]["cell"]
		for day in range(2):
			store.war.state["tick"] += 1
			store.war._observe_all()
			T.move(store.war)
			print("MOVEMENT_SAMPLE ",kind," day=",day," path=",pair[0]["tactical"].get("move_path",[])," ground=",T.terrain_class(pair[0]["tactical"]["cell"])," credit=",pair[0]["tactical"].get("movement_credit",0)," phase=",pair[0]["tactical"]["phase"])
		travel[kind] = T.cell_distance(start,pair[0]["tactical"]["cell"])
	check(travel["cavalry"] > travel["infantry"],"Plains cavalry is not faster: "+str(travel))
	pair = fixture("archers",1)
	var bow: Dictionary = pair[0].duplicate(true)
	var foot: Dictionary = pair[0].duplicate(true)
	bow["melee_attack"] = true
	foot["units"] = {"infantry":3000,"cavalry":0,"archers":0}
	foot["melee_attack"] = true
	var weak: Dictionary = store.war.Combat.losses_detail(bow,pair[1],store.war.rules,"plains",1.0)
	var strong: Dictionary = store.war.Combat.losses_detail(foot,pair[1],store.war.rules,"plains",1.0)
	check(weak["raw"] < strong["raw"],"Archers have no melee weakness")
	check(Roles.mobility(foot,"plains",store.war.rules) > Roles.mobility({"units":{"cavalry":3000}},"mountains",store.war.rules),"Rough ground does not constrain cavalry")
	var board: Dictionary = store.war.state["battlefield"]
	for site in board["fortifications"].values():
		var polygon := Fort.footprint(site)
		if polygon.size() < 3: continue
		for cell in site["cells"]:
			check(cell == site["center"] or Geometry2D.is_point_in_polygon(T.grid().center(cell),polygon),"Exterior hex blocked by small wall overlap")
	print("TROOP_TRAITS_CONTACT ","PASS" if failures.is_empty() else "FAIL", " travel=",travel," failures=",failures)
	quit(0 if failures.is_empty() else 1)
