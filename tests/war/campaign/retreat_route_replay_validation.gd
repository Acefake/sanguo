extends SceneTree
var failures: Array[String] = []
func _initialize() -> void: call_deferred("run")
func check(ok: bool, message: String) -> void:
	if not ok: failures.append(message); push_error(message)
func run() -> void:
	root.get_node("GameState").persist_enabled = false
	var store = preload("res://scripts/core/game_state.gd").new()
	store.persist_enabled = false
	store._load_demo()
	for city in store.scenario["places"].values():
		if city.has("garrison"): city["faction"] = "cao_cao"
	for node in ["runan","lujiang"]: store.city_state(node)["faction"] = "liu_bei"
	var first: Dictionary = store.war.route("liu_bei","jianye","runan")
	var second: Dictionary = store.war.route("liu_bei","jianye","lujiang")
	check(first["found"] and second["found"] and is_equal_approx(first["cost"],second["cost"]),"Fixture does not offer equal-cost friendly retreat routes")
	var army := {"id":"route-fixture","faction":"liu_bei","location":{"node":"jianye","edge":""}}
	store.war._start_return(army)
	var original: Dictionary = army.duplicate(true)
	store.scenario = JSON.parse_string(JSON.stringify(store.scenario))
	army = {"id":"route-fixture","faction":"liu_bei","location":{"node":"jianye","edge":""}}
	store.war._start_return(army)
	check(army == original and army.get("return_destination","") == "lujiang","JSON city order changes an equal-cost retreat route")
	store.free()
	print("RETREAT_ROUTE_REPLAY ","PASS" if failures.is_empty() else failures)
	quit(0 if failures.is_empty() else 1)
