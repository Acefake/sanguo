extends SceneTree

var failures: Array[String] = []

class SlowAgent extends Node:
	var endpoint := "fixture://slow"
	var model := "slow-fixture"
	var enabled := true
	var metrics := {"calls": 0, "fallbacks": 0}
	var delay := 0.35
	func supports_background_decisions() -> bool: return true
	func choose_batch(contexts: Array) -> Dictionary:
		metrics["calls"] += contexts.size()
		await get_tree().create_timer(delay).timeout
		var outputs := {}
		for context in contexts:
			var selected: Dictionary = context["candidates"][0]
			for candidate in context["candidates"]:
				if candidate["action"].get("task", "") == "flank": selected = candidate; break
			outputs[context["request_id"]] = {"candidate_id": selected["id"], "reason_summary": "测试主帅调整侧翼", "source": "model"}
		return outputs

func _initialize() -> void: call_deferred("_run")

func check(value: bool, message: String) -> void:
	if not value: failures.append(message); push_error(message)

func _run() -> void:
	var store: Node = root.get_node("GameState")
	store.persist_enabled = false
	store.prepare_battle_test(true)
	var agent := SlowAgent.new()
	root.add_child(agent)
	var start := Time.get_ticks_msec()
	await store.war.step(agent)
	var elapsed := Time.get_ticks_msec() - start
	check(elapsed < 150 and store.war.planner.running, "游戏日等待了模型回复")
	check(agent.metrics["calls"] == 2, "首轮不是仅2位主帅请求")
	await create_timer(0.45).timeout
	check(not store.war.planner.running and store.war.planner.ready.size() == 2, "后台请求没有完成")
	await store.war.step(agent)
	check(store.war.state["corps"].values().all(func(c): return c["orders"].any(func(o): return o["source"] == "model")), "模型回复没有在日边界应用")
	check(agent.metrics["calls"] == 2, "自己的军令触发了重复请求")
	# Movement within the same task is not a new decision trigger.
	for day in range(2): await store.war.step(agent)
	check(agent.metrics["calls"] <= 4, "逐日行军触发重复模型请求")
	store.prepare_battle_test(true)
	agent.delay = 0.5
	await store.war.step(agent)
	store.prepare_battle_test(true)
	await create_timer(0.6).timeout
	check(store.war.planner.ready.is_empty() and store.war.state["corps"].values().all(func(c): return c["orders"].is_empty()), "旧模型回复污染新场景")
	store.restore_battle_test()
	agent.queue_free()
	print("DECISION_SCHEDULER_OK: non-blocking day_ms=%d, only commanders, boundary application, cooldown, reset cancellation" % elapsed if failures.is_empty() else "DECISION_SCHEDULER_FAILED")
	quit(0 if failures.is_empty() else 1)
