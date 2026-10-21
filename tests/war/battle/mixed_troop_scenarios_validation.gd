extends SceneTree
const Scenarios = preload("res://scripts/war/battle/battle_scenarios.gd")
const Roles = preload("res://scripts/war/battle/troop_roles.gd")
const Policy = preload("res://scripts/agents/baseline_policy.gd")
const Corps = preload("res://scripts/war/campaign/army_corps.gd")
var failures: Array = []
var checks := 0
func _initialize() -> void: call_deferred("run")
func check(ok: bool, text: String) -> void:
	checks += 1
	if not ok and not failures.has(text): failures.append(text); push_error(text)
func run() -> void:
	var store = root.get_node("GameState")
	store.persist_enabled = false
	store.agent.enabled = false
	var offline = preload("res://scripts/agents/agent_adapter.gd").new()
	root.add_child(offline)
	var runs: Array = []
	for spec in Scenarios.definitions():
		store.prepare_battle_test(true,spec.id,42)
		var war = store.war
		war.rules["duel"]["enabled"] = false
		for faction in ["liu_bei","yuan_shao"]:
			if spec.kind == "siege" and faction == "liu_bei": continue
			var kinds := {}
			var total := 0
			for army in war.active_armies(faction):
				kinds[Roles.kind(army)] = true
				total += war.Combat.strength(army)
			check(kinds.size() == 3, spec.id+": missing initial arm")
			check(total == int(spec.get("strengths",{}).get(faction,20000)),spec.id+": wrong initial strength")
		if spec.kind == "siege": check(store.city_state("xiaopei").garrison == 9000,spec.id+": guard accounting")
		var corps: Dictionary = war.state.corps.values()[0]
		var context: Dictionary = Corps.commander_context(war,corps)
		for unit in context.corps.units:
			check(unit.has("units"), "commander does not know own unit composition")
			if Roles.kind(unit) == "archers":
				var support := Policy.commander_explicit(context,{"action":{"type":"assign_task","unit":unit.id,"task":"support"}},"assign_task","support",Policy.weights().commander,Policy.effective_personality(context))
				var front := Policy.commander_explicit(context,{"action":{"type":"assign_task","unit":unit.id,"task":"main_attack"}},"assign_task","main_attack",Policy.weights().commander,Policy.effective_personality(context))
				check(support.get("兵种职责适配",0) > front.get("兵种职责适配",0),"archer command fit")
		var row := {"id":spec.id,"contact":0,"ranged":0,"engine_bonus":1.0,"days":0}
		for day in range(65):
			await war.step(offline)
			row.days = day+1
			var occupied := {}
			for army in war.active_armies():
				var cell: int = army.tactical.cell
				check(war.Tactical.can_enter(war,army,cell) and not occupied.has(cell),spec.id+": blocked or overlapping deployment")
				occupied[cell] = true
				if army.get("combat_tick",-1) == war.state.tick:
					row.contact += 1
					if army.tactical.get("phase","") == "远射": row.ranged += 1
			for side in war.Feedback.snapshot(war): check(side.initial == side.accounted,spec.id+": troop accounting")
			for siege in war.state.sieges.values(): row.engine_bonus = maxf(row.engine_bonus,float(siege.get("engine_bonus",1)))
			if war.state.battlefield.has("winner"): break
		check(row.contact > 0,spec.id+": no real combat")
		row["winner"] = war.state.battlefield.get("winner","交战中")
		if spec.kind == "siege" and war.state.battlefield.has("winner"):
			check(war.state.battlefield.winner == store.city_state("xiaopei").faction,spec.id+": siege result ignores city holder")
		if spec.engines > 0 and spec.kind == "siege": check(row.engine_bonus > 1,spec.id+": engines never improve actual breach")
		runs.append(row)
		print("MIXED_SCENARIO_RESULT ",JSON.stringify(row))
	check(Roles.breach_multiplier([{"units":{"infantry":1000},"siege_engines":4}]) == 1.3,"engine crew cap")
	check(Roles.breach_multiplier([{"units":{"infantry":1000},"siege_engines":4,"returning":true}]) == 1,"routing engines remain effective")
	var replay := ""
	for i in range(2):
		store.prepare_battle_test(true,"guandu_clash",7654)
		store.war.rules["duel"]["enabled"] = false
		for day in range(20): await store.war.step(offline)
		var clean_state: Dictionary = store.war.state.duplicate(true)
		clean_state.erase("battle_ai_metrics")
		var result := JSON.stringify(clean_state)
		if i == 0: replay = result
		else: check(replay == result,"mixed arms same-seed replay")
	var file := FileAccess.open("res://docs/validation/mixed-troop-scenarios-2026-10-06.json",FileAccess.WRITE)
	file.store_string(JSON.stringify({"checks":checks,"failures":failures,"runs":runs},"\t"))
	print("MIXED_TROOP_SCENARIOS checks=",checks," failures=",failures.size())
	quit(0 if failures.is_empty() else 1)
