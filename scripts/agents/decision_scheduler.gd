extends RefCounted

# Independent completion and bounded fair queue. Callbacks never execute actions.
var epoch := 0
var running := false
var ready: Dictionary = {}
var requested: Dictionary = {}
var discarded := 0
var last_batch_ms := 0
var queue: Array = []
var queued_requests := 0
var _inflight := 0
var _serial := 0
var _round := -1
var _submitted := 0
var _fair_cursor := 0
var concurrency := 6
var round_budget := 6
var queue_limit := 64
var _served: Dictionary = {}
var _dispatch_serial := 0

func clear() -> void:
	epoch += 1
	running = _inflight > 0
	ready.clear()
	requested.clear()
	queue.clear()
	queued_requests = 0
	_submitted = 0
	_round = -1
	_served.clear()
	_dispatch_serial = 0

func begin_round(round_now: int) -> void:
	if _round == round_now: return
	_round = round_now
	_submitted = 0
	for key in ready.keys():
		if round_now - int(ready[key]["tick"]) > int(ready[key].get("ttl",10)):
			ready.erase(key)
			discarded += 1
	for job in queue.duplicate():
		if _round - int(job["tick"]) > int(job["ttl"]):
			invalidate(job["key"])
			discarded += 1
	_pump()

func invalidate(key: String) -> void:
	requested.erase(key)
	ready.erase(key)
	queue = queue.filter(func(job): return job["key"] != key)
	queued_requests = queue.size()

func has_pending(key: String) -> bool:
	return requested.has(key) or ready.has(key)

func take(key: String, signature: String, tick: int) -> Dictionary:
	if not ready.has(key): return {}
	var proposal: Dictionary = ready[key]
	ready.erase(key)
	if proposal["signature"] != signature or tick - int(proposal["tick"]) > int(proposal.get("ttl",10)):
		discarded += 1
		return {}
	return proposal

func submit(contexts: Array, adapter: Node, signatures: Dictionary) -> bool:
	if contexts.is_empty() or not is_instance_valid(adapter): return false
	var accepted := false
	for property in adapter.get_property_list():
		if property["name"] == "concurrency": concurrency = clampi(int(adapter.get("concurrency")),1,6)
	var ordered: Array = contexts.duplicate()
	ordered.sort_custom(func(a,b): return int(_served.get(key_for(a),-1)) < int(_served.get(key_for(b),-1)))
	for context in ordered:
		if adapter.has_method("can_request_model") and not adapter.can_request_model(context): continue
		var key := key_for(context)
		if has_pending(key): continue
		if queue.size() >= queue_limit:
			discarded += 1
			continue
		_serial += 1
		var tick := int(context.get("battle_round",context.get("observation_revision",0)))
		var ttl := 2 if context.get("level","") == "unit" else 3 if context.get("level","") == "adviser" else 5 if context.get("level","") == "commander" else 10
		requested[key] = _serial
		queue.append({"key":key,"context":context.duplicate(true),"adapter":adapter,"signature":signatures.get(key,""),"token":_serial,"tick":tick,"ttl":ttl,"epoch":epoch,"queued_ms":Time.get_ticks_msec()})
		accepted = true
	queued_requests = queue.size()
	_pump()
	return accepted

func _pick() -> int:
	var lane: String = ["commander","unit","unit","adviser","unit","unit"][_fair_cursor % 6]
	_fair_cursor += 1
	var best := -1
	var oldest := 0
	var least_served := 1 << 30
	for i in range(queue.size()):
		var job: Dictionary = queue[i]
		var age := Time.get_ticks_msec() - int(job["queued_ms"])
		if job["context"].get("level","") == lane or age > 5000:
			var served := int(_served.get(job["key"],-1))
			if best < 0 or served < least_served or (served == least_served and age > oldest): best = i; oldest = age; least_served = served
	return maxi(0,best)

func _pump() -> void:
	while not queue.is_empty() and _inflight < concurrency and (_round < 0 or _submitted < round_budget):
		var job: Dictionary = queue.pop_at(_pick())
		queued_requests = queue.size()
		if not is_instance_valid(job["adapter"]) or not requested.has(job["key"]): continue
		_inflight += 1
		_dispatch_serial += 1
		_served[job["key"]] = _dispatch_serial
		if _served.size() > 1024:
			var oldest_key := str(_served.keys()[0])
			for key in _served:
				if int(_served[key]) < int(_served[oldest_key]): oldest_key = key
			_served.erase(oldest_key)
		_submitted += 1
		running = true
		_complete(job)
	running = _inflight > 0

func _complete(job: Dictionary) -> void:
	var started := Time.get_ticks_msec()
	var outputs: Dictionary = await job["adapter"].choose_batch([job["context"]])
	_inflight = maxi(0,_inflight-1)
	if int(job["epoch"]) != epoch:
		_pump()
		return
	last_batch_ms = Time.get_ticks_msec() - started
	var key := str(job["key"])
	if requested.get(key,-1) != job["token"]:
		discarded += 1
	else:
		requested.erase(key)
		ready[key] = {"context":job["context"],"result":outputs.get(job["context"]["request_id"],{}),"signature":job["signature"],"tick":job["tick"],"ttl":job["ttl"]}
	running = _inflight > 0
	_pump()

static func key_for(context: Dictionary) -> String:
	if context.has("actor_key"): return str(context["actor_key"])
	return "corps:" + str(context["corps"]["id"]) if context.get("level","") == "commander" else "army:" + str(context["army_id"])
