extends SceneTree
## ModelQueue / DecisionScheduler / ModelClient 的行为检验，不依赖 GameState 与战役数据。
##
##   godot --headless --path . --script res://tests/agents/model_queue_validation.gd
##
## 覆盖 08b §9 的 2–4 条：提交点（早到用模型、晚到用默认、复查与否决）、情境失效丢弃不报错、同人同类顶替且队列不增长；
## 另有优先级、超时、统计、决策日志与传输层解码。

const Client = preload("res://scripts/agents/model_client.gd")
const Request = preload("res://scripts/agents/decision_request.gd")
const Scheduler = preload("res://scripts/agents/decision_scheduler.gd")

var failures: Array[String] = []
var queue: Node


## 只实现 choose_batch 的夹具：固定延迟后从候选里取第 2 名（没有第 2 名取第 1 名）。
class MockAdapter extends Node:
	var delay := 0.05
	var concurrency := 6
	var calls := 0
	func supports_background_decisions() -> bool: return true
	func veto(_context: Dictionary, candidate_id: String) -> Dictionary: return {"ok": candidate_id != "reckless"}
	func choose_batch(contexts: Array) -> Dictionary:
		calls += contexts.size()
		await get_tree().create_timer(delay).timeout
		var outputs := {}
		for context in contexts:
			var candidates: Array = context["candidates"]
			outputs[context["request_id"]] = {"candidate_id": candidates[mini(1, candidates.size() - 1)]["id"], "reason_summary": "夹具", "source": "model"}
		return outputs


func _initialize() -> void: call_deferred("_run")


func check(value: bool, message: String) -> void:
	if not value:
		failures.append(message)
		push_error(message)


func _run() -> void:
	queue = root.get_node("ModelQueue")
	queue.set_log_path("user://model_queue_validation.jsonl")
	_client_checks()
	await _priority_checks()
	await _supersede_checks()
	await _stale_queue_checks()
	await _timeout_checks()
	await _commit_checks()
	print("MODEL_QUEUE_STATS ", JSON.stringify(queue.stats()))
	print("MODEL_QUEUE_OK: client decode, priority, supersede, stale, timeout, commit point, decision log" if failures.is_empty() else "MODEL_QUEUE_FAILED")
	quit(0 if failures.is_empty() else 1)


func _client_checks() -> void:
	var ollama := "http://127.0.0.1:11434/api/chat"
	var cloud := "https://openrouter.ai/api/v1/chat/completions"
	check(Client.lane(ollama) == "local" and Client.lane("http://localhost:8080/v1/chat/completions") == "local" and Client.lane(cloud) == "cloud", "本地/云端通道判断错误")
	var payload := Client.chat_payload(ollama, "m", [], ["a", "b"], true)
	check(payload["think"] == false and payload["format"]["properties"]["candidate_id"]["enum"] == ["a", "b"] and not payload.has("max_tokens"), "Ollama 协议字段错误")
	payload = Client.chat_payload(cloud, "m", [], ["a"], true)
	check(payload["max_tokens"] == 256 and payload["reasoning"] == {"enabled": false} and not payload.has("format"), "OpenRouter 适配字段错误")
	check(not Client.headers(ollama, "k").has("Authorization: Bearer k") and Client.headers(cloud, "k").has("Authorization: Bearer k"), "请求头密钥规则错误")
	var body := JSON.stringify({"message": {"content": "```json\n{\"candidate_id\":\"hold\",\"reason_summary\":\"守\"}\n```"}, "prompt_eval_count": 20, "eval_count": 10})
	var decoded := Client.decode(ollama, HTTPRequest.RESULT_SUCCESS, 200, body.to_utf8_buffer())
	check(decoded.get("candidate_id") == "hold" and decoded["usage"]["input"] == 20 and decoded["source"] == "model", "Ollama 响应解码错误")
	check(Client.decode(cloud, HTTPRequest.RESULT_SUCCESS, 401, PackedByteArray()).has("error"), "HTTP 错误没有报错")
	check(Client.decode(cloud, HTTPRequest.RESULT_SUCCESS, 200, "{\"choices\":[]}".to_utf8_buffer()).has("error"), "空 choices 没有报错")


