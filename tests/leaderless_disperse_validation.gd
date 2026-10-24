extends SceneTree
const Fate = preload("res://scripts/war/officer_fate.gd")
const War = preload("res://scripts/war/campaign_state.gd")
var failures: Array = []
func _initialize(): call_deferred("run")
func check(ok: bool, message: String):
	if not ok: failures.append(message); push_error(message)
func run():
	var store = root.get_node("GameState")
	store.persist_enabled = false
	for preformed in [true, false]:
		store.prepare_battle_test(preformed, "plains_clash")
		var war = store.war
		var enemy: Dictionary = war.active_armies("liu_bei")[0]
		var side: Array = war.active_armies("yuan_shao")
		var corps: Dictionary = war.state["corps"][side[0]["corps_id"]]
		var ids: Array = corps["members"].duplicate()
		var initial := 0
		for unit in side: initial += war.Combat.strength(unit)
		var guard_before: int = store.city_state(side[0]["home"])["garrison"]
		# Kill every deployed commander, including successive staff appointments.
		var safety := 0
		while not war.active_armies("yuan_shao").is_empty() and safety < 10:
			safety += 1
			var unit: Dictionary = war.active_armies("yuan_shao")[0]
			var before: int = war.Combat.strength(unit)
			Fate.settle(war, unit, enemy, "dead", "测试战死")
			if unit["status"] != "ended":
				check(war.Combat.strength(unit) == before, "Successor lost troops")
				check(not Fate.unavailable(war, unit["officer_id"]), "Dead successor appointed")
		check(war.active_armies("yuan_shao").is_empty(), "All officers dead but troops still active")
		var dispersed := 0
		for unit in side:
			dispersed += int(unit.get("dispersed", 0))
			check(war.ledger(unit)["missing"] == 0, "Dispersal ledger does not balance")
			check(unit["dead"] == 0 and unit["captured"] == 0 and unit["deposited"] == 0, "Dispersal counted as deaths, capture or return")
			var saved_count: int = unit.get("dispersed", 0)
			war._check_rout(unit)
			Fate.disperse(war, unit)
			check(unit.get("dispersed", 0) == saved_count, "Dispersal counted twice")
		check(dispersed == initial, "Not all surviving soldiers dispersed")
		check(store.city_state(side[0]["home"])["garrison"] == guard_before, "Dispersed soldiers returned to garrison")
		for id in ids: check(Fate.unavailable(war, id), "An original corps officer survived test unexpectedly")
		for row in war.Feedback.snapshot(war): check(row["initial"] == row["accounted"], "Battle summary missing dispersed troops")
		var restored = War.new()
		restored.setup(store, war.export_state().duplicate(true))
		check(restored.active_armies("yuan_shao").is_empty(), "Save reload resurrected dispersed army")
		store.restore_battle_test()
	# An old save must not preserve an army whose dead commander was retreating.
	store.prepare_battle_test(false, "plains_clash")
	var war = store.war
	var unit: Dictionary = war.active_armies("yuan_shao")[0]
	var corps: Dictionary = war.state["corps"][unit["corps_id"]]
	var count: int = war.Combat.strength(unit)
	unit["units"]["infantry"] -= 7
	unit["wounded"] = 7
	unit["wounded_units"] = {"infantry": 7, "archers": 0, "cavalry": 0}
	for id in corps["members"]:
		war.state["officer_fates"][id] = {"officer_id": id, "status": "dead", "faction": "yuan_shao"}
	unit["commander_unavailable"] = true
	unit["returning"] = true
	var restored = War.new()
	restored.setup(store, war.export_state().duplicate(true))
	var loaded: Dictionary = restored.state["armies"][unit["id"]]
	check(loaded["status"] == "ended" and loaded.get("dispersed", 0) == count, "Old leaderless save or wounded troops not dispersed")
	check(restored.ledger(loaded)["missing"] == 0, "Old save dispersal accounting failed")
	store.restore_battle_test()
	print("LEADERLESS_DISPERSE_OK failures=", failures)
	quit(0 if failures.is_empty() else 1)
