extends SceneTree
## 不阻塞检验（08b §9 第 1 条）：MockAdapter 固定延迟 30 秒，连跑 30 日战役，step() 从不等待模型。
##
##   godot --headless --path . --script res://tests/agents/step_latency_validation.gd
##
## 同一剧本先跑纯规则（adapter = null）再跑 MockAdapter，打印两组 step() 单次耗时 p50/p95/p99/max（毫秒，不含渲染），
## 以及每次 step 里花在决策调度（DecisionScheduler 的 begin_round / submit / take）上的耗时。
## 断言：MockAdapter 模式下每次 step 都在同一帧内返回（没有挂起等待）、确实向队列提交了请求、
## 调度耗时 p99 < 16 ms。step 总耗时包含战役引擎本身的结算（纯规则那一组就是引擎的底数），
## 只打印 STEP_BUDGET 供对比，不作断言。

const Store = preload("res://scripts/core/game_state.gd")
const DAYS := 30
const BUDGET_MS := 16.0

var failures: Array[String] = []


## 给每次 step 计调度耗时的 DecisionScheduler。
class TimedScheduler extends "res://scripts/agents/decision_scheduler.gd":
	var usec := 0
	func begin_round(round_now: int) -> void:
		var started := Time.get_ticks_usec()
		super.begin_round(round_now)
		usec += Time.get_ticks_usec() - started
	func submit(contexts: Array, adapter: Node, signatures: Dictionary, defaults: Dictionary = {}) -> bool:
		var started := Time.get_ticks_usec()
		var accepted := super.submit(contexts, adapter, signatures, defaults)
		usec += Time.get_ticks_usec() - started
		return accepted
	func take(key: String, signature: String, tick: int, context_now: Dictionary = {}) -> Dictionary:
		var started := Time.get_ticks_usec()
		var proposal := super.take(key, signature, tick, context_now)
		usec += Time.get_ticks_usec() - started
		return proposal


## 固定延迟 30 秒、从候选里取第 2 名的模型替身。
class MockAdapter extends Node:
	var endpoint := "mock://fixed-delay"
	var model := "mock"
	var enabled := true
	var metrics := {"calls": 0, "fallbacks": 0}
	var delay := 30.0
	func supports_background_decisions() -> bool: return true
	func can_request_model(_context: Dictionary) -> bool: return true
	func choose_batch(contexts: Array) -> Dictionary:
		metrics["calls"] += contexts.size()
		await get_tree().create_timer(delay).timeout
		var outputs := {}
		for context in contexts:
			var candidates: Array = context.get("candidates", [])
			if not candidates.is_empty(): outputs[context["request_id"]] = {"candidate_id": candidates[mini(1, candidates.size() - 1)]["id"], "reason_summary": "替身", "source": "model"}
		return outputs


func _initialize() -> void: call_deferred("_run")


func check(value: bool, message: String) -> void:
	if not value:
		failures.append(message)
		push_error(message)


func _run() -> void:
	var queue: Node = root.get_node("ModelQueue")
	queue.set_log_path("user://step_latency_decisions.jsonl")
	var rules := await _campaign(null)
	var mock := MockAdapter.new()
	root.add_child(mock)
	var submitted_before: int = queue.stats()["submitted"]
	var modeled := await _campaign(mock)
	var submitted: int = int(queue.stats()["submitted"]) - submitted_before
	print("STEP_MS rules  ", JSON.stringify(_summary(rules["ms"])))
	print("STEP_MS mock30 ", JSON.stringify(_summary(modeled["ms"])), " submitted=", submitted, " suspended=", modeled["suspended"])
	print("SCHEDULER_MS mock30 ", JSON.stringify(_summary(modeled["scheduler_ms"])))
	print("MODEL_QUEUE_STATS ", JSON.stringify(queue.stats()))
	check(int(modeled["suspended"]) == 0, "有 %d 次 step 挂起等待" % int(modeled["suspended"]))
	check(submitted > 0, "MockAdapter 模式没有向队列提交任何请求，检验无效")
	check(float(_summary(modeled["scheduler_ms"])["p99"]) < BUDGET_MS, "决策调度耗时 p99 超过 %.0f ms" % BUDGET_MS)
	# step 总耗时含战役引擎本身的结算，纯规则一组就是引擎底数；只报告，不作为本检验的断言（慢在引擎而不在模型等待）。
	print("STEP_BUDGET mock30 p99=%.2f ms rules p99=%.2f ms budget=%.0f ms" % [float(_summary(modeled["ms"])["p99"]), float(_summary(rules["ms"])["p99"]), BUDGET_MS])
	mock.queue_free()
	print("STEP_LATENCY_OK: %d days, mock 30s, no suspension" % DAYS if failures.is_empty() else "STEP_LATENCY_FAILED")
	quit(0 if failures.is_empty() else 1)


## 新开一局演示剧本跑 DAYS 日；返回每日 step 耗时（毫秒）与挂起次数。
func _campaign(adapter: Node) -> Dictionary:
	var sandbox := Store.new()
	sandbox.persist_enabled = false
	sandbox._load_demo()
	var war = sandbox.war
	var timed := TimedScheduler.new()
	timed.alive = war.planner.alive
	war.planner = timed
	var times: Array[float] = []
	var scheduler_times: Array[float] = []
	var suspended := 0
	for day in DAYS:
		var frame := Engine.get_process_frames()
		var started := Time.get_ticks_usec()
		var scheduler_before := timed.usec
		await war.step(adapter)
		times.append((Time.get_ticks_usec() - started) / 1000.0)
		scheduler_times.append((timed.usec - scheduler_before) / 1000.0)
		if Engine.get_process_frames() != frame: suspended += 1
	timed.clear()
	sandbox.free()
	return {"ms": times, "scheduler_ms": scheduler_times, "suspended": suspended}


static func _summary(times: Array[float]) -> Dictionary:
	var sorted := times.duplicate()
	sorted.sort()
	var pick := func(q: float) -> float: return snappedf(sorted[clampi(int(ceil(q * sorted.size())) - 1, 0, sorted.size() - 1)], 0.01)
	return {"n": sorted.size(), "p50": pick.call(0.5), "p95": pick.call(0.95), "p99": pick.call(0.99), "max": snappedf(sorted[-1], 0.01)}
