extends Node
## Autoload ModelQueue：所有模型请求的唯一出口。submit 立即返回，结果在提交点用 take 取。
##
## - 优先级 = value / max(1, commit_tick − now)，同分时先问被服务次数少的人，再按排队先后。
## - 每条通道（local / cloud）有并发上限；本地默认 1，云端读 ai_runtime.json。
## - 同一 slot（同一个人的同一类决策）的新请求顶替旧请求：排队中的直接替换，在飞的结果作废。
## - 出队时情境已失效（alive 返回 false）的请求直接丢弃。
## - 超过 real_deadline_ms 视为超时，槽位立即释放，迟到的结果丢弃。
## - 决策日志（每个提交点一行 JSON）也由这里统一写，只有一个写入者。
##
## 放成 Autoload 的原因：HTTPRequest 必须挂在场景树上；队列要比 CampaignState 活得久
## （重开战场会重建 CampaignState）；并发上限必须对整个进程生效，否则多个调用方会同时压一台本地模型。

const Runtime = preload("res://scripts/agents/ai_runtime.gd")
const Request = preload("res://scripts/agents/decision_request.gd")

## 请求有了结论（答案、失败、超时、丢弃都算）时发出，供等待者醒来。
signal settled(request_id: String)

var now_tick := 0
## 还没结论或结论还没被取走的请求：request_id -> Request
var _open: Dictionary = {}
var _queued: Array = []
## request_id -> 发出时刻（毫秒）
var _inflight: Dictionary = {}
## 请求对象 id -> 通道：已作废（顶替、取消、超时）但请求还在路上的。HTTP 请求不会因作废而中断，
## 模型服务仍在算它，所以通道槽位要等它真正返回才释放，否则本地模型会同时收到多于并发上限的请求。
var _draining: Dictionary = {}
## request_id -> 模型返回的原始结果
var _answers: Dictionary = {}
## slot -> 当前有效的 request_id（顶替看它）
var _slots: Dictionary = {}
var _served: Dictionary = {}
var _serial := 0
var _latencies: Array[int] = []
var _counts := {"submitted": 0, "calls": 0, "answers": 0, "failures": 0, "timeouts": 0, "superseded": 0, "stale": 0, "late": 0, "adopted": 0, "fallbacks": 0, "vetoes": 0}
## request_id -> 最近一次失败原因（模型报错原文或超时），供提交方按原因统计；只留最近 64 条。
var _failure_reasons: Dictionary = {}
var _log: FileAccess
var _log_path := ""


func _process(_delta: float) -> void:
	_expire_inflight()
	_pump()
	if _log != null: _log.flush()


## 推进队列的“当前游戏时刻”，影响优先级。
func advance(tick: int) -> void:
	now_tick = tick


## 入队并立即返回。同 slot 的旧请求（排队、在飞或答案未取）被顶替。
func submit(request: Request) -> void:
	var previous := str(_slots.get(request.slot(), ""))
	if not previous.is_empty(): _drop(previous, "superseded")
	_open[request.request_id] = request
	_slots[request.slot()] = request.request_id
	_queued.append(request)
	_counts["submitted"] += 1
	_pump()


## 在提交点取结果：已到返回原始答案，否则返回 {} 并把请求作废（迟到的结果不会再被采用）。
func take(request_id: String) -> Dictionary:
	if not _answers.has(request_id):
		_drop(request_id, "late")
		return {}
	var answer: Dictionary = _answers[request_id]
	_drop(request_id, "")
	return answer


## 结果是否已到（不取走）。
func has_answer(request_id: String) -> bool:
	return _answers.has(request_id)


## 请求还在排队、尚未发出。
func is_queued(request_id: String) -> bool:
	return _open.has(request_id) and _queued.has(_open[request_id])


## 请求还在排队或在飞。
func is_pending(request_id: String) -> bool:
	return _open.has(request_id) and not _answers.has(request_id)


## 等某个请求有结论再返回其结果（只给测试与玩家主动打开的场景用，主循环不调用）。
func wait(request_id: String) -> Dictionary:
	while is_pending(request_id):
		await settled
	return take(request_id)


## 某个请求失败的原因（模型报错原文或超时）；没有记录时给通用原因。
func failure_reason(request_id: String) -> String:
	return str(_failure_reasons.get(request_id, "模型没有在时限内给出可用答案"))


func _note_failure(request_id: String, reason: String) -> void:
	_failure_reasons[request_id] = reason
	if _failure_reasons.size() > 64: _failure_reasons.erase(_failure_reasons.keys()[0])


## 取消一个请求；结果若已到也一并丢弃。
func cancel(request_id: String) -> void:
	_drop(request_id, "")


## 取消某个提交方的全部请求。
func cancel_owner(owner: int) -> void:
	for request in _open.values():
		if request.owner == owner: _drop(request.request_id, "")


