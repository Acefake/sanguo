extends RefCounted
## 战场决策的提交点：每个 CampaignState 一个，把将领决策交给 ModelQueue，到提交点再决定用模型答案还是默认答案。
##
## 流程（08b §3.1）：
## 1. submit：习惯层答案已经由调用方当天执行；问模型的请求带上 commit_tick = 当前回合 + commit_delay_ticks
##    （默认下一日 step）交给 ModelQueue，立即返回。
## 2. 模型答案一到就进 ready（界面与测试可见），但只在 commit_tick 那一回合可取。
## 3. begin_round 到达 commit_tick：答案没到的请求作废，记“默认”；答案到了但当回合没被取走的，下一回合丢弃。
## 4. take：调用方给出今日上下文时，先复查合法性（同一行动仍在今日候选里），再请适配器按今日上下文
##    否决（AgentAdapter.veto 即 POLICY.veto），过关才采用，否则返回 {} 让调用方沿用默认。
## 每个结算过的请求都向 ModelQueue 写一行决策日志，记录最终采用值。
##
## 对外接口（submit / take / has_pending / invalidate / begin_round / clear / ready / requested /
## running / discarded / queued_requests / key_for）与旧版保持一致，只在本地的 unit_brain 等脚本照常可用。

const Runtime = preload("res://scripts/agents/ai_runtime.gd")
const Request = preload("res://scripts/agents/decision_request.gd")

var epoch := 0
var running := false
## key -> 已到的提案 {"context", "result", "signature", "tick", "commit_tick", "request_id", "entry", "adapter"}
var ready: Dictionary = {}
## key -> 在等的 Request
var requested: Dictionary = {}
var discarded := 0
## 已提交、还在 ModelQueue 里排队（未发出）的请求数。
var queued_requests: int:
	get: return requested.values().filter(func(request): return _models().is_queued(request.request_id)).size()
## key -> bool：情境是否仍有效（军队溃散、军团撤退后返回 false）。CampaignState.setup 注入。
var alive: Callable
var _round := -1
## request_id -> {"key", "request", "context", "adapter"}：等答案的请求，答案到达时按 id 找回。
var _waiting: Dictionary = {}
var _queue_node: Node


func clear() -> void:
	epoch += 1
	var open: Array = requested.values().map(func(request): return request.request_id) + ready.values().map(func(proposal): return str(proposal["request_id"]))
	requested.clear()
	ready.clear()
	_waiting.clear()
	for id in open: _models().cancel(id)
	_round = -1
	_refresh()


## 进入新回合：结算到期的提交点。
func begin_round(round_now: int) -> void:
	if _round == round_now: return
	_round = round_now
	if requested.is_empty() and ready.is_empty(): return
	_models().advance(round_now)
	for key in ready.keys():
		if int(ready[key]["commit_tick"]) >= round_now: continue
		_record(ready[key]["entry"], {}, "expired")
		ready.erase(key)
		discarded += 1
	for key in requested.keys():
		var request: Request = requested[key]
		if request.commit_tick > round_now: continue
		requested.erase(key)
		_waiting.erase(request.request_id)
		_models().take(request.request_id)
		_record(_entry(request), {}, "late")
	_refresh()


func invalidate(key: String) -> void:
	var id: String = requested[key].request_id if requested.has(key) else str(ready.get(key, {}).get("request_id", ""))
	requested.erase(key)
	ready.erase(key)
	_waiting.erase(id)
	if not id.is_empty(): _models().cancel(id)
	_refresh()


func has_pending(key: String) -> bool:
	return requested.has(key) or ready.has(key)


## 在提交点取提案。context_now 非空时复查：同一行动须仍在今日候选里，再过适配器的 veto；
## 复查后的提案 context 换成今日上下文、candidate_id 换成今日候选的 id。不过关返回 {}。
## context_now 为空（旧调用方）时沿用旧规则：情境指纹不一致即丢弃。
func take(key: String, signature: String, _tick: int, context_now: Dictionary = {}) -> Dictionary:
	if not ready.has(key) or int(ready[key]["commit_tick"]) > _round: return {}
	var proposal: Dictionary = ready[key]
	ready.erase(key)
	if alive.is_valid() and not alive.call(key):
		_record(proposal["entry"], proposal["result"], "stale")
		discarded += 1
		return {}
	var hash_match: bool = proposal["signature"] == signature
	var verdict := _admit(proposal, context_now) if not context_now.is_empty() else {"ok": hash_match, "reason": "context_changed"}
	if not verdict["ok"]:
		_record(proposal["entry"], proposal["result"], str(verdict["reason"]))
		discarded += 1
		return {}
	_record(proposal["entry"], proposal["result"], "adopted")
	if context_now.is_empty(): return proposal
	var admitted: Dictionary = proposal.duplicate()
	admitted["context"] = context_now
	admitted["result"] = proposal["result"].duplicate()
	admitted["result"]["candidate_id"] = verdict["candidate_id"]
	admitted["hash_match"] = hash_match
	return admitted


