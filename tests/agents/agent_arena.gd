extends SceneTree

# Agent arena: a manual evaluation harness for weight and prompt tuning. It is
# intentionally NOT part of the regression suite. It replays the fixed-seed
# Xiaopei battle end with the local policy and, when an endpoint/model is passed
# on the command line, with the model as well, then reports comparable metrics.
#
# Usage: godot --headless --path <repo> --script res://tests/agents/agent_arena.gd
#        godot --headless --path <repo> --script res://tests/agents/agent_arena.gd -- --endpoint http://host/v1/chat/completions --model name

const Adapter = preload("res://scripts/agents/agent_adapter.gd")
const Brain = preload("res://scripts/agents/unit_brain.gd")

var drain := false
var max_days := 120


func _initialize() -> void: call_deferred("run")


func run() -> void:
	var store: Node = root.get_node("GameState")
	store.persist_enabled = false
	var report: Dictionary = {"rounds": []}
	report["rounds"].append(await _round(store, null, "local"))
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var endpoint := ""
	var model := ""
	var model_mode := "commanders"
	for index in range(args.size()):
		if args[index] == "--endpoint" and index + 1 < args.size(): endpoint = args[index + 1]
		if args[index] == "--model" and index + 1 < args.size(): model = args[index + 1]
		if args[index] == "--model-mode" and index + 1 < args.size(): model_mode = args[index + 1]
		if args[index] == "--drain": drain = true
		if args[index] == "--days" and index + 1 < args.size(): max_days = maxi(1, int(args[index + 1]))
	if endpoint != "" and model != "":
		var adapter := Adapter.new()
		root.add_child(adapter)
		adapter.configure({"enabled": true, "endpoint": endpoint, "model": model, "decision_budget": 20, "model_mode": model_mode}, false)
		Brain.ask_stats.clear()
		report["rounds"].append(await _round(store, adapter, "model-" + model_mode))
		report["ask_stats"] = Brain.ask_stats.duplicate()
		adapter.queue_free()
	store.restore_battle_test()
	var file := FileAccess.open("res://docs/validation/agent-arena.json", FileAccess.WRITE)
	if file != null: file.store_string(JSON.stringify(report, "\t"))
	print("AGENT_ARENA ", JSON.stringify(report))
	quit(0)


func _round(store: Node, adapter, label: String) -> Dictionary:
	store.prepare_battle_test(true)
	var war = store.war
	var started := Time.get_ticks_msec()
	var days := 0
	for day in range(max_days):
		await war.step(adapter)
		days += 1
		if adapter != null and drain:
			var guard := 0
			var models: Node = root.get_node("ModelQueue")
			while (models.inflight_count() > 0 or models.queued_count() > 0) and guard < 1200:
				await process_frame
				guard += 1
		if war.state.get("battlefield", {}).has("winner"): break
	var sides: Dictionary = {}
	for army in war.state["armies"].values():
		var faction := str(army.get("faction", ""))
		if not sides.has(faction): sides[faction] = {"strength": 0, "dead": 0, "wounded": 0, "captured": 0}
		sides[faction]["strength"] += war.Combat.strength(army)
		for ledger in ["dead", "wounded", "captured"]: sides[faction][ledger] += int(army.get(ledger, 0))
	var retreats := 0
	for army in war.state["armies"].values():
		if bool(army.get("returning", false)) or str(army.get("outcome", "")) in ["撤退", "溃败撤退", "溃败"]: retreats += 1
	var decisions: int = war.state["decisions"].size()
	for corps in war.state["corps"].values(): decisions += corps.get("orders", []).size()
	return {
		"label": label, "days": days, "decisions": decisions, "retreats": retreats,
		"winner": war.state.get("battlefield", {}).get("winner", ""), "sides": sides,
		"vetoes": 0 if adapter == null else int(adapter.metrics.get("vetoes", 0)),
		"calls": 0 if adapter == null else int(adapter.metrics.get("calls", 0)),
		"fallbacks": 0 if adapter == null else int(adapter.metrics.get("fallbacks", 0)),
		"local_decisions": 0 if adapter == null else int(adapter.metrics.get("local_decisions", 0)),
		"mode": "local" if adapter == null else adapter.model_mode,
		"failure_reasons": {} if adapter == null else adapter.failure_reasons.duplicate(),
		"planner": {"inflight": root.get_node("ModelQueue").inflight_count(), "queued": root.get_node("ModelQueue").queued_count(), "ready": war.planner.ready.size(), "requested": war.planner.requested.size(), "discarded": war.planner.discarded, "submitted": int(root.get_node("ModelQueue").stats()["submitted"]), "round": war.planner._round},
		"ms": Time.get_ticks_msec() - started
	}
