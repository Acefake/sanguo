extends "res://tests/city_defense_separation_validation.gd"

# Boundary regressions supplement the main siege suite using its real scenario helpers.
func lone_attacker(war) -> Dictionary:
	var mover: Dictionary = war.active_armies("yuan_shao")[0]
	for unit in war.active_armies():
		if unit["id"] != mover["id"]: unit["status"] = "ended"
	return mover

func open_gate(war, mover: Dictionary) -> int:
	var siege: Dictionary = Defense.create(war, "xiaopei", mover)
	war.state["sieges"]["xiaopei"] = siege
	siege["gate"] = 0.0
	siege["gate_breached"] = true
	Defense.open_passage(war, "xiaopei", siege, [])
	return Defense.breach_cell(war, "xiaopei")

func outside_neighbor(war, board: Dictionary, cell: int) -> int:
	var legal := Fort.movement_board(war, board, "yuan_shao")
	for value in T.neighbors(cell):
		if T.in_battlefield(legal, int(value)) and Fort.inside_city(board, int(value)) == "": return int(value)
	return -1

func run() -> void:
	var store = root.get_node("GameState")
	prepare(store)
	var war = store.war
	var board: Dictionary = war.state["battlefield"]
	var mover := lone_attacker(war)
	var breach := open_gate(war, mover)
	var outside := outside_neighbor(war, board, breach)
	check(outside >= 0, "no legal exterior cavalry entry fixture")
	if outside >= 0:
		mover["units"] = {"infantry": 0, "archers": 0, "cavalry": 8000}
		mover["siege_engines"] = 0
		mover["tactical"]["cell"] = outside
		mover["tactical"]["movement_credit"] = 0.0
		mover["action"] = {"type": "continue"}
		T.move(war)
		check(Fort.inside_city(board, int(mover["tactical"]["cell"])) == "xiaopei", "real cavalry movement did not enter breached city")
		var route: Array = mover["tactical"].get("move_path", [])
		var legal := Fort.movement_board(war, board, "yuan_shao")
		for index in range(1, route.size()):
			check(T.cell_distance(int(route[index - 1]), int(route[index])) == 1 and T.in_battlefield(legal, int(route[index])), "cavalry entry skipped or crossed an illegal cell")
		# A personal decision to hold remains in force at an open gate.
		mover["tactical"]["cell"] = outside
		mover["autonomy"] = {"stance": "independent"}
		mover["action"] = {"type": "hold", "tactical_contract": true, "path": [outside], "goal_cell": outside}
		war.state["tick"] += 1
		T.move(war)
		check(int(mover["tactical"]["cell"]) == outside, "autonomous hold was replaced with entry movement")
		mover["action"] = {"type": "hold"}
		war.state["tick"] += 1
		T.move(war)
		check(int(mover["tactical"]["cell"]) == outside, "ordinary autonomous hold was replaced with siege march")
		# Spend a complete infantry budget moving to the exterior gate approach.
		var farther := outside_neighbor(war, board, outside)
		check(farther >= 0, "no exterior approach budget fixture")
		if farther >= 0:
			mover["units"] = {"infantry": 8000, "archers": 0, "cavalry": 0}
			mover["tactical"]["cell"] = farther
			mover["tactical"]["movement_credit"] = 0.0
			mover["action"] = {"type": "reposition", "template": "approach_objective", "tactical_contract": true, "path": [farther, outside], "goal_cell": outside}
			var occupied := {farther: mover["id"]}
			T._move_committed(war, mover, board, occupied, {})
			check(int(mover["tactical"]["cell"]) == outside and mover["tactical"]["move_path"].size() == 2, "exhausted movement budget received an extra entry step")

	prepare(store)
	war = store.war
	board = war.state["battlefield"]
	mover = war.active_armies("yuan_shao")[0]
	var siege := Defense.create(war, "xiaopei", mover)
	war.state["sieges"]["xiaopei"] = siege
	var empty_city: Dictionary = store.city_state("xiaopei").duplicate(true)
	empty_city["garrison"] = 0
	check(not Defense.occupation_state(war, "xiaopei", siege, [], empty_city, 8000)["ok"], "intact empty city captured without breach or entry")
	check(not Defense.occupation_state(war, "xiaopei", siege, [mover], empty_city, 8000)["ok"], "intact empty city captured even though facilities were closed")

	# Keeping infantry fixed while adding cavalry cannot add facility damage.
	var mixed: Dictionary = mover.duplicate(true)
	mixed["units"] = {"infantry": 4000, "archers": 0, "cavalry": 0}
	mixed["siege_engines"] = 2
	var foot_power := Defense.facility_power(war, [mixed])
	mixed["units"]["cavalry"] = 20000
	var mixed_power := Defense.facility_power(war, [mixed])
	check(is_equal_approx(float(foot_power["wall"]), float(mixed_power["wall"])) and is_equal_approx(float(foot_power["gate"]), float(mixed_power["gate"])), "cavalry mix changed facility damage or disabled its infantry")
	mixed["units"]["infantry"] = 8000
	check(float(Defense.facility_power(war, [mixed])["wall"]) > float(mixed_power["wall"]), "additional infantry failed to increase facility damage")

	# Facility state belongs to the city across attackers; repairs close the passage.
	siege["gate"] = 0.0
	siege["gate_breached"] = true
	Defense.open_passage(war, "xiaopei", siege, [])
	Defense.persist(war, "xiaopei", siege)
	var other: Dictionary = mover.duplicate(true)
	other["faction"] = "cao_cao"
	var replacement := Defense.create(war, "xiaopei", other)
	check(float(replacement["gate"]) == 0.0 and bool(replacement["breach_open"]), "changing attacker restored gate durability")
	Defense.repair(war, "xiaopei", 20.0)
	check(not Defense.breach_open(war, "xiaopei") and float(siege["gate"]) > 0.0, "repair failed to close breached gate")
	check(Fort.blocked_for(war, board, "yuan_shao").has(int(Fort.for_city(store, "xiaopei")["gate"])), "repair left gate passage walkable")

	# Missing render geometry must not bypass positive city defense.
	prepare(store)
	war = store.war
	board = war.state["battlefield"]
	var cached_sites: Dictionary = Fort._sites.duplicate(true)
	for key in Fort._sites.keys():
		if Fort._sites[key]["id"] == "xiaopei": Fort._sites.erase(key)
	var city: Dictionary = store.city_state("xiaopei")
	var before := int(city["garrison"])
	for day in range(12): resolve_day(war)
	check(int(city["garrison"]) == before and city["faction"] == "liu_bei", "missing geometry allowed attacks on protected garrison")
	Fort._sites = cached_sites

	# One interior combatant gets garrison kills; exterior units get none.
	prepare(store)
	war = store.war
	board = war.state["battlefield"]
	mover = war.active_armies("yuan_shao")[0]
	breach = open_gate(war, mover)
	mover["tactical"]["cell"] = breach
	var outsiders: Array = war.active_armies("yuan_shao").filter(func(unit): return unit["id"] != mover["id"])
	var kills_before := {}
	for unit in outsiders: kills_before[unit["id"]] = int(unit.get("enemy_killed", 0))
	var interior_kills := int(mover.get("enemy_killed", 0))
	city = store.city_state("xiaopei")
	before = int(city["garrison"])
	resolve_day(war)
	check(int(city["garrison"]) < before and int(mover.get("enemy_killed", 0)) > interior_kills, "interior combat failed to award actual garrison kills")
	for unit in outsiders: check(int(unit.get("enemy_killed", 0)) == kills_before[unit["id"]], "exterior unit received interior garrison kill credit")

	# An active guard standing inside is a street opponent, not external relief.
	var guard := make_sortie(war, board)
	var pocket := -1
	for value in Fort.for_city(store, "xiaopei")["cells"]:
		if int(value) != breach and T.cell_distance(breach, int(value)) == 1 and T.can_enter(war, guard, int(value)): pocket = int(value); break
	check(pocket >= 0, "no adjacent legal interior guard fixture")
	if pocket >= 0:
		guard["tactical"]["cell"] = pocket
		before = int(city["garrison"])
		resolve_day(war)
		check(siege_of(war, "xiaopei")["phase"] != "援军阻断" and int(city["garrison"]) < before, "interior active guard blocked garrison combat as external relief")
	print("CITY_DEFENSE_EDGE_OK" if failures.is_empty() else "CITY_DEFENSE_EDGE_FAILED: " + str(failures))
	quit(0 if failures.is_empty() else 1)
