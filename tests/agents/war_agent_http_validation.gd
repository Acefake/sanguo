extends SceneTree

const Adapter = preload("res://scripts/agents/agent_adapter.gd")
var failed := false


func _initialize() -> void:
	call_deferred("_run")


func _check(condition: bool, message: String) -> void:
	if not condition:
		failed = true
		push_error(message)


func _run() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var port: String = args[0] if not args.is_empty() else "0"
	var base: String = "http://127.0.0.1:" + port
	var adapter := Adapter.new()
	root.add_child(adapter)
	var contexts: Array = []
	for index in range(4):
		contexts.append({"request_id": "request-%d" % index, "officer": {"name": "测试主将"}, "candidates": [{"id": "hold-%d" % index, "action": {"type": "hold"}}]})
	adapter.configure({"enabled": true, "endpoint": base + "/v1/chat/completions", "model": "mock-only", "timeout": 2, "api_key": "test-session-key"}, false)
	var results: Dictionary = await adapter.choose_batch(contexts)
	for context in contexts:
		var result: Dictionary = results.get(context["request_id"], {})
		_check(result.get("source", "") == "model" and result.get("candidate_id", "") == context["candidates"][0]["id"], "HTTP批次响应串线或选择错误")
	_check(int(adapter.metrics["calls"]) == 4 and int(adapter.metrics["input_tokens"]) == 40, "接口耗量统计错误")
	for endpoint in ["/malformed", "/error", "/slow"]:
		adapter.configure({"enabled": true, "endpoint": base + endpoint, "model": "mock-only", "timeout": 2}, false)
		results = await adapter.choose_batch([contexts[0]])
		_check(results.get("request-0", {}).get("source", "") == "baseline", "HTTP异常未接管：" + endpoint)
	_check(int(adapter.metrics["failures"]) == 3, "接口失败统计不正确")
	adapter.configure({"enabled": true, "endpoint": base + "/slow", "model": "mock-only", "timeout": 2}, false)
	create_timer(0.05).timeout.connect(adapter.cancel_pending)
	results = await adapter.choose_batch([contexts[0]])
	_check(results.is_empty(), "取消后的迟到响应仍被提交")
	adapter.queue_free()
	await process_frame
	if not failed: print("WAR_AGENT_HTTP_OK: real HTTP transport, bounded batches, isolated responses, usage, malformed JSON, HTTP 503, timeout, cancellation; mock model only")
	quit(1 if failed else 0)