static func _request(id: String, actor: String, delay: float, value: float = 1.0, commit: int = 1, deadline: int = 5000) -> Request:
	var request := Request.new()
	request.request_id = id
	request.kind = "army"
	request.actor = actor
	request.value = value
	request.commit_tick = commit
	request.real_deadline_ms = deadline
	request.lane = "cloud"
	request.lane_limit = 1
	request.fetch = func() -> Dictionary:
		await Engine.get_main_loop().create_timer(delay).timeout
		return {"candidate_id": id, "source": "model"}
	return request


func _priority_checks() -> void:
	queue.advance(0)
	var order: Array = []
	var record := func(id: String) -> void:
		if queue.has_answer(id): order.append(id)
	queue.settled.connect(record)
	queue.submit(_request("busy", "p0", 0.05))
	queue.submit(_request("far", "p1", 0.01, 1.0, 10))
	queue.submit(_request("near", "p2", 0.01, 3.0, 1))
	while order.size() < 3: await process_frame
	queue.settled.disconnect(record)
	check(order == ["busy", "near", "far"], "优先级顺序错误：%s" % str(order))
	for id in order: queue.take(id)


func _supersede_checks() -> void:
	var before: int = queue.stats()["superseded"]
	for i in range(20): queue.submit(_request("dup-%d" % i, "same-actor", 0.05))
	check(queue.queued_count() + queue.inflight_count() == 1, "同人同类顶替后队列长度增长：%d" % (queue.queued_count() + queue.inflight_count()))
	check(int(queue.stats()["superseded"]) - before == 19, "顶替计数错误")
	# dup-0 已发出：作废后 HTTP 请求仍在路上，通道（并发 1）要等它返回才让最新请求发出。
	check(queue.inflight_count() == 0 and queue.queued_count() == 1, "顶替在飞请求后，新请求在旧请求返回前就占用了通道")
	while queue.is_pending("dup-19"): await process_frame
	check(queue.has_answer("dup-19") and not queue.has_answer("dup-0"), "顶替后保留的不是最新请求")
	queue.take("dup-19")


func _stale_queue_checks() -> void:
	var routed := {"value": false}
	queue.submit(_request("blocker", "s0", 0.05))
	var doomed := _request("doomed", "s1", 0.01)
	doomed.alive = func() -> bool: return not routed["value"]
	queue.submit(doomed)
	routed["value"] = true
	var before: int = queue.stats()["stale"]
	while queue.is_pending("doomed") or queue.is_pending("blocker"): await process_frame
	check(int(queue.stats()["stale"]) == before + 1 and queue.take("doomed").is_empty(), "情境失效的请求没有在出队时丢弃")
	queue.take("blocker")


func _timeout_checks() -> void:
	var before: int = queue.stats()["timeouts"]
	queue.submit(_request("slow", "t0", 0.4, 1.0, 1, 50))
	while queue.is_pending("slow"): await process_frame
	check(int(queue.stats()["timeouts"]) == before + 1 and queue.take("slow").is_empty(), "超过现实时限没有判超时")
	await create_timer(0.45).timeout
	check(not queue.has_answer("slow"), "超时后迟到的结果仍被保留")


func _context(request_id: String, ids: Array) -> Dictionary:
	return {"army_id": "army-x", "actor_key": "army:army-x", "request_id": request_id, "level": "unit", "candidates": ids.map(func(id): return {"id": id, "action": {"type": id}})}


