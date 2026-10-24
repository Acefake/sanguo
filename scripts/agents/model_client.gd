extends RefCounted
## 模型传输层：Ollama /api/chat 与 OpenAI 兼容 /chat/completions 两种协议，含 OpenRouter 的参数适配。
##
## 只管“怎么发、怎么收”：请求体的协议字段、请求头、超时、把响应解码成 {"candidate_id", "reason_summary"}。
## 发什么（系统提示词、上下文裁剪）和收到后怎么用（否决、兜底）在 agent_adapter.gd。
## 除 send 外都是纯函数，可脱离场景树测试。

const BODY_LIMIT := 1048576


static func is_ollama(endpoint: String) -> bool:
	return endpoint.trim_suffix("/").ends_with("/api/chat")


static func is_openrouter(endpoint: String) -> bool:
	return endpoint.to_lower().begins_with("https://openrouter.ai/")


## 本机服务走 local 通道（默认并发 1），其余走 cloud。
static func lane(endpoint: String) -> String:
	var host := endpoint.get_slice("://", 1).get_slice("/", 0)
	host = host.get_slice("]", 0).trim_prefix("[") if host.begins_with("[") else host.get_slice(":", 0)
	return "local" if host.to_lower() in ["127.0.0.1", "localhost", "::1", "0.0.0.0"] else "cloud"


## 协议字段补进请求体。choices 是允许的候选 id，Ollama 用它生成结构化输出约束。
static func chat_payload(endpoint: String, model: String, messages: Array, choices: Array, disable_reasoning: bool) -> Dictionary:
	var payload := {"model": model, "stream": false, "messages": messages}
	if is_openrouter(endpoint):
		payload["max_tokens"] = 256
		if disable_reasoning: payload["reasoning"] = {"enabled": false}
	if is_ollama(endpoint):
		payload["think"] = not disable_reasoning
		payload["keep_alive"] = "10m"
		payload["options"] = {"temperature": 0.2, "num_predict": 128, "num_ctx": 8192}
		payload["format"] = {"type": "object", "properties": {"candidate_id": {"type": "string", "enum": choices}, "reason_summary": {"type": "string"}}, "required": ["candidate_id", "reason_summary"], "additionalProperties": false}
	return payload


static func headers(endpoint: String, api_key: String) -> PackedStringArray:
	var result := PackedStringArray(["Content-Type: application/json"])
	if not api_key.is_empty() and not is_ollama(endpoint): result.append("Authorization: Bearer " + api_key)
	return result


## 发一次请求并等待结果（协程）。host 是挂 HTTPRequest 的节点；超时由 HTTPRequest 自己执行。
static func send(host: Node, endpoint: String, api_key: String, payload: Dictionary, timeout_seconds: float) -> Dictionary:
	var request := HTTPRequest.new()
	request.timeout = maxf(0.1, timeout_seconds)
	request.body_size_limit = BODY_LIMIT
	host.add_child(request)
	var error := request.request(endpoint, headers(endpoint, api_key), HTTPClient.METHOD_POST, JSON.stringify(payload))
	if error != OK:
		request.queue_free()
		return {"error": "无法发起模型请求（%d）" % error}
	var completed: Array = await request.request_completed
	request.queue_free()
	return decode(endpoint, int(completed[0]), int(completed[1]), completed[3])


## 把 HTTP 响应解码成一次选择；失败返回 {"error": 原因}。成功时附 usage（输入/输出 token）。
static func decode(endpoint: String, result: int, code: int, body: PackedByteArray) -> Dictionary:
	if result != HTTPRequest.RESULT_SUCCESS or code < 200 or code >= 300:
		# 带上响应体开头，便于看出是鉴权、限流还是模型名错误。
		return {"error": "模型连接失败（HTTP %d，网络 %d）%s" % [code, result, body.get_string_from_utf8().left(160)]}
	# 用 JSON 实例解析：模型输出不合法是常见情况，JSON.parse_string 会把它当引擎错误打印。
	var parser := JSON.new()
	if parser.parse(body.get_string_from_utf8()) != OK:
		return {"error": "模型响应不是合法JSON"}
	var parsed: Variant = parser.data
	if is_ollama(endpoint) and parsed is Dictionary and parsed.get("message") is Dictionary:
		parsed = {"choices": [{"message": parsed["message"]}], "usage": {"prompt_tokens": parsed.get("prompt_eval_count", 0), "completion_tokens": parsed.get("eval_count", 0)}}
	if not parsed is Dictionary or not parsed.get("choices", []) is Array or parsed.get("choices", []).is_empty():
		return {"error": "模型响应缺少 choices"}
	var first: Variant = parsed["choices"][0]
	if not first is Dictionary or not first.get("message", {}) is Dictionary:
		return {"error": "模型响应格式无效"}
	if parser.parse(_strip_fence(str(first["message"].get("content", "")).strip_edges())) != OK:
		return {"error": "模型行动不是合法JSON"}
	var action: Variant = parser.data
	if not action is Dictionary or not action.get("candidate_id", null) is String:
		return {"error": "模型没有返回合法行动选择"}
	var usage: Variant = parsed.get("usage", {})
	var tokens := {"input": int(usage.get("prompt_tokens", 0)), "output": int(usage.get("completion_tokens", 0))} if usage is Dictionary else {"input": 0, "output": 0}
	return {"candidate_id": action["candidate_id"], "reason_summary": str(action.get("reason_summary", "")).left(160), "source": "model", "usage": tokens}


static func _strip_fence(content: String) -> String:
	if not content.begins_with("```"): return content
	var lines: PackedStringArray = content.split("\n")
	lines.remove_at(0)
	if not lines.is_empty() and lines[lines.size() - 1].begins_with("```"): lines.remove_at(lines.size() - 1)
	return "\n".join(lines)
