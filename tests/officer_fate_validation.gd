extends SceneTree
const Fate = preload("res://scripts/war/officer_fate.gd")
const Duel = preload("res://scripts/war/duel_system.gd")
const War = preload("res://scripts/war/campaign_state.gd")
var failures: Array = []
var checks := 0
func _initialize(): call_deferred("run")
func check(ok: bool, message: String):
	checks += 1
	if not ok: failures.append(message); push_error(message)
func run():
	var store = root.get_node("GameState")
	store.persist_enabled = false
	var adapter = preload("res://scripts/agents/agent_adapter.gd").new()
	root.add_child(adapter)
	for status in ["dead", "captured"]:
		store.prepare_battle_test(true, "plains_clash")
		var war = store.war
		var a: Dictionary = war.active_armies("liu_bei")[1]
		var b: Dictionary = war.active_armies("yuan_shao")[1]
		var loser_id: String = b["officer_id"]
		var manpower: int = war.Combat.strength(b)
		war.rules["officer_fate"]["duel_death"] = 1.0 if status == "dead" else 0.0
		war.rules["officer_fate"]["duel_capture"] = 0.0 if status == "dead" else 1.0
		var outcome := {"result":"overwhelming", "winner":0}
		Duel.apply_result(war, a, b, outcome)
		check(outcome["fate"]["status"] == status, "Forced duel fate not applied")
		check(war.Combat.strength(b) + int(b.get("dispersed", 0)) == manpower, "Officer loss did not account for surviving soldiers")
		check(war.state["officer_states"][loser_id]["status"] == status, "Officer status missing")
		if b["officer_id"] != loser_id:
			check(not Fate.unavailable(war, b["officer_id"]) and not b.get("commander_unavailable", false), "Invalid successor")
		else: check(b["status"] == "ended" and b.get("commander_unavailable", false) and b.get("dispersed", 0) == manpower, "Leaderless unit did not disperse")
		check(not war.available_officers("yuan_shao").any(func(officer): return officer["id"] == loser_id), "Terminal officer available")
		var fate_before: Dictionary = war.state["officer_fates"][loser_id].duplicate(true)
		Fate.settle(war, b, a, status, "重复结算") if b["officer_id"] == loser_id else null
		check(war.state["officer_fates"][loser_id] == fate_before, "Fate settled twice")
		b["location"] = {"node":b["home"], "edge":"", "progress":0.0}
		war._finish(b, "撤退")
		war.state["tick"] += 100
		war._deliver_reports()
		check(war.state["officer_states"][loser_id]["status"] == status, "Return/healing resurrected officer")
		var restored = War.new()
		restored.setup(store, war.export_state().duplicate(true))
		check(restored.state["officer_fates"][loser_id] == war.state["officer_fates"][loser_id], "Fate lost on reload")
		if status == "captured":
			check(not Fate.release(restored, a["officer_id"]), "Non-prisoner released")
			check(Fate.release(restored, loser_id), "Owned prisoner cannot release")
			check(restored.state["officer_states"][loser_id]["status"] == "recovering", "Released prisoner skipped recovery")
			Fate.restore(restored)
			check(restored.state["officer_states"][loser_id]["status"] == "recovering", "Restore recaptured released officer")
		store.restore_battle_test()
	# Integer credit and overkill cap, independent of attack iteration order.
	store.prepare_battle_test(true, "plains_clash")
	var war = store.war
	var own: Array = war.active_armies("liu_bei")
	var weights := {own[0]["id"]:1, own[1]["id"]:2, own[2]["id"]:3}
	Fate.credit(war, weights, 7)
	var total := 0
	for unit in own: total += int(unit.get("enemy_killed", 0))
	check(total == 7, "Kill allocation not conserved")
	var saved: Dictionary = war.export_state().duplicate(true)
	var migrated = War.new()
	saved.erase("officer_fates"); saved.erase("officer_kills")
	migrated.setup(store, saved)
	check(migrated.state["officer_fates"].is_empty() and migrated.state["officer_kills"].is_empty(), "Old save migration fails")
	store.restore_battle_test()
	# Destruction and rout settle through the authoritative campaign path.
	for cause in ["destroyed", "rout"]:
		store.prepare_battle_test(true, "plains_clash")
		war = store.war
		var loser: Dictionary = war.active_armies("yuan_shao")[1]
		var attacker: Dictionary = war.active_armies("liu_bei")[1]
		var officer_id: String = loser["officer_id"]
		loser["tactical"]["cell"] = war.Tactical.offset_cell(war.state["battlefield"], 0, 0)
		attacker["tactical"]["cell"] = war.Tactical.neighbors(loser["tactical"]["cell"])[0]
		war.rules["officer_fate"][cause + "_death"] = 0.0
		war.rules["officer_fate"][cause + "_capture"] = 1.0
		if cause == "destroyed": war.Combat.apply_loss(loser, war.Combat.strength(loser))
		else: loser["morale"] = 0; loser["organization"] = 0
		war._check_rout(loser)
		check(war.state["officer_fates"].get(officer_id, {}).get("status", "") == "captured", "Real " + cause + " did not capture officer")
		store.restore_battle_test()
	store.prepare_battle_test(true, "siege_assault")
	war = store.war
	var city_node: String = str(war.state["battlefield"]["objectives"].keys()[0])
	var guard: Dictionary = Fate.garrison(war, city_node, store.city_state(city_node))
	var besieger: Dictionary = war.active_armies("yuan_shao")[0]
	war.rules["officer_fate"]["city_death"] = 0.0
	war.rules["officer_fate"]["city_capture"] = 1.0
	Fate.city_falls(war, guard, besieger)
	check(war.state["officer_states"][guard["officer_id"]]["status"] == "captured", "City fall did not capture garrison commander")
	var guard_reload = War.new()
	guard_reload.setup(store, war.export_state().duplicate(true))
	check(guard_reload.roster.officers.has(guard["officer_id"]), "Garrison commander missing after reload")
	store.restore_battle_test()
	for scenario in ["plains_clash", "siege_assault", "mountain_pass"]:
		store.prepare_battle_test(true, scenario)
		war = store.war
		for day in range(45):
			await war.step(adapter)
			for unit in war.state["armies"].values():
				check(war.ledger(unit)["missing"] == 0, "Manpower not conserved after fate")
		var killed := 0
		var deaths := 0
		for unit in war.state["armies"].values():
			killed += int(unit.get("enemy_killed", 0)); deaths += int(unit["dead"])
		for guard_entry in war.state["garrison_commanders"].values(): killed += int(guard_entry.get("enemy_killed", 0))
		var garrison_deaths := 0
		for city in store.scenario["places"].values(): garrison_deaths += int(city.get("war_dead", 0))
		check(killed == deaths + garrison_deaths, "Real combat kill totals differ from actual enemy deaths: " + scenario + " " + str([killed, deaths, garrison_deaths]))
		store.restore_battle_test()
	print("OFFICER_FATE_OK checks=", checks, " failures=", failures)
	quit(0 if failures.is_empty() else 1)
