extends SceneTree

const Adapter = preload("res://scripts/agents/agent_adapter.gd")

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	var store: Node = root.get_node("GameState")
	store.persist_enabled = false
	store.prepare_battle_test()
	var adapter := Adapter.new()
	root.add_child(adapter)
	adapter.configure({"enabled": true, "endpoint": "http://127.0.0.1:11434/api/chat", "model": "qwen3:1.7b", "concurrency": 1, "decision_budget": 15, "timeout": 15, "disable_reasoning": true}, false)
	var contexts: Array = []
	for corps in store.war.state["corps"].values(): contexts.append(store.war.Corps.commander_context(store.war, corps))
	var start := Time.get_ticks_msec()
	var outputs: Dictionary = await adapter.choose_batch(contexts)
	var elapsed := Time.get_ticks_msec() - start
	var valid_models := 0
	var choices := {}
	var decisions: Array = []
	for context in contexts:
		var result: Dictionary = outputs.get(context["request_id"], {})
		var validated: Dictionary = {"ok": false}
		for candidate in context["candidates"]:
			if candidate["id"] == result.get("candidate_id", ""): validated = {"ok": true, "action": candidate["action"]}
		if result.get("source") == "model" and validated.get("ok", false): valid_models += 1
		var kind: String = str(validated.get("action", {}).get("type", "invalid"))
		choices[kind] = int(choices.get(kind, 0)) + 1
		decisions.append({"officer": context["officer"]["name"], "role": "commander", "action": kind, "reason": result.get("reason_summary", ""), "source": result.get("source", "")})
	var report := {"model": adapter.model, "commander_count": contexts.size(), "formation_count": store.war.active_armies().size(), "elapsed_ms": elapsed, "valid_model_decisions": valid_models, "metrics": adapter.metrics.duplicate(true), "concurrency": 1, "budget_seconds": 15, "thinking": false, "choices": choices, "decisions": decisions}
	if "--simulate" in OS.get_cmdline_user_args():
		var days: Array = []
		var collisions := 0
		for day in range(3):
			var day_started := Time.get_ticks_msec()
			await store.war.step(adapter)
			var occupied := {}
			var fighting := 0
			var returning := 0
			for army in store.war.active_armies():
				var key: String = str(army["tactical"]["cell"])
				if occupied.has(key) or store.war.state["battlefield"]["blocked"].has(army["tactical"]["cell"]): collisions += 1
				occupied[key] = true
				if army.get("combat_tick", -1) == store.war.state["tick"]: fighting += 1
				if army["returning"]: returning += 1
			days.append({"tick": store.war.state["tick"], "elapsed_ms": Time.get_ticks_msec() - day_started, "active": occupied.size(), "fighting": fighting, "returning": returning})
			await create_timer(2.0).timeout
		report["three_day_simulation"] = days
		# Verify a real reply reaches the rule boundary, not only the protocol parser.
		var waited := Time.get_ticks_msec()
		while store.war.planner.running and Time.get_ticks_msec() - waited < 18000:
			await create_timer(0.25).timeout
		await store.war.step(adapter)
		var model_orders := 0
		var applied_orders := 0
		for corps in store.war.state["corps"].values():
			for order in corps["orders"]:
				if order.get("source", "") == "model":
					model_orders += 1
					if order["applied"].get("ok", false): applied_orders += 1
		report["boundary_model_orders"] = model_orders
		report["boundary_applied_orders"] = applied_orders
		report["deployed_corps"] = store.war.state["corps"].values().filter(func(c): return c.get("deployed", false)).size()
		report["final_formation_count"] = store.war.active_armies().size()
		report["discarded_stale_proposals"] = store.war.planner.discarded
		report["collisions"] = collisions
		report["simulation_metrics"] = adapter.metrics.duplicate(true)
		if collisions > 0: valid_models = 0
	var file := FileAccess.open("res://docs/validation/local-agent-benchmark.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	print("LOCAL_AGENT_LIVE ", JSON.stringify(report))
	store.restore_battle_test()
	adapter.queue_free()
	quit(0 if valid_models > 0 else 1)