## 提交点结算后由调用方回报：采用了模型答案、用了默认、或被否决。
func note_commit(adopted: bool, vetoed: bool) -> void:
	_counts["adopted" if adopted else "fallbacks"] += 1
	if vetoed: _counts["vetoes"] += 1


## 写一行决策日志（最终采用值）。路径来自 ai_runtime.json，可用 set_log_path 改到测试目录。
func log_decision(entry: Dictionary) -> void:
	if _log == null: _open_log(str(Runtime.config()["decision_log"]))
	if _log != null: _log.store_line(JSON.stringify(entry))


func set_log_path(path: String) -> void:
	_log = null
	_open_log(path)


func log_path() -> String:
	return _log_path


## 计数与延迟分位（毫秒）。
func stats() -> Dictionary:
	var result := _counts.duplicate()
	var sorted := _latencies.duplicate()
	sorted.sort()
	result["queued"] = _queued.size()
	result["inflight"] = _inflight.size()
	result["p50_ms"] = _percentile(sorted, 0.5)
	result["p95_ms"] = _percentile(sorted, 0.95)
	return result


func reset_stats() -> void:
	for key in _counts: _counts[key] = 0
	_latencies.clear()


func queued_count() -> int:
	return _queued.size()


func inflight_count() -> int:
	return _inflight.size()


## 把请求从队列、在飞、答案和槽位里全部移除；reason 非空时计数。
func _drop(request_id: String, reason: String) -> void:
	if not _open.has(request_id): return
	var request: Request = _open[request_id]
	_open.erase(request_id)
	_queued.erase(request)
	if _inflight.has(request_id): _draining[request.get_instance_id()] = request.lane
	_inflight.erase(request_id)
	_answers.erase(request_id)
	if _slots.get(request.slot(), "") == request_id: _slots.erase(request.slot())
	if not reason.is_empty(): _counts[reason] += 1
	settled.emit(request_id)


func _lane_limit(request: Request) -> int:
	var limit := Runtime.concurrency(request.lane)
	return mini(limit, request.lane_limit) if request.lane_limit > 0 else limit


func _pump() -> void:
	var index := _pick()
	while index >= 0:
		var request: Request = _queued.pop_at(index)
		if request.still_alive(): _start(request)
		else: _drop(request.request_id, "stale")
		index = _pick()


## 可以出队的请求里优先级最高的那个；没有则 -1。
func _pick() -> int:
	var busy := {}
	for id in _inflight: busy[_open[id].lane] = int(busy.get(_open[id].lane, 0)) + 1
	for id in _draining: busy[_draining[id]] = int(busy.get(_draining[id], 0)) + 1
	var best := -1
	for index in range(_queued.size()):
		var request: Request = _queued[index]
		if int(busy.get(request.lane, 0)) >= _lane_limit(request): continue
		if best < 0 or _before(request, _queued[best]): best = index
	return best


func _before(a: Request, b: Request) -> bool:
	var pa := a.priority(now_tick)
	var pb := b.priority(now_tick)
	if not is_equal_approx(pa, pb): return pa > pb
	return int(_served.get(a.actor, -1)) < int(_served.get(b.actor, -1))


func _start(request: Request) -> void:
	_serial += 1
	_served[request.actor] = _serial
	_inflight[request.request_id] = Time.get_ticks_msec()
	_counts["calls"] += 1
	_run(request)


func _run(request: Request) -> void:
	var raw: Variant = await request.fetch.call()
	var id := request.request_id
	if _draining.erase(request.get_instance_id()): _pump()
	# 同一 request_id 可能已被新请求重用：只认本次发出的这个请求对象。
	if not _inflight.has(id) or _open.get(id) != request: return
	_latencies.append(Time.get_ticks_msec() - int(_inflight[id]))
	if _latencies.size() > int(Runtime.config()["latency_window"]): _latencies.pop_front()
	_inflight.erase(id)
	var answer: Dictionary = raw if raw is Dictionary else {}
	if answer.is_empty() or answer.has("error"):
		_note_failure(id, str(answer.get("error", "模型返回空答案")))
		_drop(id, "failures")
	else:
		_counts["answers"] += 1
		_answers[id] = answer
		settled.emit(id)
	_pump()


func _expire_inflight() -> void:
	var now := Time.get_ticks_msec()
	for id in _inflight.keys():
		if now - int(_inflight[id]) > _open[id].real_deadline_ms:
			_note_failure(id, "模型超过现实时限（%d 毫秒）未回复" % _open[id].real_deadline_ms)
			_drop(id, "timeouts")


func _open_log(path: String) -> void:
	_log_path = path
	_log = FileAccess.open(path, FileAccess.READ_WRITE) if FileAccess.file_exists(path) else FileAccess.open(path, FileAccess.WRITE)
	if _log == null:
		push_warning("无法写决策日志：" + path)
		return
	_log.seek_end()


static func _percentile(sorted: Array, q: float) -> int:
	if sorted.is_empty(): return 0
	return int(sorted[clampi(int(ceil(q * sorted.size())) - 1, 0, sorted.size() - 1)])
