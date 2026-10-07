extends SceneTree

const Fort = preload("res://scripts/war/city_fortifications.gd")
const Combat = preload("res://scripts/war/combat_system.gd")
var failures: Array[String] = []

func _initialize() -> void: call_deferred("run")
func check(ok: bool, message: String) -> void:
	if not ok: failures.append(message); push_error(message)

func total_troops(war) -> int:
	var total := 0
	for city in war.store.scenario["places"].values():
		total += int(city.get("garrison", 0)) + int(city.get("wounded", 0)) + int(city.get("war_dead", 0)) + int(city.get("prisoners", 0))
	for army in war.state["armies"].values():
		total += int(army.get("dead", 0)) + int(army.get("captured", 0))
		if army["status"] != "ended": total += Combat.strength(army) + int(army.get("wounded", 0))
	return total

func run() -> void:
	var store = root.get_node("GameState")
	store.persist_enabled = false
	store.agent.enabled = false
	store.prepare_battle_test(false, "siege_assault", 42)
	var war = store.war
	var board: Dictionary = war.state["battlefield"]
	var center := int(board["objectives"]["xiaopei"])
	var city: Dictionary = store.city_state("xiaopei")
	city.merge({"garrison": 9000, "units": {"infantry": 5400, "archers": 3600, "cavalry": 0}}, true)
	var attackers: Array = war.active_armies("yuan_shao")
	# Declare extra attack directions from mobilized army state when the fixture
	# has fewer than three forces; all damage still goes through real settlement.
	while attackers.size() < 3:
		var detachment: Dictionary = attackers[0].duplicate(true)
		detachment["id"] = "volley-fixture:" + str(attackers.size())
		detachment.erase("corps_id")
		detachment.erase("corps_task")
		war.state["armies"][detachment["id"]] = detachment
		attackers.append(detachment)
	for other in attackers.slice(3): other["status"] = "ended"
	attackers = attackers.slice(0, 3)
	# The siege fixture returned the defenders to town; place one friendly patrol
	# back on the board to exercise friendly-fire exclusion alongside real attackers.
	var friend: Dictionary = war.state["armies"].values().filter(func(army): return army["faction"] == "liu_bei")[0]
	friend["status"] = attackers[0]["status"]
	friend["units"] = {"infantry": 1000, "archers": 0, "cavalry": 0}
	friend["tactical"] = attackers[0]["tactical"].duplicate(true)
	var candidates: Array = []
	for q in range(int(board["min_column"]), int(board["max_column"]) + 1):
		for r in range(int(board["min_row"]), int(board["max_row"]) + 1):
			var cell: int = war.Tactical.cell_at(q, r)
			# Range is measured from the actual wall footprint, not the city center.
			if Fort.distance_to_wall(board,"xiaopei",cell) == 2 and war.Tactical.can_enter(war, attackers[0], cell) and Fort.line_of_sight(board, center, cell, "xiaopei"): candidates.append(cell)
	check(candidates.size() >= 3, "fixture has too few legal firing directions")
	var selected: Array = [candidates[0]]
	while selected.size() < 3:
		var best := -1
		var separation := -1
		for cell in candidates:
			if selected.has(cell): continue
			var gap := 10000
			for other in selected: gap = mini(gap, war.Tactical.cell_distance(cell, other))
			if gap > separation: separation = gap; best = cell
		selected.append(best)
	for index in range(attackers.size()): attackers[index]["tactical"]["cell"] = selected[index]
	friend["tactical"]["cell"] = candidates[1]
	var initial := total_troops(war)
	var strengths := {}
	for army in attackers + [friend]: strengths[army["id"]] = Combat.strength(army)
	war.state["tick"] = 1
	Fort.fire(war)
	var volleys: Array = war.state["city_volleys"].filter(func(event): return event["city"] == "xiaopei")
	check(volleys.size() == 3, "one city did not strike all three attack directions")
	var ids := {}
	var shooters := 0
	for event in volleys:
		check(not ids.has(event["id"]), "multiple targets share one animation event")
		ids[event["id"]] = true
		shooters += int(event["shooters"])
		check(int(event["loss"]) > 0, "multi-target volley is visual only")
	check(shooters == 4680, "extra targets duplicated or lost garrison firepower")
	for army in attackers: check(Combat.strength(army) < int(strengths[army["id"]]), "unharmed attacker: " + army["id"])
	check(Combat.strength(friend) == int(strengths[friend["id"]]), "city fired on a friendly army")
	check(total_troops(war) == initial, "multi-target losses broke troop conservation")
	var settled := total_troops(war)
	var after := {}
	for army in attackers: after[army["id"]] = Combat.strength(army)
	for tick in [1, 2]:
		war.state["tick"] = tick
		Fort.fire(war)
		check(war.state["city_volleys"].is_empty(), "city ignored its firing cooldown")
		for army in attackers: check(Combat.strength(army) == int(after[army["id"]]), "cooldown applied additional casualties")
	# A nearer obstacle must suppress just the occluded line of fire.
	var blocked: Dictionary = attackers[0]
	var midpoint: int = war.Tactical.grid().pick(war.Tactical.grid().center(center).lerp(war.Tactical.grid().center(int(blocked["tactical"]["cell"])), 0.5))
	board["fortifications"]["fixture_occluder"] = {"id": "fixture_occluder", "cells": [midpoint]}
	war.state["tick"] = 3
	Fort.fire(war)
	check(not war.state["city_volleys"].any(func(event): return event["target"] == blocked["id"]), "city fired through an intervening building")
	check(Combat.strength(blocked) == int(after[blocked["id"]]), "occluded target took damage")
	board["fortifications"].erase("fixture_occluder")
	# Moving out of range and changing ownership both stop the corresponding fire.
	var outside: Array = []
	for q in range(int(board["min_column"]),int(board["max_column"])+1):
		for r in range(int(board["min_row"]),int(board["max_row"])+1):
			var cell: int = war.Tactical.cell_at(q,r)
			if Fort.distance_to_wall(board,"xiaopei",cell) == 3 and Fort.line_of_sight(board,center,cell,"xiaopei") and war.Tactical.can_enter(war,blocked,cell): outside.append(cell)
	check(not outside.is_empty(),"fixture has no unobstructed three-cell range boundary")
	blocked["tactical"]["cell"] = outside[0]
	war.state["tick"] = 5
	Fort.fire(war)
	check(not war.state["city_volleys"].any(func(event): return event["target"] == blocked["id"]), "city fired on an unobstructed army three cells from its wall")
	check(total_troops(war) == settled, "later volleys changed the troop ledger")
	friend["status"] = "ended"
	city["faction"] = "yuan_shao"
	war.state["tick"] = 7
	Fort.fire(war)
	check(war.state["city_volleys"].is_empty(), "captured city continued firing on its new owner's troops")
	print("CITY_VOLLEY_OK: three directions, conserved bow budget, real losses, friendly exclusion, cooldown, occlusion, range, ownership" if failures.is_empty() else "CITY_VOLLEY_FAILED: " + str(failures))
	quit(0 if failures.is_empty() else 1)
