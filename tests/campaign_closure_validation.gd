extends SceneTree

const Store = preload("res://scripts/game_state.gd")
const Combat = preload("res://scripts/war/combat_system.gd")
const Fort = preload("res://scripts/war/city_fortifications.gd")
var failures: Array[String] = []
var results: Array = []

func _initialize() -> void: call_deferred("run")
func check(value: bool, text: String) -> void:
	if not value and not failures.has(text): failures.append(text); push_error(text)

func fixture() -> Node:
	var store := Store.new()
	store.persist_enabled = false
	store._load_demo()
	store.city_state("xiaopei")["garrison"] = 50000
	store.city_state("xiaopei")["units"] = {"infantry": 35000, "archers": 12000, "cavalry": 3000}
	store.city_state("xiaopei")["defense"] = 100
	store.war.start_campaign()
	return store

func digest(store) -> Dictionary:
	return {"war": store.war.export_state(), "places": store.scenario["places"], "day": store.day, "month": store.month, "year": store.year, "chronicles": store.chronicles}

func equivalent(a: Variant, b: Variant) -> bool:
	if typeof(a) in [TYPE_INT, TYPE_FLOAT] and typeof(b) in [TYPE_INT, TYPE_FLOAT]: return absf(float(a) - float(b)) < 0.00000001
	if typeof(a) != typeof(b): return false
	if a is Dictionary:
		if a.size() != b.size(): return false
		for key in a:
			if not b.has(key) or not equivalent(a[key], b[key]): return false
		return true
	if a is Array:
		if a.size() != b.size(): return false
		for index in range(a.size()):
			if not equivalent(a[index], b[index]): return false
		return true
	return a == b

func difference(a: Variant, b: Variant, path: String = "root") -> String:
	if equivalent(a, b): return ""
	if a is Dictionary and b is Dictionary:
		for key in a:
			if not b.has(key): return path + "." + str(key) + " missing"
			var found := difference(a[key], b[key], path + "." + str(key))
			if found != "": return found
		for key in b:
			if not a.has(key): return path + "." + str(key) + " added"
	elif a is Array and b is Array and a.size() == b.size():
		for index in range(a.size()):
			var found := difference(a[index], b[index], path + "[%d]" % index)
			if found != "": return found
	return path + ": " + str(a) + " != " + str(b)

func validate(store) -> void:
	var war = store.war
	var occupied := {}
	var officers := {}
	for army in war.active_armies():
		check(not officers.has(army["officer_id"]), "duplicate active officer " + str(army["officer_id"]))
		officers[army["officer_id"]] = true
		check(int(war.ledger(army)["missing"]) == 0, "unbalanced army " + str(army["id"]))
		if army.has("tactical"):
			var cell := int(army["tactical"]["cell"])
			check(war.Tactical.can_enter(war, army, cell), "army in blocked building " + str(army["id"]))
			check(not occupied.has(cell), "overlapping tactical cell " + str(cell))
			occupied[cell] = true
	for node in store.scenario["places"]:
		var city: Dictionary = store.city_state(node)
		if not city.has("population"): continue
		var sum := 0
		var wounded := 0
		for type in Combat.TYPES:
			sum += int(city["units"][type])
			wounded += int(city["wounded_units"][type])
		check(sum == int(city["garrison"]), "city inventory mismatch " + str(node))
		check(wounded == int(city.get("wounded", 0)), "city wound inventory mismatch " + str(node))
		for field in ["garrison", "population", "treasury", "grain"]: check(int(city.get(field, 0)) >= 0, "negative city resource " + str(node) + ":" + field)
	check(not war.state.has("battlefield"), "formal campaign retained global board")

func run() -> void:
	root.get_node("GameState").persist_enabled = false
	var seeds := [42, 1910901, 6482]
	var days := 180
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--seed="): seeds = [int(argument.trim_prefix("--seed="))]
		if argument.begins_with("--days="): days = maxi(100, int(argument.trim_prefix("--days=")))
	for seed_value in seeds:
		var store := fixture()
		store.war.rng.seed = seed_value
		var start := Time.get_ticks_msec()
		var maximum := 0
		var replay: Node
		for index in range(days):
			await store.advance_day()
			maximum = maxi(maximum, store.war.active_armies().size())
			validate(store)
			if index == 89:
				replay = fixture()
				replay.scenario = JSON.parse_string(JSON.stringify(store.scenario))
				replay.year = store.year
				replay.month = store.month
				replay.day = store.day
				replay.action_points = store.action_points
				replay.chronicles = JSON.parse_string(JSON.stringify(store.chronicles))
				replay.war.setup(replay, JSON.parse_string(JSON.stringify(store.war.export_state())))
			elif index in range(90, 100):
				await replay.advance_day()
				var original := digest(store)
				var restored := digest(replay)
				if not equivalent(original, restored):
					for side in ["original", "restored"]:
						var diagnostic := FileAccess.open("res://docs/validation/replay-%d-%d-%s.json" % [seed_value, index, side], FileAccess.WRITE)
						diagnostic.store_string(JSON.stringify(original if side == "original" else restored, "\t"))
				check(equivalent(original, restored), "save replay diverged at seed %d day %d: %s" % [seed_value, index, difference(original, restored)])
			if index == 99: replay.free()
		var boards: int = store.war.state["battlefields"].size()
		check(boards > 0 and maximum > 0, "NPC campaign never reached a battlefield")
		results.append({"seed": seed_value, "days": days, "maximum_active_armies": maximum, "battlefields": boards, "elapsed_ms": Time.get_ticks_msec() - start, "factions": store.war.state["faction_status"]})
		print("CAMPAIGN_SEED_DONE ", JSON.stringify(results[-1]))
		store.free()
	var file := FileAccess.open("res://docs/validation/campaign-closure-2026-10-06.json", FileAccess.WRITE)
	file.store_string(JSON.stringify({"results": results, "failures": failures}, "\t"))
	print("CAMPAIGN_CLOSURE_OK" if failures.is_empty() else "CAMPAIGN_CLOSURE_FAILED: " + str(failures))
	quit(0 if failures.is_empty() else 1)