func _commit_checks() -> void:
	var adapter := MockAdapter.new()
	root.add_child(adapter)
	var scheduler := Scheduler.new()
	var lines_before := _log_lines()
	var defaults := {"r1": {"candidate_id": "hold", "source": "baseline"}}
	# 早到：答案在提交点之前到达，并通过复查 → 采用模型答案（第 2 名 engage）。
	scheduler.begin_round(1)
	scheduler.submit([_context("r1", ["hold", "engage"])], adapter, {"army:army-x": "h1"}, defaults)
	await create_timer(0.15).timeout
	check(scheduler.take("army:army-x", "h1", 1, _context("r1-now", ["hold", "engage"])).is_empty(), "提交点之前就交出了答案")
	scheduler.begin_round(2)
	var early := scheduler.take("army:army-x", "h1", 2, _context("r2", ["engage", "hold"]))
	check(early.get("result", {}).get("candidate_id", "") == "engage", "早到的模型答案没有在提交点采用")
	# 晚到：提交点时答案未到 → 默认；之后到达的答案被丢弃。
	adapter.delay = 0.3
	scheduler.submit([_context("r3", ["hold", "engage"])], adapter, {"army:army-x": "h3"}, {"r3": {"candidate_id": "hold"}})
	scheduler.begin_round(3)
	check(scheduler.take("army:army-x", "h3", 3, _context("r3-now", ["hold", "engage"])).is_empty() and not scheduler.has_pending("army:army-x"), "晚到的请求在提交点没有作废")
	await create_timer(0.4).timeout
	check(scheduler.ready.is_empty(), "提交点之后到达的答案仍进入 ready")
	# 复查：今日候选里已没有模型选的行动 → 不采用。
	adapter.delay = 0.01
	scheduler.submit([_context("r4", ["hold", "flank"])], adapter, {"army:army-x": "h4"})
	await create_timer(0.1).timeout
	scheduler.begin_round(4)
	check(scheduler.take("army:army-x", "h4", 4, _context("r4-now", ["hold", "engage"])).is_empty(), "非法答案通过了提交点复查")
	# 否决：答案合法但按今日上下文被适配器否决 → 不采用。
	scheduler.submit([_context("r45", ["hold", "reckless"])], adapter, {"army:army-x": "h45"})
	await create_timer(0.1).timeout
	scheduler.begin_round(5)
	check(scheduler.take("army:army-x", "h45", 5, _context("r45-now", ["hold", "reckless"])).is_empty(), "被否决的答案仍被采用")
	# 情境失效：答案已到但军队溃散 → 丢弃，不报错。
	var routed := {"value": false}
	scheduler.alive = func(_key: String) -> bool: return not routed["value"]
	scheduler.submit([_context("r5", ["hold", "engage"])], adapter, {"army:army-x": "h5"})
	await create_timer(0.1).timeout
	routed["value"] = true
	scheduler.begin_round(6)
	check(scheduler.take("army:army-x", "h5", 6, _context("r5-now", ["hold", "engage"])).is_empty(), "溃散后的答案没有丢弃")
	# 顶替：同一 key 连续提交，只留最新一个。
	scheduler.alive = Callable()
	adapter.delay = 0.05
	for i in range(10): scheduler.submit([_context("dup-r%d" % i, ["hold", "engage"])], adapter, {"army:army-x": "d%d" % i})
	check(scheduler.requested.size() == 1 and queue.queued_count() + queue.inflight_count() <= 1, "调度器顶替后队列增长")
	scheduler.clear()
	await create_timer(0.1).timeout
	check(scheduler.ready.is_empty(), "clear 之后旧答案仍落地")
	var lines := _log_lines().slice(lines_before.size())
	var outcomes: Array = lines.map(func(line): return JSON.parse_string(line)["outcome"])
	check(outcomes.has("adopted") and outcomes.has("late") and outcomes.has("illegal") and outcomes.has("vetoed") and outcomes.has("stale"), "决策日志缺少结论：%s" % str(outcomes))
	var adopted: Dictionary = JSON.parse_string(lines[outcomes.find("adopted")])
	check(adopted["final"] == "engage" and adopted["default"] == "hold", "决策日志的最终采用值错误")
	adapter.queue_free()


func _log_lines() -> Array:
	return Array(FileAccess.get_file_as_string(queue.log_path()).split("\n", false))
