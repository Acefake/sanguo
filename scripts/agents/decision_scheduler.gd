extends RefCounted

# Model work is independent of the game-day clock. Only validated proposals
# are consumed at a later day boundary; never mutate simulation in a callback.
# One batch runs at a time; later submits queue instead of being dropped, so a
# corps request can never starve the free armies that submit on the same frame.
var epoch := 0
var running := false
var ready: Dictionary = {}
var requested: Dictionary = {}
var discarded := 0
var last_batch_ms := 0
var queue: Array = []
var queued_requests := 0

func clear() -> void:
	epoch += 1
	running = false
	ready.clear()
	requested.clear()
	queue.clear()
	queued_requests = 0

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
	if contexts.is_empty(): return false
	var generation := epoch
	# Mark the request before dispatching, so a queued batch is not resubmitted
	# by the next day boundary while it is still waiting for a slot.
	for context in contexts: requested[key_for(context)] = true
	if running:
		queue.append({"contexts": contexts.duplicate(true), "adapter": adapter, "signatures": signatures.duplicate(true), "generation": generation})
		queued_requests += contexts.size()
		return true
	running = true
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
		ready[key] = {"context": context, "result": outputs.get(context["request_id"], {}), "signature": signatures.get(key, ""), "tick": context["observation_revision"]}
	while not queue.is_empty():
		var batch: Dictionary = queue.pop_front()
		if int(batch["generation"]) != epoch:
			# The campaign was reset while this batch waited; drop it loudly.
			discarded += batch["contexts"].size()
			for context in batch["contexts"]: requested.erase(key_for(context))
			continue
		queued_requests -= batch["contexts"].size()
		submit(batch["contexts"], batch["adapter"], batch["signatures"])
		return

static func key_for(context: Dictionary) -> String:
	return "corps:" + str(context["corps"]["id"]) if context.get("level", "") == "commander" else "army:" + str(context["army_id"])