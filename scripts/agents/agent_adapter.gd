extends Node

const Explain = preload("res://scripts/officers/officer_explain.gd")
const SETTINGS_PATH := "user://officer_agent.cfg"
var settings_path := SETTINGS_PATH
const POLICY = preload("res://scripts/agents/baseline_policy.gd")
var enabled := false
var model_mode := "commanders"
var endpoint := ""
var model := ""
var api_key := ""
var timeout_seconds := 15.0
var concurrency := 6
var decision_budget_seconds := 8.0
var disable_reasoning := true
var generation := 0
var metrics: Dictionary = {"calls": 0, "failures": 0, "fallbacks": 0, "vetoes": 0, "local_decisions": 0, "input_tokens": 0, "output_tokens": 0}
var last_status := "本地策略  尚未配置模型"


func load_settings() -> void:
	var config := ConfigFile.new()
	if config.load(settings_path) == OK:
		enabled = bool(config.get_value("agent", "enabled", false))
		model_mode = str(config.get_value("agent", "model_mode", "commanders"))
		endpoint = str(config.get_value("agent", "endpoint", ""))
		model = str(config.get_value("agent", "model", ""))
		api_key = str(config.get_value("agent", "api_key", ""))
		timeout_seconds = clampf(float(config.get_value("agent", "timeout", 15)), 2, 60)
		concurrency = clampi(int(config.get_value("agent", "concurrency", 6)), 1, 6)
		decision_budget_seconds = clampf(float(config.get_value("agent", "decision_budget", 8)), 2, 30)
		disable_reasoning = bool(config.get_value("agent", "disable_reasoning", true))
	last_status = "智能体已启用" if enabled and not endpoint.is_empty() and not model.is_empty() else "本地策略  尚未配置模型"


func configure(values: Dictionary, persist: bool = true) -> String:
	var next_endpoint: String = str(values.get("endpoint", "")).strip_edges()
	var next_model: String = str(values.get("model", "")).strip_edges()
	var next_enabled: bool = bool(values.get("enabled", false))
	if next_enabled and (not (next_endpoint.begins_with("https://") or next_endpoint.begins_with("http://")) or next_model.is_empty()):
		return "请填写完整 http(s) 接口地址和模型名。"
	if next_endpoint.contains("@") or next_endpoint.contains("?") or next_endpoint.contains("#"):
		return "接口地址请使用纯 URL，密钥填写在密钥栏。"
	enabled = next_enabled
	model_mode = str(values.get("model_mode",model_mode))
	if model_mode not in ["local","commanders","all"]: model_mode = "commanders"
	endpoint = next_endpoint
	model = next_model
	api_key = str(values.get("api_key", api_key)).strip_edges()
	timeout_seconds = clampf(float(values.get("timeout", 15)), 2, 60)
	concurrency = clampi(int(values.get("concurrency", concurrency)), 1, 6)
	decision_budget_seconds = clampf(float(values.get("decision_budget", decision_budget_seconds)), 2, 30)
	disable_reasoning = bool(values.get("disable_reasoning", disable_reasoning))
	generation += 1
	if persist:
		var config := ConfigFile.new()
		config.set_value("agent", "enabled", enabled)
		config.set_value("agent", "model_mode", model_mode)
		config.set_value("agent", "endpoint", endpoint)
		config.set_value("agent", "model", model)
		config.set_value("agent", "timeout", timeout_seconds)
		config.set_value("agent", "api_key", api_key)
		config.set_value("agent", "concurrency", concurrency)
		config.set_value("agent", "decision_budget", decision_budget_seconds)
		config.set_value("agent", "disable_reasoning", disable_reasoning)
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
			outputs[str(context["request_id"])] = _local_choice(context)
		last_status = "本地策略  尚未启用模型"
		return outputs
	var queue: Array = []
	for context in contexts:
		var id: String = str(context["request_id"])
		if not can_request_model(context):
			outputs[id] = _local_choice(context)
			continue
		if not POLICY.should_ask_model(context):
			outputs[id] = _local_choice(context)
			metrics["local_decisions"] += 1
			continue
		queue.append(context)
	if queue.is_empty():
		last_status = "本地策略  分差明确无需询问模型"
		return outputs
	var epoch: int = generation
	var deadline := Time.get_ticks_msec() + int(decision_budget_seconds * 1000)
	var rotate := int(queue[0].get("observation_revision", 0)) % queue.size()
	queue = queue.slice(rotate) + queue.slice(0, rotate)
	var pending: Dictionary = {}
	var requests: Array[HTTPRequest] = []
	var index := 0
	while (index < queue.size() or not pending.is_empty()) and generation == epoch and Time.get_ticks_msec() < deadline:
		while index < queue.size() and pending.size() < concurrency and Time.get_ticks_msec() < deadline:
			var context: Dictionary = queue[index]
			index += 1
			var id: String = str(context["request_id"])
			pending[id] = true
			var request := HTTPRequest.new()
			request.timeout = minf(timeout_seconds, maxf(0.1, (deadline - Time.get_ticks_msec()) / 1000.0))
			request.body_size_limit = 1048576
			add_child(request)
			requests.append(request)
			request.request_completed.connect(func(result, code, _headers, body):
				outputs[id] = _decode_response(result, code, body)
				pending.erase(id)
			)
			var headers := PackedStringArray(["Content-Type: application/json"])
			if not api_key.is_empty() and not is_ollama(): headers.append("Authorization: Bearer " + api_key)
			var payload: Dictionary = _build_payload(context)
			metrics["calls"] += 1
			var error: int = request.request(endpoint, headers, HTTPClient.METHOD_POST, JSON.stringify(payload))
			if error != OK:
				outputs[id] = {"error": "无法发起模型请求（%d）" % error}
				pending.erase(id)
		last_status = "将领决策 %d/%d  最多等待%.0f秒" % [outputs.size(), contexts.size(), decision_budget_seconds]
		await get_tree().process_frame
	for request in requests:
		request.cancel_request()
		request.queue_free()
	if generation != epoch: return {}
	for context in contexts:
		var id: String = str(context["request_id"])
		if not outputs.has(id): outputs[id] = {"error": "本日模型决策等待已达上限"}
	for context in contexts:
		var id: String = str(context["request_id"])
		if outputs.get(id, {}).has("error"):
			metrics["failures"] += 1
			metrics["fallbacks"] += 1
			last_status = str(outputs[id]["error"]) + "  本地策略接管"
			var fallback: Dictionary = _local_choice(context)
			fallback["fallback_reason"] = str(outputs[id]["error"])
			outputs[id] = fallback
		elif str(outputs[id].get("source", "")) == "model":
			var verdict: Dictionary = POLICY.veto(context, str(outputs[id].get("candidate_id", "")))
			if not verdict.get("ok", true):
				var local: Dictionary = _local_choice(context)
				local["vetoed"] = true
				local["fallback_reason"] = str(verdict.get("reason", "模型建议被守门否决"))
				local["rejected_model_reason"] = outputs[id].get("reason_summary", "")
				metrics["vetoes"] += 1
				outputs[id] = local
				last_status = "模型建议被守门否决  本地策略接管"
			else:
				last_status = "智能体决策完成"
	return outputs


