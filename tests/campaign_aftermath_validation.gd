extends SceneTree

const Store = preload("res://scripts/game_state.gd")
var failures: Array[String] = []
var events: Array = []
func _initialize() -> void: call_deferred("run")
func check(value: bool, message: String) -> void:
	if not value: failures.append(message); push_error(message)
func ledger(store) -> int:
	var value := 0
	for city in store.scenario["places"].values(): value += int(city.get("garrison", 0)) + int(city.get("wounded", 0)) + int(city.get("war_dead", 0)) + int(city.get("prisoners", 0))
	for army in store.war.state["armies"].values():
		value += int(army["dead"]) + int(army["captured"])
		if army["status"] != "ended": value += store.war.Combat.strength(army) + int(army["wounded"])
	return value
func city(store, node: String, faction: String, count: int, defense: int = 10) -> void:
	store.city_state(node).merge({"faction": faction, "garrison": count, "units": {"infantry": int(count * 0.8), "archers": count - int(count * 0.8), "cavalry": 0}, "defense": defense, "treasury": 50000, "grain": 50000}, true)
func capture(store, target: String, faction: String, budget: int, conserved: int) -> void:
	for index in range(budget):
		await store.war.step()
		check(ledger(store) == conserved, "troop ledger changed during capture")
		if store.city_state(target)["faction"] == faction: return
	check(false, "failed to capture " + target + " as " + faction)
func run() -> void:
	root.get_node("GameState").persist_enabled = false
	var store := Store.new(); store.persist_enabled = false; store._load_demo()
	var war = store.war
	war.set_player_faction("dong_zhuo")
	city(store, "jincheng", "ma_teng", 50000)
	city(store, "changan", "dong_zhuo", 500, 8)
	city(store, "wudu", "dong_zhuo", 50000)
	city(store, "tianshui", "", 500, 8)
	war.Lifecycle.maintain(war)
	war.start_campaign()
	war.rules["strategy"] = {}
	war.Operations.scout_for_faction(war, "jincheng", "ma_teng")
	var section := {"front_limit": 2, "target_sample": 10, "threshold": -50, "max_ratio": 1.8, "min_grain_days": 0}
	var decisions: Array = war.Strategic._plan_faction(war, store, "ma_teng", section)
	check(decisions.any(func(d): return d["target"] == "changan"), "NPC strategy never attacked player city")
	var before := ledger(store)
	await capture(store, "changan", "ma_teng", 100, before)
	events.append({"phase": "NPC攻占玩家城", "tick": war.state["tick"], "siege": war.state["sieges"].get("changan", {}).duplicate(true)})
	check(store.city_state("changan")["garrison"] > 0 and not war.state["campaign_result"].has("status"), "occupation lost garrison or prematurely ended player")
	check(not store.apply_action("changan", "recruit")["ok"], "player retains control after losing city")
	check(war.state["officer_fates"].values().any(func(f): return f.get("city", "") == "changan"), "city defeat did not settle staff")
	# Let all winning units finish their real return path before another campaign.
	for index in range(30):
		await war.step()
		if war.active_armies("ma_teng").is_empty(): break
	check(war.active_armies("ma_teng").is_empty(), "victorious corps never returned/released officers")
	check(not store.city_state("changan").get("governor_id", "").is_empty(), "new city never received administration")
	war.state["city_policies"]["changan"] = {"defense": "hold", "rebuild": "military", "delegated": true}
	war.state["faction_action_points"]["ma_teng"] = 3
	var resources: Dictionary = store.city_state("changan").duplicate(true)
	war.Strategic._govern(war, store, "ma_teng")
	check(store.city_state("changan") != resources and store.faction_action_points("ma_teng") < 3, "NPC occupation did not rebuild using real resources")
	events.append({"phase": "战后重建", "tick": war.state["tick"], "action_points": store.faction_action_points("ma_teng")})
	# Newly conquered ground becomes a valid origin for the next NPC offensive.
	war.state["faction_action_points"]["ma_teng"] = 3
	war.Operations.scout_for_faction(war, "changan", "ma_teng")
	decisions = war.Strategic._plan_faction(war, store, "ma_teng", section)
	check(decisions.any(func(d): return d["target"] == "tianshui"), "NPC cannot continue war from a conquered city")
	before = ledger(store)
	await capture(store, "tianshui", "ma_teng", 100, before)
	events.append({"phase": "NPC再次出征", "tick": war.state["tick"], "owner": store.city_state("tianshui")["faction"]})
	# Recapture reopens a new siege episode; it must not inherit an occupied lock.
	var officer: String = war.available_officers("dong_zhuo")[0]["id"]
	war.state["officer_states"][officer] = {"status": "available", "city": "wudu"}
	var dispatched: Dictionary = war.dispatch("wudu", "changan", officer)
	check(dispatched["ok"], "player cannot counterattack lost city")
	before = ledger(store)
	await capture(store, "changan", "dong_zhuo", 110, before)
	events.append({"phase": "玩家夺回城池", "tick": war.state["tick"], "siege": war.state["sieges"].get("changan", {}).duplicate(true)})
	check(war.state["battlefields"].keys().any(func(id): return str(id).begins_with("city:changan@")), "recapture overwrote earlier battlefield history")
	var saved: Dictionary = JSON.parse_string(JSON.stringify(war.export_state()))
	var restored := Store.new(); restored.persist_enabled = false; restored._load_demo(); restored.scenario = store.scenario.duplicate(true); restored.war.setup(restored, saved)
	for id in saved["officer_fates"]:
		var fate: Dictionary = saved["officer_fates"][id]
		if fate["status"] in ["captured", "dead"]: check(not restored.war.available_officers(fate["faction"]).any(func(o): return o["id"] == id), "load revived captured/dead officer")
	check(restored.war.state["battlefields"].size() == war.state["battlefields"].size(), "save lost repeated battle history")
	var file := FileAccess.open("res://docs/validation/campaign-aftermath-2026-10-06.json", FileAccess.WRITE)
	file.store_string(JSON.stringify({"events": events, "failures": failures}, "\t"))
	restored.free(); store.free()
	print("CAMPAIGN_AFTERMATH_OK" if failures.is_empty() else "CAMPAIGN_AFTERMATH_FAILED: " + str(failures))
	quit(0 if failures.is_empty() else 1)
