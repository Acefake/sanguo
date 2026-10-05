extends RefCounted

# Model work is independent of the game-day clock. Only validated proposals
# are consumed at a later day boundary; never mutate simulation in a callback.
var epoch := 0
var running := false
var ready: Dictionary = {}
var requested: Dictionary = {}
var discarded := 0
var last_batch_ms := 0

func clear() -> void:
	epoch += 1
	running = false
	ready.clear()
	requested.clear()

func has_pending(key: String) -> bool:
	return requested.has(key) or ready.has(key)

func take(key: String, signature: String, tick: int) -> Dictionary:
	if not ready.has(key): return {}
	var proposal: Dictionary = ready[key]
	ready.erase(key)
	if proposal["signature"] != signature or tick - int(proposal["tick"]) > 10:
		discarded += 1
		return {}
	return proposal

func submit(contexts: Array, adapter: Node, signatures: Dictionary) -> bool:
	if running or contexts.is_empty(): return false
	running = true
	var generation := epoch
	for context in contexts: requested[key_for(context)] = true
	_complete(contexts.duplicate(true), adapter, signatures.duplicate(true), generation)
	return true

func _complete(contexts: Array, adapter: Node, signatures: Dictionary, generation: int) -> void:
	var started := Time.get_ticks_msec()
	var outputs: Dictionary = await adapter.choose_batch(contexts)
	if generation != epoch: return
	last_batch_ms = Time.get_ticks_msec() - started
	running = false
	for context in contexts:
		var key := key_for(context)
		requested.erase(key)
		ready[key] = {"context": context, "result": outputs.get(context["request_id"], {}), "signature": signatures[key], "tick": context["observation_revision"]}

static func key_for(context: Dictionary) -> String:
	return "corps:" + str(context["corps"]["id"]) if context.get("level", "") == "commander" else "army:" + str(context["army_id"])
