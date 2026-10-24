extends SceneTree

# TEMP PROBE: measure decision cadence during xiaopei battle. Delete after use.

class Probe extends Node:
	var model := "probe"
	var last_status := "probe"
	var metrics := {"fallbacks": 0}
	var calls := 0
	func choose_batch(contexts: Array) -> Dictionary:
		calls += 1
		var results := {}
		for context in contexts:
			var choice := "maintain"
			for candidate in context["candidates"]:
				if candidate["action"]["type"] == "engage":
					choice = candidate["id"]
					break
			results[context["request_id"]] = {"candidate_id": choice, "reason_summary": "probe engage", "source": "probe"}
		return results

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	var store: Node = root.get_node("GameState")
	store.persist_enabled = false
	store.prepare_battle_test()
	var probe := Probe.new()
	root.add_child(probe)
	var days := 14
	for day in range(days):
		var orders_before := {}
		for corps_id in store.war.state["corps"]:
			orders_before[corps_id] = store.war.state["corps"][corps_id]["orders"].size()
		await store.war.step(probe)
		var planned := []
		for corps_id in store.war.state["corps"]:
			if store.war.state["corps"][corps_id]["orders"].size() > orders_before[corps_id]:
				planned.append(corps_id)
		var states := []
		for army in store.war.active_armies():
			states.append("%s:%s%s%s" % [String(army["id"]).substr(4), String(army["status"]).substr(0, 1), "R" if army["returning"] else "", "B" if army["tactical"].get("blocked", false) else ""])
		print("day %02d tick=%d planned=%s calls_total=%d | %s" % [day + 1, store.war.state["tick"], str(planned), probe.calls, " ".join(states)])
		if store.war.active_armies("yuan_shao").is_empty() or store.war.active_armies("liu_bei").is_empty():
			print("battle ended")
			break
	print("PROBE_DONE calls_total=%d" % probe.calls)
	store.restore_battle_test()
	quit(0)