## 交给 ModelQueue，立即返回。同一 key 的新请求顶替旧请求。至少受理一个时返回 true。
func submit(contexts: Array, adapter: Node, signatures: Dictionary, defaults: Dictionary = {}) -> bool:
	if contexts.is_empty() or not is_instance_valid(adapter): return false
	var accepted := false
	for context in contexts:
		if adapter.has_method("can_request_model") and not adapter.can_request_model(context): continue
		var key := key_for(context)
		invalidate(key)
		# 浅拷贝：调用方之后改顶层键不影响请求。不做深拷贝（一批十几个上下文深拷贝要十几毫秒）；
		# 提交点复查用的是当日新建的上下文，不依赖这里的嵌套数据保持不变。
		var snapshot: Dictionary = context.duplicate()
		var request: Request = adapter.request_for(snapshot) if adapter.has_method("request_for") else _fixture_request(adapter, snapshot)
		accepted = true
		if request == null: continue
		request.actor = key
		request.commit_tick = _round + int(Runtime.config()["commit_delay_ticks"])
		request.context_hash = str(signatures.get(key, ""))
		if defaults.has(request.request_id): request.default = defaults[request.request_id]
		if alive.is_valid(): request.alive = alive.bind(key)
		requested[key] = request
		_waiting[request.request_id] = {"key": key, "request": request, "context": snapshot, "adapter": adapter}
		if not _models().settled.is_connected(_on_settled): _models().settled.connect(_on_settled)
		_models().submit(request)
	_refresh()
	return accepted


## 某个请求有了结论：答案放进 ready（只在提交点可取）；失败或超时留在 requested 里，到提交点按“没有可用答案”结算。
func _on_settled(request_id: String) -> void:
	if not _waiting.has(request_id): return
	var waiting: Dictionary = _waiting[request_id]
	_waiting.erase(request_id)
	var key: String = waiting["key"]
	var request: Request = waiting["request"]
	var adapter: Node = waiting["adapter"]
	if requested.get(key) != request: return
	if not _models().has_answer(request_id):
		if is_instance_valid(adapter) and adapter.has_method("record_failure"): adapter.record_failure(_models().failure_reason(request_id))
		return
	var answer: Dictionary = _models().take(request_id)
	if is_instance_valid(adapter) and adapter.has_method("resolve"): answer = adapter.resolve(waiting["context"], answer)
	ready[key] = {"context": waiting["context"], "result": answer, "signature": request.context_hash, "tick": request.commit_tick - int(Runtime.config()["commit_delay_ticks"]), "commit_tick": request.commit_tick, "request_id": request_id, "entry": _entry(request), "adapter": adapter}
	requested.erase(key)
	_refresh()


## 只实现 choose_batch 的适配器（测试夹具）：每个上下文都问，答案即最终结果。
func _fixture_request(adapter: Node, context: Dictionary) -> Request:
	var request := Request.new()
	request.request_id = str(context["request_id"])
	request.kind = str(context.get("level", "army"))
	request.real_deadline_ms = Runtime.deadline_ms(request.kind)
	request.value = Runtime.value(request.kind)
	request.owner = adapter.get_instance_id()
	if "concurrency" in adapter: request.lane_limit = int(adapter.get("concurrency"))
	var id := request.request_id
	request.fetch = func() -> Dictionary:
		var outputs: Dictionary = await adapter.choose_batch([context])
		return outputs.get(id, {})
	return request


## 复查：模型选的行动必须仍在今日候选里；模型给出的答案再交适配器按今日上下文否决（适配器没有 veto 时不否决）。
func _admit(proposal: Dictionary, context_now: Dictionary) -> Dictionary:
	var chosen := str(proposal["result"].get("candidate_id", ""))
	var action: Variant = null
	for candidate in proposal["context"].get("candidates", []):
		if str(candidate["id"]) == chosen: action = candidate["action"]
	if action == null: return {"ok": false, "reason": "illegal"}
	var adapter: Variant = proposal["adapter"]
	var judge: bool = str(proposal["result"].get("source", "")) == "model" and is_instance_valid(adapter) and adapter.has_method("veto")
	for candidate in context_now.get("candidates", []):
		if candidate["action"] != action: continue
		if judge and not adapter.veto(context_now, str(candidate["id"])).get("ok", true): return {"ok": false, "reason": "vetoed"}
		return {"ok": true, "candidate_id": str(candidate["id"])}
	return {"ok": false, "reason": "illegal"}


## 日志与统计用的请求摘要。
static func _entry(request: Request) -> Dictionary:
	return {"request_id": request.request_id, "kind": request.kind, "context_hash": request.context_hash, "commit_tick": request.commit_tick, "default": request.default}


## 一个请求在提交点的结论：写一行决策日志（最终采用值），并计入队列统计。
## outcome：adopted / late（提交点前没有可用答案：未到、失败或超时）/ expired / stale / illegal / vetoed / context_changed。
func _record(entry: Dictionary, model_answer: Dictionary, outcome: String) -> void:
	var adopted := outcome == "adopted"
	var final: Dictionary = model_answer if adopted else entry["default"]
	_models().log_decision({"request_id": entry["request_id"], "kind": entry["kind"], "context_hash": entry["context_hash"], "commit_tick": entry["commit_tick"], "round": _round, "default": entry["default"].get("candidate_id", ""), "model": model_answer.get("candidate_id", ""), "arrived_before_commit": outcome != "late", "outcome": outcome, "final": final.get("candidate_id", ""), "source": final.get("source", "")})
	_models().note_commit(adopted, outcome == "vetoed")


func _refresh() -> void:
	running = not requested.is_empty()


func _models() -> Node:
	if not is_instance_valid(_queue_node): _queue_node = Engine.get_main_loop().root.get_node("ModelQueue")
	return _queue_node


static func key_for(context: Dictionary) -> String:
	if context.has("actor_key"): return str(context["actor_key"])
	return "corps:" + str(context["corps"]["id"]) if context.get("level","") == "commander" else "army:" + str(context["army_id"])