func _local_choice(context: Dictionary) -> Dictionary:
	return preload("res://scripts/war/campaign/army_corps.gd").fallback(context) if context.get("level", "") == "commander" else POLICY.choose(context)

func _brief_candidate(candidate: Dictionary) -> Dictionary:
	var brief := {"id":candidate["id"], "action":candidate["action"], "forecast":_brief_forecast(candidate), "description":str(candidate.get("description", "")).left(80)}
	if candidate.has("canonical_plan"):
		brief["canonical_plan"] = candidate["canonical_plan"]
		brief["stage"] = candidate.get("stage","")
	return brief


func _model_candidates(context: Dictionary) -> Array:
	var candidates: Array = context.get("candidates", [])
	var gate: Dictionary = POLICY.weights().get("model_gate", {})
	var limit := int(gate.get("max_candidates", 8))
	if candidates.size() <= limit: return candidates
	var chosen: Array = []
	var seen := {}
	# Reserve slots for safe options before filling the remaining ranking slots.
	for candidate in candidates:
		if chosen.size() >= limit: break
		if str(candidate["id"]) in gate.get("always_keep", []):
			chosen.append(candidate)
			seen[str(candidate["id"])] = true
	for entry in POLICY.rank(context):
		if chosen.size() >= limit: break
		if not seen.has(str(entry["candidate"]["id"])):
			chosen.append(entry["candidate"])
			seen[str(entry["candidate"]["id"])] = true
	if chosen.is_empty(): return candidates.slice(0,limit)
	return chosen


func is_ollama() -> bool:
	return endpoint.trim_suffix("/").ends_with("/api/chat")

