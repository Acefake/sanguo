extends SceneTree
## step() 热点内部的单项计时（只用于测量）。
##
##   godot --headless --path . --script res://tools/profile/micro_profile.gd -- [--days=12,25] [--repeat=20]
##
## 纯规则跑演示剧本到指定日，在当日状态上把热点阶段里的各个子项各重复调用 REPEAT 次，打印每次的平均微秒数：
## FactionLifecycle.maintain 及其子项、_observe_all 及其子项、context_for、ArmyCorps.commander_context、存档序列化。
## 这些子项在同一 tick 上重复调用结果相同（覆盖写同样的值），计时之后不再推进战役，所以不影响任何对比结果。

const Store = preload("res://scripts/core/game_state.gd")
const Lifecycle = preload("res://scripts/war/campaign/faction_lifecycle.gd")
const Corps = preload("res://scripts/war/campaign/army_corps.gd")
const Strategic = preload("res://scripts/war/campaign/strategic_ai.gd")

var repeat := 20


func _initialize() -> void: call_deferred("_run")


func _time(label: String, body: Callable) -> void:
	body.call()
	var started := Time.get_ticks_usec()
	for i in repeat: body.call()
	print("MICRO %-44s %10.1f us" % [label, float(Time.get_ticks_usec() - started) / repeat])


func _run() -> void:
	var days: Array = [12, 25]
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--days="): days = Array(arg.get_slice("=", 1).split(",")).map(func(d): return int(d))
		elif arg.begins_with("--repeat="): repeat = int(arg.get_slice("=", 1))
	var sandbox := Store.new()
	sandbox.persist_enabled = false
	sandbox._load_demo()
	var war = sandbox.war
	var reached := 0
	for target in days:
		while reached < target:
			await war.step(null)
			reached += 1
		_measure(sandbox, war, reached)
	sandbox.free()
	quit(0)


func _measure(sandbox: Node, war, day: int) -> void:
	var scenario: Dictionary = sandbox.scenario
	var armies: Array = war.active_armies()
	var factions: Array = scenario.get("factions", {}).keys()
	var generated := 0
	for officer in war.roster.officers.values(): if officer.get("generated", false): generated += 1
	print("MICRO_DAY %d places=%d factions=%d officers=%d generated=%d armies=%d corps=%d" % [day, scenario.get("places", {}).size(), factions.size(), war.roster.officers.size(), generated, armies.size(), war.state["corps"].size()])
	# FactionLifecycle.maintain（step 里调用两次）
	_time("Lifecycle.maintain", func(): Lifecycle.maintain(war))
	_time("  roster.ensure_factions", func(): war.roster.ensure_factions(scenario))
	_time("  generated officers duplicate(true)", func():
		for id in war.roster.officers:
			if war.roster.officers[id].get("generated", false): war.state["generated_officers"][id] = war.roster.officers[id].duplicate(true))
	_time("  available_officers × 每个势力", func():
		for faction in factions: war.available_officers(str(faction)))
	_time("  Strategic.lord_of × 每个势力", func():
		for faction in factions: Strategic.lord_of(war.roster, str(faction), war.state["officer_states"]))
	_time("  active_armies()", func(): war.active_armies())
	# _observe_all（step 里调用两次）
	_time("_observe_all", func(): war._observe_all())
	_time("  city_intel × 全部地点", func():
		for node in scenario.get("places", {}): war.city_intel(str(node)))
	var cities := {}
	for node in scenario.get("places", {}): cities[node] = war.city_intel(str(node))
	_time("  cities.duplicate(true) × 部队数", func():
		for army in armies: cities.duplicate(true))
	_time("  enemy_intel × 敌对部队对", func():
		for army in armies:
			for enemy in armies:
				if war.hostile(str(enemy["faction"]), str(army["faction"])): war.enemy_intel(enemy))
	# 决策上下文
	if not armies.is_empty():
		_time("context_for(第一支部队)", func(): war.context_for(armies[0]))
		_time("  intel.cities.values().duplicate(true)", func(): armies[0]["intel"]["cities"].values().duplicate(true))
	for corps in war.state["corps"].values():
		_time("Corps.commander_context(第一个军团)", func(): Corps.commander_context(war, corps))
		break
	# 寻路：route() = 排除表循环 + graph.path（缓存）；未命中时 _search 是整图 Dijkstra
	var nodes: Array = war.graph.places.keys()
	nodes.sort()
	var pairs: Array = []
	for i in 10: pairs.append([str(nodes[(i * 7) % nodes.size()]), str(nodes[(i * 13 + 5) % nodes.size()])])
	var faction: String = str(armies[0]["faction"]) if not armies.is_empty() else str(factions[0])
	_time("route() × 10 对（缓存命中）", func():
		for pair in pairs: war.route(faction, pair[0], pair[1]))
	_time("  排除表循环 can_cross × 全部地点 × 10", func():
		for pair in pairs:
			var excluded: Array = []
			for node in war.graph.places:
				if node != pair[0] and node != pair[1] and not war.can_cross(faction, str(node)): excluded.append(node))
	_time("graph._search × 10 对（未命中时的整图 Dijkstra）", func():
		for pair in pairs: war.graph._search(pair[0], pair[1], []))
	# Lifecycle.maintain 里逐城循环中的 active_armies().any(...)
	var guarded := 0
	for node in scenario.get("places", {}):
		if not war.state["garrison_commanders"].get(node, {}).is_empty(): guarded += 1
	print("MICRO_GUARDED_CITIES %d" % guarded)
	_time("export_state", func(): war.export_state())
	var payload := {"places": scenario.get("places", {}), "war": war.export_state()}
	_time("JSON.stringify(存档, \"\\t\")", func(): JSON.stringify(payload, "\t"))
	print("MICRO_SAVE_BYTES %d" % JSON.stringify(payload, "\t").length())
