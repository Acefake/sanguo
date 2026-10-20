extends SceneTree

const Adapter = preload("res://scripts/agents/agent_adapter.gd")
const Policy = preload("res://scripts/agents/baseline_policy.gd")
var failures: Array[String] = []

class MockServer extends Node:
	var tcp := TCPServer.new()
	var socket: StreamPeerTCP
	var data := ""
	var reply_id := "hold"
	var served := 0
	func _process(_delta: float) -> void:
		if socket == null and tcp.is_connection_available():
			socket = tcp.take_connection()
			data = ""
		if socket == null: return
		socket.poll()
		if socket.get_available_bytes() > 0: data += socket.get_utf8_string(socket.get_available_bytes())
		if not data.contains("\r\n\r\n"): return
		var sections: PackedStringArray = data.split("\r\n\r\n", true, 1)
		var length := 0
		for line in sections[0].split("\r\n"):
			if line.to_lower().begins_with("content-length:"): length = int(line.split(":")[1])
		if sections[1].to_utf8_buffer().size() < length: return
		served += 1
		var body := JSON.stringify({"choices": [{"message": {"content": JSON.stringify({"candidate_id": reply_id, "reason_summary": "模型选择"})}}]})
		socket.put_data(("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % body.to_utf8_buffer().size() + body).to_utf8_buffer())
		socket = null
	func _exit_tree() -> void: tcp.stop()

func _initialize() -> void: call_deferred("_run")

func check(value: bool, message: String) -> void:
	if not value:
		failures.append(message)
		push_error(message)

func _candidate(id: String, type: String, extra: Dictionary = {}) -> Dictionary:
	var action := {"type": type}
	action.merge(extra)
	return {"id": id, "action": action, "description": id}

func _context(candidates: Array, army: Dictionary, extra: Dictionary = {}) -> Dictionary:
	var context := {"request_id": extra.get("request_id", "r"), "observation_revision": 10, "army": army, "enemies": extra.get("enemies", []), "allies": [], "operation": extra.get("operation", {}), "target_known": extra.get("target_known", true), "returning": extra.get("returning", false), "current_action": {"type": "hold"}, "officer": {"name": "测试", "personality": {}, "trait_ids": []}, "candidates": candidates}
	if extra.has("level"): context["level"] = extra["level"]
	return context

func _run() -> void:
	root.get_node("GameState").persist_enabled = false
	var adapter := Adapter.new()
	root.add_child(adapter)
	# 1) 分差明确：不请求模型，直接本地决策。
	var army := {"strength": 5000, "morale": 90, "organization": 90, "grain_days": 20}
	var clear := _context([_candidate("hold", "hold"), _candidate("scout", "scout")], army, {"request_id": "clear", "target_known": false})
	check(not Policy.should_ask_model(clear), "分差明确仍请求模型")
	adapter.configure({"enabled": true, "endpoint": "http://127.0.0.1:9/chat/completions", "model": "m", "decision_budget": 2}, false)
	var gated: Dictionary = await adapter.choose_batch([clear])
	check(adapter.metrics["calls"] == 0 and adapter.metrics["local_decisions"] == 1, "分差明确没有走本地决策")
	check(str(gated["clear"].get("source", "")) == "baseline" and str(gated["clear"]["candidate_id"]) == "scout", "分差明确未采用本地最高分")
	# 2) 模糊：请求模型（离线则退回本地最高分）。
	var ambiguous := _context([_candidate("hold", "hold"), _candidate("scout", "scout")], army, {"request_id": "ambiguous", "target_known": true})
	check(Policy.should_ask_model(ambiguous), "分差模糊未请求模型")
	adapter.metrics["calls"] = 0
	var offline: Dictionary = await adapter.choose_batch([ambiguous])
	check(adapter.metrics["calls"] == 1 and adapter.metrics["fallbacks"] >= 1, "离线时没有尝试请求并回退")
	check(str(offline["ambiguous"].get("source", "")) == "baseline" and str(offline["ambiguous"]["candidate_id"]) == Policy.choose(ambiguous)["candidate_id"], "模型离线未退回本地最高分")
	# 3) 高风险：即使分差大也要问模型。
	var desperate := _context([_candidate("withdraw", "withdraw"), _candidate("engage", "engage", {"enemy": "e1"})], {"strength": 5000, "morale": 20, "organization": 20, "grain_days": 20}, {"request_id": "desperate", "enemies": [{"id": "e1", "strength_estimate": 5000}]})
	check(Policy.should_ask_model(desperate), "高风险行动未请求模型")
	# 4) 候选截断保留安全项。
	var many: Array = [_candidate("hold", "hold"), _candidate("withdraw", "withdraw")]
	for index in range(12): many.append(_candidate("march%d" % index, "march", {"target": "n%d" % index, "edge": "e"}))
	var capped: Array = adapter._model_candidates(_context(many, army, {"request_id": "many"}))
	var ids: Array = capped.map(func(c): return c["id"])
	check(capped.size() <= 13 and "withdraw" in ids and "hold" in ids, "候选截断没有保留安全选项")
	# 5) 守门否决：模型选择远低于最高分时被拦截。
	var server := MockServer.new()
	var port := 50000 + int(Time.get_ticks_usec() % 10000)
	if server.tcp.listen(port, "127.0.0.1") != OK:
		push_error("测试监听失败"); quit(1); return
	root.add_child(server)
	server.reply_id = "engage"
	adapter.configure({"enabled": true, "endpoint": "http://127.0.0.1:%d/chat/completions" % port, "model": "m", "decision_budget": 2, "concurrency": 1}, false)
	adapter.metrics["vetoes"] = 0
	var veto_context := _context([_candidate("withdraw", "withdraw"), _candidate("engage", "engage", {"enemy": "e1"})], {"strength": 5000, "morale": 20, "organization": 20, "grain_days": 20}, {"request_id": "veto"})
	var verdict: Dictionary = Policy.veto(veto_context, "engage")
	check(not verdict.get("ok", true), "低分模型选择没有被否决")
	var result: Dictionary = await adapter.choose_batch([veto_context])
	check(adapter.metrics["vetoes"] == 1 and bool(result["veto"].get("vetoed", false)), "守门否决没有生效或没有记录")
	check(str(result["veto"]["candidate_id"]) == "withdraw" and str(result["veto"].get("source", "")) != "model", "否决后没有采用本地最高分")
	check(Policy.veto(veto_context, "withdraw").get("ok", false), "高分候选被误否决")
	server.queue_free()
	adapter.queue_free()
	print("MODEL_GATE_OK: clear margin stays local, ambiguous asks, high risk asks, candidate cap keeps safe options, veto blocks low picks, offline falls back" if failures.is_empty() else "MODEL_GATE_FAILED")
	quit(0 if failures.is_empty() else 1)