func _compact_context(context: Dictionary) -> Dictionary:
	if context.get("level","") in ["unit","adviser"]:
		var unit := {}
		for field in ["schema_version","level","actor_key","army_id","officer_id","battle_id","battle_round","actor_revision","command_revision","self","officer","task","authority","knowledge","coordination_view","current_plan","events","experience","supply_enabled"]: unit[field] = context.get(field)
		unit["candidates"] = _model_candidates(context).map(_brief_candidate)
		if context.get("level","") == "adviser": unit["weak_count"] = context.get("weak_count",0); unit["crisis"] = context.get("crisis",false)
		return unit
	var compact := {}
	for field in ["army_id", "observation_revision", "army", "returning", "objective", "operation", "battlefield", "current_action", "candidates", "orders", "retreat_assessment", "supply_enabled"]: compact[field] = context.get(field)
	var task: Dictionary = context.get("operation", {})
	compact["operation"] = {"role": task.get("role", ""), "support_id": task.get("support_id", ""), "suggested_target": task.get("suggested_target", ""), "plan_until": task.get("plan_until", 0)}
	compact["candidates"] = _model_candidates(context).map(_brief_candidate)
	if context.has("army") and context.get("candidates", []).size() > 1:
		var top: Array = []
		for entry in POLICY.rank(context).slice(0, 3): top.append({"id": entry["candidate"]["id"], "score": snappedf(float(entry["score"]), 0.1)})
		if not top.is_empty(): compact["ranking"] = top
	var officer: Dictionary = context.get("officer", {})
	# 核心定义、生效特性与同军团关系一起给模型，否则模型只看得到人格数值。
	compact["officer"] = Explain.model_profile(officer, context.get("members", []))
	var experience: Variant = context.get("experience", {})
	if experience is Dictionary and not experience.is_empty(): compact["experience"] = experience
	compact["allies"] = []
	for friend in context.get("allies", []):
		if friend.get("near_battle", false): compact["allies"].append({"id": friend["id"], "strength": friend["strength"], "cell": int(friend.get("tactical_cell", -1)), "role": friend.get("role", ""), "can_support": friend.get("can_support", false), "returning": friend.get("returning", false)})
	compact["enemies"] = []
	for enemy in context.get("enemies", []): compact["enemies"].append({"id": enemy["id"], "cell": int(enemy.get("tactical_cell", -1)), "strength_estimate": enemy.get("strength_estimate", 0), "routing": enemy.get("routing", false), "observed_at": enemy.get("observed_at", 0)})
	if context.get("level", "") == "commander":
		compact["level"] = "commander"
		compact["staff_advice"] = context.get("staff_advice", {})
		compact["battle_objective"] = context.get("battle_objective", {})
		compact["objective_text"] = context.get("objective_text", "")
		compact["siege"] = context.get("siege", {})
		compact["terrain"] = context.get("terrain", "plains")
		compact["unit_mix"] = context.get("unit_mix", {})
		compact["enemy_unit_mix_estimate"] = context.get("enemy_unit_mix_estimate", {})
		compact["deployment_age"] = context.get("deployment_age", 0)
		compact["corps"] = context["corps"].duplicate(true)
		compact["corps"]["units"] = context["corps"]["units"].map(func(unit): return {"id": unit["id"], "officer": unit["officer"], "strength": unit["strength"], "units": unit.get("units",{}), "siege_engines": unit.get("siege_engines",0), "morale": unit["morale"], "organization": unit["organization"], "fatigue": unit["fatigue"], "grain_days": unit["grain_days"], "task": unit["task"]["type"], "issued_at": unit["task"].get("issued_at", 0), "cell": unit["cell"], "returning": unit["returning"]})
		compact["corps"].erase("appointments")
		compact["members"] = context["members"].map(func(member): return {"id": member["id"], "name": member["name"], "position": member["position"], "skills": {"带兵": member["skills"].get("带兵", 50), "奇袭": member["skills"].get("奇袭", 50), "治军": member["skills"].get("治军", 50)}, "risk": member["personality"].get("风险承受", 50)})
	var board: Dictionary = context.get("local_map", {})
	if not board.is_empty() and context.get("level", "") != "commander": compact["map"] = {"grid": "global", "anchor": board.get("anchor", -1), "blocked": board.get("blocked", [])}
	return compact

func _brief_forecast(candidate: Dictionary) -> Dictionary:
	var forecast: Dictionary = candidate.get("forecast", {})
	var brief := {}
	for key in ["own_loss", "enemy_loss", "kill_ratio", "flank_risk", "eta_days", "grain_after", "escape_ready", "risk", "loss_interval", "eta_rounds", "uncertainty", "horizon"]:
		if forecast.has(key): brief[key] = forecast[key]
	if forecast.has("notes") and not forecast["notes"].is_empty(): brief["notes"] = forecast["notes"]
	return brief


