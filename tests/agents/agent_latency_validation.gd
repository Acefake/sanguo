extends SceneTree

const Adapter = preload("res://scripts/agents/agent_adapter.gd")
var failures: Array[String] = []

class LocalServer extends Node:
	var tcp := TCPServer.new()
	var peers: Array = []
	var received := 0
	var max_pending := 0
	func _process(_delta: float) -> void:
		while tcp.is_connection_available():
			peers.append({"socket": tcp.take_connection(), "data": "", "received": false, "at": 0, "blocked": false})
		for peer in peers.duplicate():
			var socket: StreamPeerTCP = peer["socket"]
			socket.poll()
			if socket.get_status() != StreamPeerTCP.STATUS_CONNECTED:
				peers.erase(peer)
				continue
			if socket.get_available_bytes() > 0:
				peer["data"] += socket.get_utf8_string(socket.get_available_bytes())
			if not peer["received"] and peer["data"].contains("\r\n\r\n"):
				var sections: PackedStringArray = peer["data"].split("\r\n\r\n", true, 1)
				var length := 0
				for line in sections[0].split("\r\n"):
					if line.to_lower().begins_with("content-length:"): length = int(line.split(":")[1])
				if sections[1].to_utf8_buffer().size() >= length:
					peer["received"] = true
					peer["at"] = Time.get_ticks_msec()
					peer["blocked"] = received == 0
					received += 1
					max_pending = maxi(max_pending, peers.size())
			if peer["received"] and not peer["blocked"] and Time.get_ticks_msec() - peer["at"] >= 150:
				var body := JSON.stringify({"choices": [{"message": {"content": "{\"candidate_id\":\"hold\",\"reason_summary\":\"本地测试\"}"}}]})
				socket.put_data(("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % body.to_utf8_buffer().size() + body).to_utf8_buffer())
				peers.erase(peer)
	func _exit_tree() -> void:
		tcp.stop()
		for peer in peers: peer["socket"].disconnect_from_host()

func _initialize() -> void: call_deferred("_run")

func check(value: bool, message: String) -> void:
	if not value:
		failures.append(message)
		push_error(message)

func _run() -> void:
	root.get_node("GameState").persist_enabled = false
	var server := LocalServer.new()
	var port := 50000 + int(Time.get_ticks_usec() % 10000)
	if server.tcp.listen(port, "127.0.0.1") != OK:
		push_error("测试监听失败")
		quit(1)
		return
	root.add_child(server)
	var adapter := Adapter.new()
	root.add_child(adapter)
	adapter.configure({"enabled": true, "endpoint": "http://127.0.0.1:%d/chat/completions" % port, "model": "local-fixture", "decision_budget": 2, "concurrency": 6}, false)
	var contexts: Array = []
	for index in range(18): contexts.append({"request_id": str(index), "observation_revision": 1, "candidates": [{"id": "hold", "action": {"type": "hold"}}]})
	var started := Time.get_ticks_msec()
	var outputs: Dictionary = await adapter.choose_batch(contexts)
	var elapsed := Time.get_ticks_msec() - started
	check(elapsed < 3000, "慢请求突破整日等待上限（%dms）" % elapsed)
	check(server.received == 18 and server.max_pending <= 6, "慢武将阻塞后续请求或超出并发数")
	check(outputs.size() == 18 and adapter.metrics["fallbacks"] == 1, "超时没有单独回退或已完成模型结果丢失")
	adapter.endpoint = "https://openrouter.ai/api/v1/chat/completions"
	var payload: Dictionary = adapter._build_payload(contexts[0])
	check(payload["reasoning"]["enabled"] == false and payload["max_tokens"] == 256, "没有关闭思考或限制短答")
	adapter.endpoint = "http://localhost/chat/completions"
	check(not adapter._build_payload(contexts[0]).has("reasoning"), "通用接口被注入不兼容参数")
	server.queue_free()
	adapter.queue_free()
	if failures.is_empty(): print("AGENT_LATENCY_OK: 18 requests, rolling concurrency <= 6, one stalled request, budget_ms=%d, one fallback, reasoning control" % elapsed)
	quit(0 if failures.is_empty() else 1)
