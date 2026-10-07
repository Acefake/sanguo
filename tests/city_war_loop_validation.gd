extends SceneTree

const Store = preload("res://scripts/game_state.gd")
const Fort = preload("res://scripts/war/city_fortifications.gd")
const Fields = preload("res://scripts/war/campaign_battlefields.gd")
const T = preload("res://scripts/war/tactical_battlefield.gd")
const Combat = preload("res://scripts/war/combat_system.gd")
var failures: Array[String] = []

func _initialize() -> void: call_deferred("run")
func check(value: bool, message: String) -> void:
	if not value: failures.append(message); push_error(message)

func fixture() -> Node:
	var store := Store.new()
	store.persist_enabled = false
	store._load_demo()
	return store

func army_at(store, home: String, target: String, faction: String, strength: int = 0) -> Dictionary:
	var city: Dictionary = store.city_state(home)
	city["faction"] = faction
	city["garrison"] = 60000
	city["units"] = {"infantry": 50000, "archers": 8000, "cavalry": 2000}
	var officers: Array = store.war.available_officers(faction)
	var preview: Dictionary = store.war.preview_dispatch(home, target, str(officers[0]["id"]), false, strength)
	check(preview.get("ok", false), "formal dispatch preview")
	var army: Dictionary = store.war._mobilize(preview)
	army["location"] = {"node": target, "edge": "", "progress": 0.0}
	return army

func ledger(store) -> int:
	var sum := 0
	for city in store.scenario["places"].values(): sum += int(city.get("garrison", 0)) + int(city.get("wounded", 0)) + int(city.get("war_dead", 0)) + int(city.get("prisoners", 0))
	for army in store.war.state["armies"].values():
		sum += int(army["dead"]) + int(army["captured"])
		if army["status"] != "ended": sum += Combat.strength(army) + int(army["wounded"])
	return sum

func run() -> void:
	root.get_node("GameState").persist_enabled = false
	var store := fixture()
	check(store.canonical_city_id("city_66") == "xiaopei" and store.city_state("city_66") == store.city_state("xiaopei"), "city alias canonical identity")
	check(not store.apply_action("luoyang", "recruit")["ok"], "enemy city command denied before dispatch")
	check(not store.apply_action("tianshui", "govern")["ok"], "neutral city command denied")
	check(not store.apply_action("missing_city", "tax")["ok"], "unknown city command denied")
	for faction in store.scenario["factions"]:
		check(not store.war.available_officers(faction).is_empty(), "missing roster for " + faction)
		check(store.war.set_player_faction(faction), "unselectable faction " + faction)
	store.war.set_player_faction("liu_bei")
	var own_points: int = store.action_points
	store.war.state["tick"] = 10
	store.war.Strategic.plan(store.war, store)
	check(store.action_points == own_points, "NPC spent player action points")
	check(store.faction_action_points("cao_cao") < 3, "NPC city administration did not execute")
	for army in store.war.active_armies(): check(army.has("corps_id"), "NPC mobilization bypassed corps")
	for node in store.scenario["places"]:
		if store.city_state(node).has("population"): check(not Fort.for_city(store, node).is_empty(), "city has no siege geometry " + node)
	store.free()
	var war_store := fixture()
	war_store.war.rules["strategy"] = {}
	for target in ["xiaopei", "changan"]:
		var city: Dictionary = war_store.city_state(target)
		city["garrison"] = 300
		city["units"] = {"infantry": 240, "archers": 60, "cavalry": 0}
		city["defense"] = 10
	war_store.city_state("xiaopei")["faction"] = "lu_bu"
	var first := army_at(war_store, "peiguo", "xiaopei", "liu_bei")
	var second := army_at(war_store, "jincheng", "changan", "ma_teng")
	var initial := ledger(war_store)
	Fields.prepare(war_store.war)
	check(war_store.war.state["battlefields"].size() == 2 and not war_store.war.state.has("battlefield"), "formal boards are not independent")
	check(first["battlefield_id"] != second["battlefield_id"] and T.distance(first, second) == 10000, "different battlefields share targets")
	var board := T.board_for(war_store.war, first)
	var site := Fort.for_city(war_store, "xiaopei")
	var blocked := Fort.blocked_for(war_store.war, board, "liu_bei")
	for cell in site["cells"]: check(blocked.has(int(cell)), "unbreached enemy footprint is passable")
	var cells: Array = []
	for q in range(int(board["min_column"]), int(board["max_column"]) + 1):
		for r in range(int(board["min_row"]), int(board["max_row"]) + 1):
			var cell := T.cell_at(q, r)
			if T.can_enter(war_store.war, first, cell) and T.cell_distance(cell, int(site["center"])) == 3: cells.append(cell)
	first["tactical"]["cell"] = cells[0]
	war_store.war.state["tick"] = 1
	Fort.fire(war_store.war)
	check(not war_store.war.state["city_volleys"].is_empty(), "city volley did not fire before assault")
	check(int(first["dead"]) + int(first["wounded"]) > 0, "city volley caused no authoritative damage")
	var strength := Combat.strength(first)
	Fort.fire(war_store.war)
	check(Combat.strength(first) == strength, "city volley applied twice in one tick")
	check(ledger(war_store) == initial, "volley broke troop ledger")
	for index in range(80):
		await war_store.war.step()
		check(ledger(war_store) == initial, "campaign ledger changed on day " + str(index))
		for army in war_store.war.active_armies():
			if army.has("tactical"): check(T.can_enter(war_store.war, army, int(army["tactical"]["cell"])), "army entered closed wall")
		if war_store.city_state("xiaopei")["faction"] == "liu_bei" and war_store.city_state("changan")["faction"] == "ma_teng": break
	check(war_store.city_state("xiaopei")["faction"] == "liu_bei", "first formal siege never captured city")
	check(war_store.city_state("changan")["faction"] == "ma_teng", "second faction never captured city")
	if not failures.is_empty():
		for unit in [first, second]: print("LOOP_DEBUG ", unit["id"], " ", JSON.stringify({"action": unit["action"], "tactical": unit.get("tactical", {}), "reason": unit["last_reason"], "morale": unit["morale"], "strength": Combat.strength(unit), "returning": unit["returning"], "status": unit["status"], "siege": war_store.war.state["sieges"].get(unit["target"], {})}))
	check(int(war_store.city_state("xiaopei")["garrison"]) > 0, "occupation left no garrison")
	var saved: Dictionary = JSON.parse_string(JSON.stringify(war_store.war.export_state()))
	var restored := fixture()
	restored.scenario = war_store.scenario.duplicate(true)
	restored.war.setup(restored, saved)
	check(restored.war.state["version"] == 3 and restored.war.state["battlefields"].size() == 2, "new save lost battlefield records")
	check(restored.war.state["generated_officers"] == saved["generated_officers"], "save lost generated officer identities")
	war_store.free()
	restored.free()
	var wound := {"units": {"infantry": 0, "archers": 1000, "cavalry": 0}, "wounded": 0}
	Combat.apply_loss(wound, 100)
	check(int(wound["wounded_units"]["archers"]) == int(wound["wounded"]) and int(wound["wounded_units"]["infantry"]) == 0, "archer wounds migrated into infantry")
	print("CITY_WAR_LOOP_OK" if failures.is_empty() else "CITY_WAR_LOOP_FAILED: " + str(failures))
	quit(0 if failures.is_empty() else 1)