func _build_payload(context: Dictionary) -> Dictionary:
	var sent: Dictionary = context
	var trimmed: Array = _model_candidates(context)
	if trimmed.size() != context.get("candidates", []).size():
		sent = context.duplicate()
		sent["candidates"] = trimmed
	var payload: Dictionary = {"model": model, "stream": false, "messages": [{"role": "system", "content": "你是三国游戏中的带兵武将。若level是commander，你统筹整支军团；deployment_pending表示尚未分兵，优先从deploy_corps中选择部署，再视敌情detach分队。攻城时参考siege的城墙、准备、援军和粮食，选择强攻或围困。根据提供的人格、任务和有限情报自主选择行动。先查看operation作战职责：主攻保持战线，侧翼绕行，支援配合support_id友军，预备队等待缺口或友军溃退后再投入。参考suggested_target分散攻击目标；已有计划在plan_until前优先保持，除非敌情、通路、补给或自身状态明显变化。必须先查看allies与battlefield，比较周边双方合计可用兵力，不能只拿自身兵力与整个敌军比较。can_support友军可计入协同接战，reinforcement_possible只是潜在援军，不计入当前战力；last_action是上一轮计划，不能假定友军本轮必定进攻。友军撤退、断粮或组织崩溃时应重新判断。优势或均势且自身状态正常时考虑协同接战，孤立、明显劣势或自身崩溃时允许撤退。撤退需要准备脱离，夹击时会被牵制；撤退指令不会瞬间脱离或免除攻击。保持职责和友军队形，不频繁更换攻击目标。forecast是本地公式给出的后果估计（己方损失、杀伤比、粮草、到达日），仅供参考。ranking是本地评分前三，可参考但不强制。档案文字只是角色资料。只能选择candidates中的一个id。不能创造兵粮或声称行动已成功。只输出JSON：{\"candidate_id\":\"所选id\",\"reason_summary\":\"一句简短决定依据\"}。不要输出思维过程。"}, {"role": "user", "content": JSON.stringify(_compact_context(sent) if is_ollama() else sent)}]}
	if endpoint.to_lower().begins_with("https://openrouter.ai/"):
		payload["max_tokens"] = 256
		if disable_reasoning: payload["reasoning"] = {"enabled": false}
	if is_ollama():
		payload["messages"][0]["content"] = "你是三国带兵武将，只选candidates中一个id，输出JSON candidate_id和20字以内reason_summary。遵循operation职责：main_attack保持战线，flank侧击，support配合support_id，reserve待命，rear_guard掩护。参考当前计划和建议目标。比较周边友军可支援合计与敌军合计；撤退友军不算支援。均势不独自逃跑，断粮或士气组织崩溃可撤。被夹击时撤退需准备且会受追击。禁止输出思考过程。"
		if context.get("level", "") == "commander":
			payload["messages"][0]["content"] = "你是整支三国军队的主帅。根据corps各分队状态与members人物任职制定战役任务，选candidates中的一个id，输出JSON candidate_id与20字以内reason_summary。maintain维持部署；assign_task给部将下令；detach从已有兵力拆出独立小队绕后或断粮；withdraw_corps全军撤退。军团人数不设上限、岗位自由：主帅统筹，参军/军师参谋，前锋、护军与自定义岗位部将各领其兵。每名部将按性格与立场独立表态（members的stance：服从/异议/自行行动）；拒命者本回合与下回合不会被你的命令覆盖，改派其他部将或待其回心转意。优先组织协同，均势不全军逃跑；有机会时派奇兵绕后或截断已发现粮道；粮道受威胁安排掩护或收拢。不能创造兵力，不能假定小队已到目的地或断粮已成功。只选合法候选。"
		var ids: Array = sent.get("candidates", []).map(func(candidate): return candidate["id"])
		payload["think"] = not disable_reasoning
		payload["keep_alive"] = "10m"
		payload["options"] = {"temperature": 0.2, "num_predict": 128, "num_ctx": 4096}
		payload["format"] = {"type": "object", "properties": {"candidate_id": {"type": "string", "enum": ids}, "reason_summary": {"type": "string"}}, "required": ["candidate_id", "reason_summary"], "additionalProperties": false}
	if context.get("level", "") == "commander":
		payload["messages"][0]["content"] = "你是整支三国军队的主帅。按corps分队状态和members人物任职统一下令。maintain保持部署，assign_task调动部将，detach从现有部队拆出真实兵力执行绕后或断粮，withdraw_corps全军撤退。军团人数不限、岗位自由：主帅统筹，参军/军师参谋，前锋、护军及自定义部将各领其兵。每名部将按性格与立场独立选择服从、异议或自行行动，members的stance为其当前立场；拒命者本回合与下回合不可覆盖，改派他人或待其回心转意。先看全军可用兵力、士气、组织、携粮和粮道，不能只看中军人数。均势不全军逃跑，有机会派奇兵，前军溃退安排掩护。不能凭空创造兵粮、假设小队已到目的地或断粮已成功。仅选candidates中的一个id，输出JSON candidate_id和20字以内reason_summary，不输出思考过程。"
	if context.get("level", "") == "commander" and not context.get("battle_objective", {}).is_empty():
		payload["messages"][0]["content"] += " 此战有据点控制目标：根据battle_objective的实际控制与争夺进度安排前锋争夺、护军支援，不因追击放弃据点。下令不等于已经占领。"
	if not context.get("supply_enabled", true):
		payload["messages"][0]["content"] = "你是三国游戏将领，只能选candidates中的一个id，输出JSON candidate_id和简短reason_summary。按operation职责和军令协同，比较周边可支援友军与已知敌军，不得泄露未知情报或凭空创造兵力。主帅在deployment_pending时优先deploy_corps部署，再用assign_task、detach、rotate_front协调前锋、侧翼、支援和预备队。攻城采用强攻，参考城墙、准备和援军。均势不要无故撤退，明显劣势或士气组织崩溃时可撤。当前粮草系统已移除，不考虑粮草、补给或截粮，不能以断粮理由撤退。不输出思考过程。"
		payload["messages"][1]["content"] = JSON.stringify(_without_supply(_compact_context(sent) if is_ollama() else sent))
	payload["messages"][0]["content"] += "先参考retreat_assessment；个别部队失利不等于全军撤退。疲惫前锋优先rotate_front轮换或归建，健康预备队保留接替。仅有真实友军脱离时安排rear_guard，不抽空最后一支正面战线。在途奇兵维持既定任务，勿重复拆分或逐日换令。"
	if context.get("level","") == "unit":
		payload["messages"][0]["content"] = "你是三国部队的带队武将。依据自己的能力、人格、有限情报与已送达的职责授权选择战术计划。主帅决定职责，你决定授权内的目标、站位、配合、局部后撤与整顿。current_plan是当前计划，knowledge中敌军都是带时效的估计。不得假定未确认支援会兑现；危机先由本地处理。不能改变职责、越过死守或追击范围，不能创建坐标、兵力、伤亡或第二次行动。只能选candidates中一个id，输出JSON candidate_id及一句简短reason_summary，不输出隐藏推理。"
		if not context.get("supply_enabled",true): payload["messages"][0]["content"] += "本战补给关闭，不考虑粮食危机。"
		payload["messages"][1]["content"] = JSON.stringify(_without_supply(_compact_context(sent)) if not context.get("supply_enabled",true) else _compact_context(sent))
	if context.get("level","") == "adviser":
		payload["messages"][0]["content"] = "你是独立思考的三国随军参谋。依据自己的性格、能力、收到的己方战报和有限敌情提出建议。authority仅允许建议，建议不等于军令，不能移动部队、制造兵力或宣布战果。只从candidates选择一个id，输出JSON candidate_id和一句reason_summary。"
		payload["messages"][1]["content"] = JSON.stringify(_compact_context(sent))
	return payload

