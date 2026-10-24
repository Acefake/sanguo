extends SceneTree

const Adapter = preload("res://scripts/agents/agent_adapter.gd")
const Scenarios = preload("res://scripts/war/battle/battle_scenarios.gd")

func _initialize() -> void: call_deferred("run")

func run() -> void:
	var store: Node = root.get_node("GameState")
	store.persist_enabled = false
	var model := Adapter.new()
	root.add_child(model)
	model.configure({"enabled":true,"endpoint":"http://127.0.0.1:11434/api/chat","model":"qwen3:1.7b","concurrency":1,"decision_budget":15,"timeout":15,"disable_reasoning":true}, false)
	var runs: Array = []
	var failed := false
	for spec in Scenarios.definitions():
		store.prepare_battle_test(false, spec["id"], 1910901)
		var war = store.war
		var corps: Dictionary = war.state["corps"].values().filter(func(c): return c["faction"] == war.state["player_faction"])[0]
		var context: Dictionary = war.Corps.commander_context(war, corps)
		if context["candidates"].any(func(candidate): return candidate["action"].has("formation") or candidate["action"]["type"] == "set_formation"): failed = true
		var compact: Dictionary = model._compact_context(context)
		if not compact.has("retreat_assessment") or not compact.has("orders") or not compact["corps"]["units"][0].has("fatigue"): failed = true
		var outputs := await model.choose_batch([context])
		var result: Dictionary = outputs.get(context["request_id"], {})
		var chosen: Dictionary = {}
		for candidate in context["candidates"]:
			if candidate["id"] == result.get("candidate_id", ""): chosen = candidate
		var applied := {"ok":false}
		if not chosen.is_empty(): applied = war.Corps.issue(war, corps, chosen["action"], str(result.get("reason_summary", "抽查")))
		if not applied.get("ok", false): failed = true
		var row := {"scenario":spec["id"],"source":result.get("source", ""),"action":chosen.get("action", {}),"reason":result.get("reason_summary", ""),"applied":applied,"vetoed":result.get("vetoed",false),"fallback_reason":result.get("fallback_reason", "")}
		runs.append(row)
		print("LIVE_SCENARIO ", JSON.stringify(row))
	var file := FileAccess.open("res://docs/validation/battle-scenarios-model.json", FileAccess.WRITE)
	file.store_string(JSON.stringify({"model":model.model,"metrics":model.metrics,"runs":runs,"failed":failed}, "\t"))
	store.restore_battle_test()
	print("BATTLE_SCENARIOS_MODEL_VALIDATION calls=", model.metrics["calls"], " failed=", failed)
	model.queue_free()
	quit(1 if failed else 0)
