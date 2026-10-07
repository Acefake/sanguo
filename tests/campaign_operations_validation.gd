extends SceneTree

const Store = preload("res://scripts/game_state.gd")
var Ops = load("res://scripts/war/campaign_operations.gd")
var Fields = load("res://scripts/war/campaign_battlefields.gd")
var Fort = load("res://scripts/war/city_fortifications.gd")
var failures: Array[String] = []

func _initialize() -> void: call_deferred("run")
func check(value: bool, message: String) -> void:
	if not value: failures.append(message); push_error(message)
func fixture(started: bool = true) -> Node:
	var store := Store.new()
	store.persist_enabled = false
	store._load_demo()
	store.war.rules["strategy"] = {}
	if started: store.war.start_campaign()
	return store
func force(home: String, target: String, faction: String, store, count: int = 4000) -> Dictionary:
	var city: Dictionary = store.city_state(home)
	city["faction"] = faction
	city["garrison"] = 40000
	city["units"] = {"infantry": 28000, "archers": 10000, "cavalry": 2000}
	var id: String = store.war.available_officers(faction)[0]["id"]
	store.war.state["officer_states"][id] = {"status": "available", "city": home}
	var preview: Dictionary = store.war.preview_dispatch(home, target, id, false, count)
	check(preview.get("ok", false), "legal adjacent dispatch: " + str(preview))
	if not preview.get("ok", false): return {}
	return store.war._mobilize(preview)
func clone(store) -> Node:
	var other := fixture(false)
	other.scenario = JSON.parse_string(JSON.stringify(store.scenario))
	other.war.setup(other, JSON.parse_string(JSON.stringify(store.war.export_state())))
	other.war.rules["strategy"] = {}
	return other

