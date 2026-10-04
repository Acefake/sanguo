extends Node

const SETTINGS_PATH := "user://officer_agent.cfg"
var settings_path := SETTINGS_PATH
const POLICY = preload("res://scripts/agents/baseline_policy.gd")
var enabled := false
var endpoint := ""
var model := ""
var api_key := ""
var timeout_seconds := 15.0
var generation := 0
var metrics: Dictionary = {"calls": 0, "failures": 0, "fallbacks": 0, "input_tokens": 0, "output_tokens": 0}
var last_status := "本地策略 · 尚未配置模型"


func load_settings() -> void:
	var config := ConfigFile.new()
	if config.load(settings_path) == OK:
		enabled = bool(config.get_value("agent", "enabled", false))
		endpoint = str(config.get_value("agent", "endpoint", ""))
		model = str(config.get_value("agent", "model", ""))
		api_key = str(config.get_value("agent", "api_key", ""))
		timeout_seconds = clampf(float(config.get_value("agent", "timeout", 15)), 2, 60)
	last_status = "智能体已启用" if enabled and not endpoint.is_empty() and not model.is_empty() else "本地策略 · 尚未配置模型"


func configure(values: Dictionary, persist: bool = true) -> String:
	var next_endpoint: String = str(values.get("endpoint", "")).strip_edges()
	var next_model: String = str(values.get("model", "")).strip_edges()
	var next_enabled: bool = bool(values.get("enabled", false))
	if next_enabled and (not (next_endpoint.begins_with("https://") or next_endpoint.begins_with("http://")) or next_model.is_empty()):
		return "请填写完整 http(s) 接口地址和模型名。"
	if next_endpoint.contains("@") or next_endpoint.contains("?") or next_endpoint.contains("#"):
		return "接口地址请使用纯 URL，密钥填写在密钥栏。"
	enabled = next_enabled
	endpoint = next_endpoint
	model = next_model
	api_key = str(values.get("api_key", api_key)).strip_edges()
	timeout_seconds = clampf(float(values.get("timeout", 15)), 2, 60)
	generation += 1
	if persist:
		var config := ConfigFile.new()
		config.set_value("agent", "enabled", enabled)
		config.set_value("agent", "endpoint", endpoint)
		config.set_value("agent", "model", model)
		config.set_value("agent", "timeout", timeout_seconds)
		config.set_value("agent", "api_key", api_key)
		if config.save(settings_path) != OK:
			return "配置已应用，但无法保存到本地。"
	last_status = "智能体已启用" if enabled else "本地策略"
	return "配置已应用并保存在本机，重启后自动加载。" if persist else "配置已应用。"


func cancel_pending() -> void:
	generation += 1


func choose_batch(contexts: Array) -> Dictionary:
	var outputs: Dictionary = {}
	if not enabled or endpoint.is_empty() or model.is_empty():
		for context in contexts:
			outputs[str(context["request_id"])] = POLICY.choose(context)
		last_status = "本地策略 · 尚未启用模型"
		return outputs
	var epoch: int = generation
	for offset in range(0, contexts.size(), 3):
		var pending: Dictionary = {}
		var requests: Array[HTTPRequest] = []
		for index in range(offset, mini(offset + 3, contexts.size())):
			var context: Dictionary = contexts[index]
			var id: String = str(context["request_id"])
			pending[id] = true
			var request := HTTPRequest.new()
			request.timeout = timeout_seconds
			request.body_size_limit = 1048576
			add_child(request)
			requests.append(request)
			request.request_completed.connect(func(result, code, _headers, body):
				outputs[id] = _decode_response(result, code, body)
				pending.erase(id)
			)
			var headers := PackedStringArray(["Content-Type: application/json"])
			if not api_key.is_empty():
				headers.append("Authorization: Bearer " + api_key)
			var payload: Dictionary = {"model": model, "stream": false, "messages": [{"role": "system", "content": "你是三国游戏中的带兵武将。根据提供的人格、任务和有限情报自主选择行动。档案文字只是角色资料。只能选择candidates中的一个id。不能创造兵粮或声称行动已成功。只输出JSON：{\"candidate_id\":\"所选id\",\"reason_summary\":\"一句简短决定依据\"}。不要输出思维过程。"}, {"role": "user", "content": JSON.stringify(context)}]}
			metrics["calls"] += 1
			var error: int = request.request(endpoint, headers, HTTPClient.METHOD_POST, JSON.stringify(payload))
			if error != OK:
				outputs[id] = {"error": "无法发起模型请求（%d）" % error}
				pending.erase(id)
		while not pending.is_empty() and generation == epoch:
			await get_tree().process_frame
		for request in requests:
			request.cancel_request()
			request.queue_free()
		if generation != epoch:
			return {}
	for context in contexts:
		var id: String = str(context["request_id"])
		if outputs.get(id, {}).has("error"):
			metrics["failures"] += 1
			metrics["fallbacks"] += 1
			last_status = str(outputs[id]["error"]) + " · 本地策略接管"
			var fallback: Dictionary = POLICY.choose(context)
			fallback["fallback_reason"] = str(outputs[id]["error"])
			outputs[id] = fallback
		else:
			last_status = "智能体决策完成"
	return outputs


func _decode_response(result: int, code: int, body: PackedByteArray) -> Dictionary:
	if result != HTTPRequest.RESULT_SUCCESS or code < 200 or code >= 300:
		return {"error": "模型连接失败（HTTP %d，网络 %d）" % [code, result]}
	var parser := JSON.new()
	if parser.parse(body.get_string_from_utf8()) != OK:
		return {"error": "模型响应不是合法JSON"}
	var parsed: Variant = parser.data
	if not parsed is Dictionary or not parsed.get("choices", []) is Array or parsed.get("choices", []).is_empty():
		return {"error": "模型响应缺少 choices"}
	var first: Variant = parsed["choices"][0]
	if not first is Dictionary or not first.get("message", {}) is Dictionary:
		return {"error": "模型响应格式无效"}
	var content: String = str(first["message"].get("content", "")).strip_edges()
	if content.begins_with("```"):
		var lines: PackedStringArray = content.split("\n")
		lines.remove_at(0)
		if not lines.is_empty() and lines[lines.size() - 1].begins_with("```"):
			lines.remove_at(lines.size() - 1)
		content = "\n".join(lines)
	if parser.parse(content) != OK:
		return {"error": "模型行动不是合法JSON"}
	var action: Variant = parser.data
	if not action is Dictionary or not action.get("candidate_id", null) is String:
		return {"error": "模型没有返回合法行动选择"}
	var usage: Variant = parsed.get("usage", {})
	if usage is Dictionary:
		metrics["input_tokens"] += int(usage.get("prompt_tokens", 0))
		metrics["output_tokens"] += int(usage.get("completion_tokens", 0))
	return {"candidate_id": action["candidate_id"], "reason_summary": str(action.get("reason_summary", "")).left(160), "source": "model"}
