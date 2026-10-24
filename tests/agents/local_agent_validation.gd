extends SceneTree

const Adapter = preload("res://scripts/agents/agent_adapter.gd")

class LocalServer extends Node:
	var tcp := TCPServer.new()
	var socket: StreamPeerTCP
	var data := ""
	var valid := false
	func _process(_delta: float) -> void:
		if tcp.is_connection_available(): socket = tcp.take_connection()
		if socket == null: return
		socket.poll()
		if socket.get_available_bytes() > 0: data += socket.get_utf8_string(socket.get_available_bytes())
		if not data.contains("\r\n\r\n"): return
		var sections := data.split("\r\n\r\n", true, 1)
		var length := 0
		for line in sections[0].split("\r\n"):
			if line.to_lower().begins_with("content-length:"): length = int(line.split(":")[1])
		if sections[1].to_utf8_buffer().size() < length: return
		var payload: Dictionary = JSON.parse_string(sections[1])
		valid = data.begins_with("POST /api/chat ") and not data.contains("Authorization:") and payload["think"] == false and payload.has("format")
		var body := JSON.stringify({"message": {"content": JSON.stringify({"candidate_id": "hold", "reason_summary": "保持阵线"})}})
		socket.put_data(("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % body.to_utf8_buffer().size() + body).to_utf8_buffer())
		socket = null
		tcp.stop()

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	root.get_node("GameState").persist_enabled = false
	var adapter := Adapter.new()
	adapter.configure({"enabled": true, "endpoint": "http://127.0.0.1:11434/api/chat", "model": "qwen3:1.7b", "concurrency": 1, "disable_reasoning": true}, false)
	var context := {"candidates": [{"id": "hold", "action": {"type": "hold"}}], "officer": {"name": "测试", "biography": "不应发送的长资料"}, "local_map": {"width": 15, "depth": 19, "blocked": [], "terrain": {"large": true}}}
	var payload: Dictionary = adapter._build_payload(context)
	var valid: bool = adapter.is_ollama() and payload["think"] == false and payload["options"]["num_predict"] == 128
	valid = valid and payload["format"]["properties"]["candidate_id"]["enum"] == ["hold"] and not payload["messages"][1]["content"].contains("biography") and not payload["messages"][1]["content"].contains("terrain")
	var body := JSON.stringify({"message": {"content": JSON.stringify({"candidate_id": "hold", "reason_summary": "保持阵线"})}, "prompt_eval_count": 20, "eval_count": 10})
	var action: Dictionary = adapter._decode_response(HTTPRequest.RESULT_SUCCESS, 200, body.to_utf8_buffer())
	valid = valid and action.get("candidate_id") == "hold" and adapter.metrics["input_tokens"] == 20
	var server := LocalServer.new()
	var port := 50000 + int(Time.get_ticks_usec() % 10000)
	if server.tcp.listen(port, "127.0.0.1") != OK:
		adapter.free()
		quit(1)
		return
	root.add_child(server)
	root.add_child(adapter)
	adapter.configure({"enabled": true, "endpoint": "http://127.0.0.1:%d/api/chat" % port, "model": "fixture", "api_key": "fake-cloud-key", "concurrency": 1, "decision_budget": 2}, false)
	context["request_id"] = "local-fixture"
	var outputs: Dictionary = await adapter.choose_batch([context])
	valid = valid and server.valid and outputs["local-fixture"].get("source") == "model" and adapter.metrics["fallbacks"] == 0
	adapter.queue_free()
	server.queue_free()
	print("LOCAL_AGENT_OK: native Ollama payload, thinking disabled, candidate schema, compact context and response" if valid else "LOCAL_AGENT_FAILED")
	quit(0 if valid else 1)