func can_request_model(context: Dictionary) -> bool:
	if not enabled or endpoint.is_empty() or model.is_empty() or model_mode == "local": return false
	return model_mode == "all" or context.get("level","") not in ["unit","adviser"]


func _decode_response(result: int, code: int, body: PackedByteArray) -> Dictionary:
	if result != HTTPRequest.RESULT_SUCCESS or code < 200 or code >= 300:
		return {"error": "模型连接失败（HTTP %d，网络 %d）" % [code, result]}
	var parser := JSON.new()
	if parser.parse(body.get_string_from_utf8()) != OK:
		return {"error": "模型响应不是合法JSON"}
	var parsed: Variant = parser.data
	if is_ollama() and parsed is Dictionary and parsed.get("message") is Dictionary:
		parsed = {"choices": [{"message": parsed["message"]}], "usage": {"prompt_tokens": parsed.get("prompt_eval_count", 0), "completion_tokens": parsed.get("eval_count", 0)}}
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


func supports_background_decisions() -> bool:
	return true


func _without_supply(value: Variant) -> Variant:
	if value is Dictionary:
		var result := {}
		for key in value:
			if key in ["grain", "grain_days", "grain_after", "supply", "known_supplies"]: continue
			result[key] = _without_supply(value[key])
		return result
	if value is Array: return value.map(func(item): return _without_supply(item))
	return value
