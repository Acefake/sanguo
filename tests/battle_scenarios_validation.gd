extends SceneTree

const Scenarios = preload("res://scripts/war/battle_scenarios.gd")
const Corps = preload("res://scripts/war/army_corps.gd")
const Policy = preload("res://scripts/agents/baseline_policy.gd")
const Tactical = preload("res://scripts/war/tactical_battlefield.gd")
const Adapter = preload("res://scripts/agents/agent_adapter.gd")
var failures: Array = []
var checks := 0

func _initialize() -> void: call_deferred("run")
func check(ok: bool, text: String) -> void:
	checks += 1
	if not ok and not failures.has(text): failures.append(text); push_error(text)

func run() -> void:
	var store: Node = root.get_node("GameState")
	store.persist_enabled = false
	var original: Dictionary = store.scenario.duplicate(true)
	store.prepare_battle_test(true)
	var war = store.war
	var corps: Dictionary = war.state["corps"].values()[0]
	var context := Corps.commander_context(war, corps)
	check(not context["candidates"].any(func(c): return c["action"].get("task", "") == "rear_guard"), "Healthy corps offers pointless rear guard")
	check(not context["candidates"].any(func(c): return c["action"]["type"] == "withdraw_corps"), "Balanced corps offers full retreat")
	var terms := Policy.commander_terms(context, "assign_task", "rear_guard")
	check(not terms.has("returning"), "Rear guard gets phantom retreat bonus")
	var candidate := {"action": {"type": "detach", "task": "raid_rear"}}
	var reserve_context := context.duplicate(true)
	for u in reserve_context["corps"]["units"]:
		if u["task"]["type"] == "reserve": u["task"]["type"] = "flank"
		if u["task"]["type"] == "main_attack": u["fatigue"] = 90
	var explicit := Policy.commander_explicit(reserve_context, candidate, "detach", "raid_rear", Policy.weights()["commander"], Policy.effective_personality(context))
	check(not explicit.has("补预备"), "Raid detachment wrongly receives reserve bonus")
	Corps.record_background_order(war, corps, {"type": "withdraw_corps"}, {"source": "model", "reason_summary": "旧观察误判全军撤退"}, 0)
	check(not corps.get("withdrawing", false) and not corps["orders"][-1]["applied"]["ok"], "Stale model retreat still executes")
	var fronts: Array = corps["units"].filter(func(id): return war.state["armies"][id]["corps_task"]["type"] == "main_attack")
	# Mixed troop presets can start with one front. This fixture needs two
	# to verify that covering a rout never empties the remaining frontline.
	if fronts.size() == 1:
		var second: String = corps["units"].filter(func(id): return id != corps["root_id"] and not fronts.has(id))[0]
		war.state["armies"][second]["corps_task"]["type"] = "main_attack"
		fronts.append(second)
	war.state["armies"][fronts[0]]["returning"] = true
	context = Corps.commander_context(war, corps)
	check(context["candidates"].any(func(c): return c["action"].get("task", "") == "rear_guard"), "Real rout cannot receive cover")
	check(not context["candidates"].any(func(c): return c["action"].get("unit", "") == fronts[1] and c["action"].get("task", "") == "rear_guard"), "Last frontline can be emptied for rear guard")
	var offline := Adapter.new()
	root.add_child(offline)
	var replay := ""
	for repeat_run in range(2):
		store.prepare_battle_test(false, "guandu_clash", 12345)
		for day in range(20): await store.war.step(offline)
		var projection: Array = []
		for army in store.war.state["armies"].values(): projection.append([army["id"], army["units"], army["morale"], army["organization"], army["tactical"]["cell"], army["returning"], army["corps_task"]])
		var fingerprint := JSON.stringify(projection)
		if repeat_run == 0: replay = fingerprint
		else: check(replay == fingerprint, "Same seed and offline policy cannot replay identically")
	var summaries: Array = []
	for spec in Scenarios.definitions():
		for seed_value in [1910901, 42]:
			store.prepare_battle_test(false, spec["id"], seed_value)
			war = store.war
			check(war.state["battlefield"]["scenario_id"] == spec["id"], "Wrong scenario metadata")
			if spec.has("terrain"): check(Tactical.terrain_class(spec["anchor"]) == spec["terrain"], spec["id"] + " is not on real matching terrain")
			if spec["id"] in ["siege_assault", "xiapi_siege"]: check(war.Feedback.visible_advantage(war)["theirs"] > 0, "Siege advantage omits the city garrison")
			var row := {"scenario": spec["id"], "seed": seed_value, "first_retreat": -1, "winner": "交战中", "days": 0, "contact_days": 0, "siege_days": 0, "rotations": 0}
			var before_snapshot: Dictionary = store.battle_snapshot["scenario"].duplicate(true)
			# Wet ground reduces damage and movement; validate a longer physical
			# engagement rather than ending the simulation at the plain-field budget.
			# 城防分离后必须真实破墙、入城才能占领，攻城场景需要比野战更长的预算。
			var budget := 160 if spec["id"] in ["marsh_battle", "wancheng_marsh", "xiapi_siege"] else 140 if spec["id"] in ["siege_assault", "city_relief", "xiangyang_relief"] else 100
			for day in range(budget):
				await war.step(offline)
				row["days"] = day + 1
				var occupied := {}
				var contact := false
				for unit in war.active_armies():
					var cell: int = unit["tactical"]["cell"]
					check(Tactical.grid().walkable(cell) and not occupied.has(cell), spec["id"] + " has overlapping or blocked units")
					occupied[cell] = true
					if unit["returning"] and row["first_retreat"] < 0: row["first_retreat"] = day + 1
					if int(unit.get("combat_tick", -1)) == int(war.state["tick"]): contact = true
					if unit["returning"]: check(unit.has("retreat_reason") or unit.get("outcome", "") != "", spec["id"] + " retreat lacks explanation")
				if contact: row["contact_days"] += 1
				if not war.state["sieges"].is_empty(): row["siege_days"] += 1
				for side in war.Feedback.snapshot(war): check(side["initial"] == side["accounted"], spec["id"] + " troop accounting diverged")
				check(store.battle_snapshot["scenario"] == before_snapshot, "Scenario corrupted original campaign snapshot")
				if war.state["battlefield"].has("winner"):
					row["winner"] = war.state["battlefield"]["winner"]
					break
			for current_corps in war.state["corps"].values():
				for order in current_corps["orders"]:
					if order["action"]["type"] == "rotate_front": row["rotations"] += 1
			check(row["contact_days"] > 0, spec["id"] + " never enters combat")
			if row["winner"] == "交战中":
				for army in war.active_armies(): print("UNFINISHED_UNIT ", JSON.stringify({"name": army["name"], "strength": war.Combat.strength(army), "task": army["corps_task"], "morale": army["morale"], "org": army["organization"], "returning": army["returning"], "phase": army["tactical"].get("phase", ""), "cell": army["tactical"]["cell"]}))
			check(row["winner"] != "交战中",spec["id"] + " never reaches a battle outcome")
			if spec["id"] in ["siege_assault", "xiapi_siege"]:
				check(row["siege_days"] > 0, "Siege scenario never invokes real siege rules")
				check(not war.state["battlefield"].has("winner") or war.state["sieges"]["xiaopei"]["phase"] == "occupied", "Siege declares victory before taking city")
			summaries.append(row)
			print("SCENARIO_RESULT ", JSON.stringify(row))
	store.restore_battle_test()
	check(store.scenario == original and not store.battle_test and not store.persist_enabled, "Original campaign not restored after switching scenarios")
	var output := FileAccess.open("res://docs/validation/battle-scenarios-results.json", FileAccess.WRITE)
	output.store_string(JSON.stringify({"checks":checks,"failures":failures,"runs":summaries}, "\t"))
	print("BATTLE_SCENARIOS_VALIDATION checks=", checks, " failures=", failures.size())
	offline.queue_free()
	quit(0 if failures.is_empty() else 1)
