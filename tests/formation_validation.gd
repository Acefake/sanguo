extends SceneTree
const Migration = preload("res://scripts/war/campaign/legacy_formation_migration.gd")
var failures: Array[String] = []
func _initialize() -> void: call_deferred("run")
func check(ok: bool, message: String) -> void:
	if not ok: failures.append(message); push_error(message)
func run() -> void:
	var store = root.get_node("GameState")
	store.persist_enabled = false
	store.prepare_battle_test(true,"plains_clash",42)
	var war = store.war
	var own: Dictionary = war.active_armies()[0]
	var corps: Dictionary = war.state["corps"][own["corps_id"]]
	check(not war.rules.has("formations"),"Retired formation rules remain")
	for candidate in war.Corps.commander_context(war,corps)["candidates"]:
		check(candidate["action"]["type"] != "set_formation" and not candidate["action"].has("formation"),"AI still proposes a formation")
	check(not war.Corps.issue(war,corps,{"type":"set_formation","formation":"fish_scale"},"old command")["ok"],"Retired formation order accepted")
	var baseline: float = war.Combat.power(own,war.rules,"plains")
	own.merge({"formation":"arrowhead","formation_locked":true,"formation_skill":100},true)
	own["action"]["formation"] = "arrowhead"
	corps.merge({"formation":"arrowhead","formation_changed_at":war.state["tick"],"formation_progress":"整阵"},true)
	corps["orders"].append({"action":{"type":"set_formation","formation":"arrowhead"}})
	Migration.apply(war.state)
	check(not own.has("formation_locked") and not corps.has("formation"),"Old save retains a formation lock")
	check(not own["action"].has("formation"),"Old pending deployment retains a formation")
	check(war.Tactical.can_attack(war,own),"Old formation lock still prevents attack")
	check(is_equal_approx(war.Combat.power(own,war.rules,"plains"),baseline),"Retired formation still changes power")
	check(corps["orders"].all(func(order): return order.get("action",{}).get("type","") != "set_formation"),"Old formation commands retained")
	var exported: Dictionary = war.export_state()
	war.setup(store,exported)
	check(war.active_armies().all(func(army): return not army.has("formation") and not army.has("formation_locked")),"Reload reintroduced formations")
	print("FORMATION_REMOVAL ","PASS" if failures.is_empty() else failures)
	quit(0 if failures.is_empty() else 1)
