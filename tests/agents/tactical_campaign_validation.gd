extends SceneTree

const Scenarios = preload("res://scripts/war/battle/battle_scenarios.gd")
const Brain = preload("res://scripts/agents/unit_brain.gd")
const Eval = preload("res://scripts/agents/tactical_evaluator.gd")
const Forecast = preload("res://scripts/agents/forecast.gd")
const Candidates = preload("res://scripts/agents/tactical_candidates.gd")
var failures: Array[String] = []
var results: Array = []

func _initialize() -> void: call_deferred("run")
func check(ok: bool, message: String) -> void:
	if not ok and not failures.has(message): failures.append(message); push_error(message)

func run() -> void:
	var store: Node = root.get_node("GameState")
	store.persist_enabled = false
	store.agent.enabled = false
	var audit := {}
	for row in store.war.roster.parsing_audit:
		for axis in row["sources"]["personality"]:
			var source: String = row["sources"]["personality"][axis]
			audit[source] = int(audit.get(source,0))+1
	var seeds := [7,19,42,73,101,1910901]
	var max_rounds := 120
	var baseline: bool = OS.get_cmdline_user_args().has("--baseline")
	if baseline: seeds = [42]
	if OS.get_cmdline_user_args().has("--quick"): seeds = [42]; max_rounds = 25
	var scenarios := Scenarios.definitions() if not OS.get_cmdline_user_args().has("--personality-only") else []
	for spec in scenarios:
		for seed_value in seeds:
			store.prepare_battle_test(true,spec["id"],seed_value)
			var war = store.war
			if baseline: war.set_battle_ai_mode("legacy")
			var board: Dictionary = war.state["battlefield"]
			var switches := 0
			var blocked := 0
			var coord := 0
			var phases := {}
			var elapsed: Array = []
			var whole_round: Array = []
			var previous := {}
			var rounds := 0
			for day in range(max_rounds):
				var started := Time.get_ticks_usec()
				await war.step()
				whole_round.append((Time.get_ticks_usec()-started)/1000.0)
				rounds += 1
				elapsed.append(war.state.get("battle_ai_metrics",{}).get("decision_ms",0))
				var occupied := {}
				for army in war.active_armies():
					if not army.has("tactical"): continue
					var cell: int = army["tactical"]["cell"]
					check(not occupied.has(cell),spec["id"]+": 重复占格")
					occupied[cell] = true
					check(war.Tactical.can_enter(war,army,cell),spec["id"]+": 不可通行格")
					if army["returning"]: continue
					var ai: Dictionary = army.get("battle_ai",{})
					if not war.ready(army): continue
					if not baseline: check(int(ai.get("submitted_round",-1)) == int(war.state["battle_round"]),spec["id"]+": 活动分队漏提交")
					var plan: Dictionary = ai.get("plan",{})
					var signature := JSON.stringify([plan.get("template",""),plan.get("target_id","")])
					if previous.has(army["id"]) and previous[army["id"]] != signature: switches += 1
					previous[army["id"]] = signature
					phases[str(plan.get("template",""))] = true
					if army["tactical"].get("blocked",false): blocked += 1
					if ai.get("last_source","") == "coordination": coord += 1
				for side in war.Feedback.snapshot(war): check(side["initial"] == side["accounted"],spec["id"]+": 兵员账本失衡")
				if board.has("winner") or war.active_armies().is_empty(): break
			elapsed.sort()
			whole_round.sort()
			var record := {"scenario":spec["id"],"seed":seed_value,"rounds":rounds,"winner":board.get("winner",""),"unfinished":not board.has("winner"),"switches":switches,"blocked":blocked,"coordination":coord,"templates":phases.keys(),"decision_p95_ms":elapsed[int((elapsed.size()-1)*0.95)],"ledger":war.Feedback.snapshot(war)}
			results.append(record)
			record["whole_round_p95_ms"] = whole_round[int((whole_round.size()-1)*0.95)]
			print("TACTICAL_CASE ",JSON.stringify(record))
			await process_frame
	store.prepare_battle_test(true,"plains_clash",42)
	var war = store.war
	await war.step()
	var context := Brain.context(war,war.active_armies("liu_bei")[1])
	var differences := 0
	var personality_cases: Array = []
	# Twelve trade-offs change only risk tolerance; bodies, enemy estimates, seed,
	# command and skills remain identical within each pair.
	for i in range(12):
		var ctx: Dictionary = context.duplicate(true)
		ctx.erase("_ranking")
		ctx["current_plan"] = {}
		ctx["task"]["role"] = "main_attack"
		ctx["task"]["anchor_cell"] = -1
		ctx["self"]["organization"] = 75.0 - (i%4)*10
		ctx["self"]["fatigue"] = 40.0 + (i%3)*10
		ctx["self"]["units"] = {"infantry":6000,"archers":0,"cavalry":0}
		ctx["self"]["strength"] = 6000
		ctx["self"]["attack_range"] = 1
		ctx["self"]["kind"] = "infantry"
		ctx["self"]["mobility"] = 1.0
		ctx["knowledge"]["allies"] = []
		ctx["knowledge"]["enemies"] = ctx["knowledge"]["enemies"].slice(0,1)
		for enemy in ctx["knowledge"]["enemies"]:
			enemy["cell"] = war.Tactical.cell_at(war.Tactical.column_of(ctx["self"]["cell"]),war.Tactical.row_of(ctx["self"]["cell"])+2)
			enemy["observed_round"] = ctx["battle_round"]
			enemy["strength_estimate"] = 6000 + i*2000
			enemy["unit_mix_estimate"] = {"infantry":enemy["strength_estimate"],"archers":0,"cavalry":0}
			ctx["exchanges"][enemy["id"]] = Forecast.tactical_exchange(ctx["self"],enemy,war.rules,war.Tactical.terrain_class(ctx["self"]["cell"]))
		ctx["crisis"] = false
		ctx["candidates"] = Candidates.generate(ctx)
		for axis in war.roster.AXES: ctx["officer"]["personality"][axis] = 50
		var cautious: Dictionary = ctx.duplicate(true)
		var bold: Dictionary = ctx.duplicate(true)
		cautious["officer"]["personality"]["风险承受"] = 0
		bold["officer"]["personality"]["风险承受"] = 100
		var low := Eval.choose(cautious)
		var high := Eval.choose(bold)
		if low["candidate_id"] != high["candidate_id"]: differences += 1
		personality_cases.append({"case":i,"cautious":low["candidate_id"],"bold":high["candidate_id"],"different":low["candidate_id"] != high["candidate_id"],"low_score":low["score"],"high_score":high["score"],"low_factors":low["score_breakdown"],"high_factors":high["score_breakdown"]})
	print("PERSONALITY_TRADEOFFS ",differences,"/12 ",JSON.stringify(personality_cases))
	check(differences >= 6,"12个取舍情境中人格差异不足6个")
	var output := {"cases":results,"failures":failures,"personality_differences":differences,"personality_cases":personality_cases,"parsing_audit":audit,"notes":"Unfinished is recorded explicitly; measured timings include current machine load."}
	var file := FileAccess.open("res://docs/validation/tactical-baseline-2026-10-10.json" if baseline else "res://docs/validation/tactical-campaign-2026-10-10.json",FileAccess.WRITE)
	file.store_string(JSON.stringify(output,"\t"))
	store.restore_battle_test()
	print("TACTICAL_CAMPAIGN_OK" if failures.is_empty() else "TACTICAL_CAMPAIGN_FAILED "+str(failures))
	quit(0 if failures.is_empty() else 1)
