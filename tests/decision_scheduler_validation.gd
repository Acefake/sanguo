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
				if candidate["action"].get("type", "") == "maintain": selected = candidate; break
			outputs[context["request_id"]] = {"candidate_id": selected["id"], "reason_summary": "测试主帅维持合法部署", "source": "model"}
		return outputs

func _initialize() -> void: call_deferred("_run")

func check(value: bool, message: String) -> void:
	if not value: failures.append(message); push_error(message)

func _run() -> void:
	var store: Node = root.get_node("GameState")
	store.persist_enabled = false
	store.prepare_battle_test(true)
	for army in store.war.active_armies(): army["corps_task"]["issued_at"] = 0
	var agent := SlowAgent.new()
	root.add_child(agent)
	var start := Time.get_ticks_msec()
	await store.war.step(agent)
	var elapsed := Time.get_ticks_msec() - start
	# A pending request proves that step returned before the reply. A fixed
	# wall-time limit also counted terrain/AI work and failed under renderer load.
	check(store.war.planner.running and store.war.planner.ready.is_empty(), "游戏日等待了模型回复")
	print("DECISION_SCHEDULER_STEP_MS ",elapsed)
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
	agent.delay = 0.35
	# 2) 批次槽位只有一个：军团批次在飞时，自由部队的提交必须排队而不是被静默丢弃。
	# 旧实现直接返回 false，调用方不检查，当天所有非军团部队只吃本地策略，且因为
	# decision_key 已提前写入，最长三日不会重判。
	var scheduler: RefCounted = preload("res://scripts/agents/decision_scheduler.gd").new()
	var context: Dictionary = {"army_id": "army-0001", "observation_revision": 1, "request_id": "army-0001:1", "candidates": [{"id": "hold", "action": {"type": "hold"}}]}
	var queued_context: Dictionary = context.duplicate(true)
	queued_context["army_id"] = "army-0002"
	queued_context["request_id"] = "army-0002:1"
	check(scheduler.submit([context], agent, {"army:army-0001": "s1"}), "首个批次未提交")
	check(scheduler.submit([queued_context], agent, {"army:army-0002": "s2"}), "槽位被占时提交被丢弃而不是排队")
	check(scheduler.queued_requests == 1 and scheduler.has_pending("army:army-0002"), "排队批次没有登记为待决")
	await create_timer(agent.delay * 2.6).timeout
	check(not scheduler.running and scheduler.ready.size() == 2, "排队批次没有在槽位空闲后发出")
	agent.queue_free()
	print("DECISION_SCHEDULER_OK: non-blocking day_ms=%d, only commanders, boundary application, cooldown, reset cancellation, queued batch" % elapsed if failures.is_empty() else "DECISION_SCHEDULER_FAILED")
	quit(0 if failures.is_empty() else 1)