func run() -> void:
	root.get_node("GameState").persist_enabled = false
	var store := fixture()
	var war = store.war
	check(not war.set_player_faction("cao_cao"), "started campaign can switch faction")
	var chief: String = war.available_officers("liu_bei")[0]["id"]
	check(not war.preview_dispatch("xiaopei", "luoyang", chief).get("ok", false), "remote attack passed through enemy cities")
	store.city_state("peiguo")["faction"] = "cao_cao"
	war.state["relations"]["cao_cao|liu_bei"] = "peace"
	check(not war.preview_dispatch("xiaopei", "peiguo", chief).get("ok", false), "peace attack allowed")
	check(not war.can_cross("liu_bei", "peiguo"), "peace allowed military passage")
	war.state["relations"]["cao_cao|liu_bei"] = "allied"
	check(war.can_cross("liu_bei", "peiguo"), "ally passage denied")
	war.state["relations"]["cao_cao|liu_bei"] = "hostile"
	var money: int = store.city_state("xiaopei")["treasury"]
	check(Ops.scout(war, "xiaopei")["ok"], "paid player scout failed")
	check(store.action_points == 2 and store.city_state("xiaopei")["treasury"] == money - 50, "scout did not consume actual budget")
	check(not war.state["faction_intel"]["liu_bei"]["cities"].is_empty(), "scout produced no intelligence")
	check(not Ops.scout(war, "peiguo")["ok"], "player scouted from enemy city")
	store.city_state("peiguo")["faction"] = "liu_bei"
	war.state["officer_states"][chief] = {"status": "available", "city": "xiaopei"}
	var transfer: Dictionary = Ops.assign(war, chief, "peiguo", "governor")
	check(transfer["ok"] and transfer["days"] > 0, "remote appointment had no travel")
	check(not war.available_officers("liu_bei").any(func(o): return o["id"] == chief), "transferring officer dispatched twice")
	var restored := clone(store)
	check(restored.war.state["officer_states"][chief]["arrives_at"] == war.state["officer_states"][chief]["arrives_at"], "save lost transfer arrival")
	restored.free()
	war.state["tick"] = int(war.state["officer_states"][chief]["arrives_at"])
	Ops.residence(war)
	check(store.city_state("peiguo")["governor_id"] == chief and war.state["officer_states"][chief]["city"] == "peiguo", "appointment never arrived")
	check(Ops.configure(war, "peiguo", {"defense": "hold", "rebuild": "civil", "delegated": true})["ok"], "city policy rejected")
	check(not Ops.configure(war, "luoyang", {"defense": "hold"})["ok"], "enemy city policy writable")
	war.state["sieges"]["peiguo"] = {"phase": "破门", "active_tick": war.state["tick"], "wall": 0, "wall_max": 40, "breach_cell": 10}
	check(not store.apply_action("peiguo", "recruit")["ok"] and not store.apply_action("peiguo", "fortify")["ok"], "siege permits repairs or recruits")
	war.state["sieges"]["peiguo"]["phase"] = "解围"
	store.action_points = 3
	store.city_state("peiguo")["defense"] = 28
	check(store.apply_action("peiguo", "fortify")["ok"] and not war.state["sieges"]["peiguo"].has("breach_cell"), "peace repair did not close breach")
	store.city_state("xiaopei")["garrison"] = 20000
	store.city_state("xiaopei")["units"] = {"infantry": 14000, "archers": 5000, "cavalry": 1000}
	var dispatch: Dictionary = war.dispatch("xiaopei", "puyang", chief)
	check(dispatch["ok"], "remote chief gathering rejected")
	var gathering: Dictionary = war.state["armies"][dispatch["army_id"]]
	check(not war.ready(gathering) and store.city_state("peiguo")["governor_id"] != chief, "chief failed to leave office or gather")
	var location: Dictionary = gathering["location"].duplicate(true)
	war._move_all()
	check(gathering["location"] == location, "army moved before chief arrived")
	restored = clone(store)
	check(not restored.war.ready(restored.war.state["armies"][gathering["id"]]), "save resumed army before gathering")
	restored.free(); store.free()

	# A transfer cannot teleport home when the destination and every escape road are lost.
	store = fixture(); war = store.war
	chief = war.available_officers("liu_bei")[0]["id"]
	war.state["officer_states"][chief] = {"status": "transferring", "city": "xiaopei", "destination": "peiguo", "arrives_at": 0}
	for edge in war.graph.edges.values():
		if edge["from"] == "peiguo" or edge["to"] == "peiguo": war.graph.closed_routes.append(edge["id"])
	war.graph.invalidate_paths()
	Ops.residence(war)
	check(war.state["officer_states"][chief]["status"] == "captured", "trapped officer teleported through closed roads")
	store.free()

	# A real road crossing creates one board; an arrival joins it without resetting cells.
	store = fixture(false); war = store.war
	var first := force("peiguo", "xiaopei", "cao_cao", store)
	var second := force("xiaopei", "peiguo", "liu_bei", store)
	first["location"] = {"node": "peiguo", "from": "peiguo", "to": "xiaopei", "edge": "b089", "progress": 0.52}
	second["location"] = {"node": "xiaopei", "from": "xiaopei", "to": "peiguo", "edge": "b089", "progress": 0.52}
	var motions := {first["id"]: {"before": first["location"].duplicate(true)}, second["id"]: {"before": second["location"].duplicate(true)}}
	motions[first["id"]]["before"]["progress"] = 0.48
	motions[second["id"]]["before"]["progress"] = 0.48
	Fields.roads(war, motions)
	check(first.has("tactical") and second.has("tactical") and first["battlefield_id"] == second["battlefield_id"], "road crossing bypassed tactical battle")
	var board: Dictionary = war.Tactical.board_for(war, first)
	var previous_cell: int = first["tactical"]["cell"]
	var third := force("runan", "xiaopei", "yuan_shu", store)
	third["location"] = first["location"].duplicate(true)
	Fields.prepare(war)
	check(third.get("battlefield_id", "") == first["battlefield_id"] and first["tactical"]["cell"] == previous_cell, "third faction arrival reset existing battle")
	var nearby: Dictionary = Fields.make_board(war, "nearby", int(board["anchor"]) + 1, {})
	check(nearby["battle_id"] == board["battle_id"], "adjacent battle was not merged")
	for node in ["xiaopei", "peiguo", "changan"]:
		var path: PackedInt32Array = Fort.road_path(store, node, node)
		check(not path.is_empty(), "no city exterior resting cell")
		if not path.is_empty(): check(Fort.Grid.shared().walkable(path[0]) and not Fort.for_city(store, node)["cells"].has(path[0]), "army rest inside city footprint")
	store.free()

	# A strategic pass has a real footprint and siege, despite having no city economy.
	store = fixture(false); war = store.war
	store.city_state("west_pass").merge({"garrison": 300, "units": {"infantry": 240, "archers": 60, "cavalry": 0}, "defense": 8}, true)
	var pass_attacker := force("luoyang", "west_pass", "liu_bei", store)
	for index in range(90):
		await war.step()
		if store.city_state("west_pass")["faction"] == "liu_bei": break
	check(store.city_state("west_pass")["faction"] == "liu_bei" and war.state["sieges"].get("west_pass", {}).get("phase", "") == "occupied", "pass cannot be captured")
	check(not Fort.for_city(store, "west_pass").is_empty() and store.city_state("west_pass")["garrison"] > 0, "pass has no fortification or occupation guard")
	check(int(war.ledger(pass_attacker)["missing"]) == 0, "pass battle lost troop accounting")
	store.free()

	# All day controls run the same settlements and policy clock when no event interrupts.
	var daily := fixture(); var ten_day := fixture(); var monthly := fixture()
	for index in range(30): await daily.advance_day()
	for index in range(3): await ten_day.advance_turn()
	await monthly.advance_month()
	check(daily.war.state["tick"] == 30 and ten_day.war.state["tick"] == 30 and monthly.war.state["tick"] == 30, "clock controls skipped campaign days")
	check(daily.scenario["places"] == ten_day.scenario["places"] and daily.scenario["places"] == monthly.scenario["places"], "day/ten-day/month settlements differ")
	daily.free(); ten_day.free(); monthly.free()
	store = fixture(); war = store.war
	for city in store.scenario["places"].values():
		if city.get("faction", "") == "liu_bei": city["faction"] = "cao_cao"
	Ops.result(war)
	check(war.state["campaign_result"].get("status", "") == "defeat", "elimination did not end campaign")
	var tick: int = war.state["tick"]
	await store.advance_day()
	check(war.state["tick"] == tick and not war.preview_dispatch("peiguo", "xiaopei", chief)["ok"], "ended campaign still mutates")
	store.free()
	store = fixture(); war = store.war
	for city in store.scenario["places"].values():
		if city.has("garrison"): city["faction"] = "liu_bei"
	Ops.result(war)
	check(war.state["campaign_result"].get("status", "") == "victory", "unification did not end campaign")
	store.free()
	print("CAMPAIGN_OPERATIONS_OK" if failures.is_empty() else "CAMPAIGN_OPERATIONS_FAILED: " + str(failures))
	quit(0 if failures.is_empty() else 1)
