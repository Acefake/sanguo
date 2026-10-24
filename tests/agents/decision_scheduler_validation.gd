extends SceneTree

var failures: Array[String] = []

class SlowAgent extends Node:
	var endpoint := "fixture://slow"
	var model := "slow-fixture"
	var enabled := true
	var metrics := {"calls": 0, "fallbacks": 0}
	var delay := 0.35
	var concurrency := 6
	## instant：答案在提交当下同步返回（不等计时器），即“模型答案总能赶上提交点”。
	var instant := false
	func supports_background_decisions() -> bool: return true
	func can_request_model(context: Dictionary) -> bool: return context.get("level","") not in ["unit", "adviser"]
	func choose_batch(contexts: Array) -> Dictionary:
		metrics["calls"] += contexts.size()
		if not instant: await get_tree().create_timer(delay).timeout
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
	agent.concurrency = 1
	var context: Dictionary = {"army_id": "army-0001", "observation_revision": 1, "request_id": "army-0001:1", "candidates": [{"id": "hold", "action": {"type": "hold"}}]}
	var queued_context: Dictionary = context.duplicate(true)
	queued_context["army_id"] = "army-0002"
	queued_context["request_id"] = "army-0002:1"
	check(scheduler.submit([context], agent, {"army:army-0001": "s1"}), "首个批次未提交")
	check(scheduler.submit([queued_context], agent, {"army:army-0002": "s2"}), "槽位被占时提交被丢弃而不是排队")
	check(scheduler.queued_requests == 1 and scheduler.has_pending("army:army-0002"), "排队批次没有登记为待决")
	await create_timer(agent.delay * 2.6).timeout
	check(not scheduler.running and scheduler.ready.size() == 2, "排队批次没有在槽位空闲后发出")
	# 3) 即时答案的主帅决策在提交点被采纳；提交日之前军团已撤退的，记 stale 而不是 expired。
	# 回归：演示剧本里主帅答案几乎全记 expired，排查后是军团在提交日前整体撤退、plan_background 不再来取，
	# begin_round 把它们当成“提交点错过”记 expired，看起来像模型答案全部作废。
	agent.concurrency = 6
	agent.instant = true
	var outcomes := await _commander_outcomes(store, agent, false)
	check(int(outcomes.get("adopted", 0)) >= 2 and not outcomes.has("expired"), "即时答案的主帅决策没有在提交点被采纳：%s" % JSON.stringify(outcomes))
	outcomes = await _commander_outcomes(store, agent, true)
	check(int(outcomes.get("stale", 0)) == 2 and not outcomes.has("expired") and not outcomes.has("adopted"), "提交日前撤退的军团，主帅答案没有记为 stale：%s" % JSON.stringify(outcomes))
	store.restore_battle_test()
	agent.queue_free()
	print("DECISION_SCHEDULER_OK: non-blocking day_ms=%d, only commanders, boundary application, cooldown, reset cancellation, queued batch, instant commander adopted, withdrawn corps stale" % elapsed if failures.is_empty() else "DECISION_SCHEDULER_FAILED")
	quit(0 if failures.is_empty() else 1)


## 新开一场预编成战场，走三日，返回主帅（commander）请求在决策日志里的结论计数。
## withdraw_first：第一日提交后立刻让全部军团撤退（decision_alive 变 false），模拟提交日前军团整体撤退。
func _commander_outcomes(store: Node, agent: Node, withdraw_first: bool) -> Dictionary:
	var queue: Node = root.get_node("ModelQueue")
	var path := "user://decision_scheduler_validation_%s.jsonl" % ("withdraw" if withdraw_first else "instant")
	if FileAccess.file_exists(path): DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	var previous: String = queue.log_path()
	queue.set_log_path(path)
	store.prepare_battle_test(true)
	for army in store.war.active_armies(): army["corps_task"]["issued_at"] = 0
	await store.war.step(agent)
	await process_frame
	check(store.war.planner.ready.size() == 2, "即时答案没有在提交当日到达")
	if withdraw_first:
		for corps in store.war.state["corps"].values(): corps["withdrawing"] = true
	for day in 2: await store.war.step(agent)
	queue.flush_log()
	queue.set_log_path(previous)
	var outcomes := {}
	for line in FileAccess.get_file_as_string(path).split("\n", false):
		var entry: Variant = JSON.parse_string(line)
		if entry is Dictionary and entry.get("kind", "") == "commander":
			outcomes[entry["outcome"]] = int(outcomes.get(entry["outcome"], 0)) + 1
	return outcomes
