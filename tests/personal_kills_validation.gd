extends SceneTree
const Fate = preload("res://scripts/war/officer_fate.gd")
const Combat = preload("res://scripts/war/combat_system.gd")
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
	store.prepare_battle_test(true, "plains_clash")
	var war = store.war
	var a: Dictionary = war.active_armies("liu_bei")[1]
	var b: Dictionary = war.active_armies("yuan_shao")[1]
	var officer: String = a["officer_id"]
	var hit := Combat.losses_detail(a, b, war.rules, "plains")
	check(float(hit["personal_fraction"]) > 0, "Commander has no melee strike")
	var ranged := a.duplicate(true)
	ranged["ranged_attack"] = true
	check(Combat.losses_detail(ranged, b, war.rules, "plains")["personal_fraction"] == 0, "Ranged soldiers credited to commander")
	ranged["commander_unavailable"] = true
	check(Combat.personal_power(ranged, war.rules) == 0, "Unavailable commander fighting")
	Fate.credit(war, {a["id"]:10.0}, 7, {}, {a["id"]:4.0})
	check(a["enemy_killed"] == 7 and a["personal_soldier_kills"] == 3, "Personal and soldier kills not partitioned")
	check(war.state["officer_personal_kills"][officer] == 3, "Personal kills missing")
	war._report(a, "战绩", "分开核对杀敌", true)
	var snapshot: Dictionary = war.state["reports"][-1]["snapshot"].duplicate(true)
	check(snapshot["commander_killed"] == 3 and snapshot["troop_killed"] == 4, "Report has wrong kill columns")
	Fate.credit(war, {a["id"]:10.0}, 7, {}, {a["id"]:4.0})
	check(snapshot["commander_killed"] == 3 and snapshot["troop_killed"] == 4, "Delivered report changed with live stats")
	var before_soldiers: int = a["enemy_killed"]
	var before_personal: int = war.state["officer_personal_kills"][officer]
	war.rules["officer_fate"]["duel_death"] = 1.0
	war.rules["officer_fate"]["duel_capture"] = 0.0
	Duel.apply_result(war, a, b, {"result":"overwhelming", "winner":0})
	check(war.state["officer_personal_kills"][officer] == before_personal + 1, "Duel execution not credited personally")
	check(a["enemy_killed"] == before_soldiers, "Duel execution credited to soldiers")
	var reload = War.new()
	reload.setup(store, war.export_state().duplicate(true))
	check(reload.state["officer_personal_kills"] == war.state["officer_personal_kills"], "Personal kills lost on reload")
	store.restore_battle_test()
	var adapter = preload("res://scripts/agents/agent_adapter.gd").new()
	root.add_child(adapter)
	var results: Array = []
	for scenario in ["plains_clash", "siege_assault", "mountain_pass"]:
		store.prepare_battle_test(true, scenario)
		war = store.war
		for day in range(45): await war.step(adapter)
		var main_soldiers := 0
		var troops := 0
		var deaths := 0
		for army in war.state["armies"].values():
			var personal: int = int(army.get("personal_soldier_kills", 0))
			var total: int = int(army.get("enemy_killed", 0))
			check(personal >= 0 and total >= personal, "Personal kills exceed actual deaths")
			main_soldiers += personal; troops += total - personal; deaths += int(army["dead"])
		for guard in war.state["garrison_commanders"].values():
			main_soldiers += int(guard.get("personal_soldier_kills", 0))
			troops += int(guard.get("enemy_killed", 0)) - int(guard.get("personal_soldier_kills", 0))
		for city in store.scenario["places"].values(): deaths += int(city.get("war_dead", 0))
		check(main_soldiers + troops == deaths, "Kills double counted: " + scenario)
		check(main_soldiers > 0 and troops > main_soldiers, "No real personal kills: " + scenario)
		results.append({"scenario":scenario, "commander_soldier_kills":main_soldiers, "troop_kills":troops, "actual_soldier_deaths":deaths})
		store.restore_battle_test()
	var file := FileAccess.open("res://docs/validation/officer-fate/personal-kills.json", FileAccess.WRITE)
	file.store_string(JSON.stringify({"checks":checks, "failures":failures, "results":results}, "  "))
	print("PERSONAL_KILLS_VALIDATION checks=", checks, " failures=", failures)
	quit(0 if failures.is_empty() else 1)
