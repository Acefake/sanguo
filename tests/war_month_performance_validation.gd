extends SceneTree

const Store = preload("res://scripts/game_state.gd")
const CitySkin = preload("res://scripts/city_ui_skin.gd")
var failures: Array[String] = []
var frames := 0
var last_frame_usec := 0
var max_frame_gap_usec := 0
var measuring := false
var advance_running := false
var watched_store: Node

class MeasuredStore extends "res://scripts/game_state.gd":
	var saves := 0
	var save_usec := 0
	var saved_while_busy := true
	func _ready() -> void:
		_load_demo()
	func _save() -> void:
		saves += 1
		saved_while_busy = saved_while_busy and busy
		var started := Time.get_ticks_usec()
		super._save()
		save_usec += Time.get_ticks_usec() - started

class MeasuredReports extends "res://scripts/war/military_reports.gd":
	var rebuilds := 0
	var rebuild_usec := 0
	func rebuild() -> void:
		rebuilds += 1
		var started := Time.get_ticks_usec()
		super.rebuild()
		rebuild_usec += Time.get_ticks_usec() - started

class MeasuredUI extends "res://scripts/war/campaign_ui.gd":
	var rebuilds: int:
		get: return reports_view.rebuilds if is_instance_valid(reports_view) else 0
		set(value):
			if is_instance_valid(reports_view): reports_view.rebuilds = value
	var rebuild_usec: int:
		get: return reports_view.rebuild_usec if is_instance_valid(reports_view) else 0
		set(value):
			if is_instance_valid(reports_view): reports_view.rebuild_usec = value
	func _create_reports_view() -> Control:
		return MeasuredReports.new()

class HoldAdapter extends Node:
	var model := "performance-fixture"
	var last_status := "本地性能测试"
	var metrics := {"fallbacks": 0}
	func choose_batch(contexts: Array) -> Dictionary:
		var results := {}
		for context in contexts:
			results[context["request_id"]] = {"candidate_id": "hold", "reason_summary": "性能测试驻守", "source": "baseline"}
		return results

func _initialize() -> void:
	process_frame.connect(_frame)
	call_deferred("_run")

func _frame() -> void:
	if measuring:
		frames += 1
		var now := Time.get_ticks_usec()
		max_frame_gap_usec = maxi(max_frame_gap_usec, now - last_frame_usec)
		last_frame_usec = now
		if advance_running:
			_check(watched_store.busy, "月度推进中途解除了操作锁")
			if not watched_store.busy: return
			var date: String = watched_store.date_text()
			var tick: int = watched_store.war.state["tick"]
			await watched_store.advance_day()
			await watched_store.advance_to_month()
			_check(watched_store.date_text() == date and int(watched_store.war.state["tick"]) == tick, "重复推进请求改变了正在结算的日期")
			_check(watched_store.action_error("luoyang", "recruit").contains("稍候"), "推进过程中仍允许执行城池命令")

func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		push_error(message)

func _fixture() -> MeasuredStore:
	var store := MeasuredStore.new()
	store.persist_enabled = false
	store.save_path = "user://war-month-perf-%d.json" % Time.get_ticks_usec()
	root.add_child(store)
	store.agent = HoldAdapter.new()
	store.add_child(store.agent)
	for city in store.scenario["places"].values():
		city["faction"] = "liu_bei"
	var home: Dictionary = store.city_state("luoyang")
	home["garrison"] = 100000
	home["grain"] = 100000
	home["units"] = {"infantry": 100000, "archers": 0, "cavalry": 0}
	store.war.rules["carry_days"] = 90
	var officers: Array = store.war.available_officers("liu_bei").slice(0, 6)
	for officer in officers:
		var preview: Dictionary = store.war.preview_dispatch("luoyang", "xiangping", officer["id"])
		_check(bool(preview["ok"]), "性能场景无法动员测试军队")
		store.war._mobilize(preview)
	return store

func _run() -> void:
	# All saves belong to a throwaway fixture; never alter the player's campaign or model settings.
	root.get_node("GameState").persist_enabled = false
	var baseline_only := OS.get_cmdline_user_args().has("--baseline-only")
	var expected: Dictionary = {}
	if not baseline_only:
		_check(CitySkin.font() == CitySkin.font(), "界面刷新仍重复创建系统字体")
		var daily := _fixture()
		for index in range(30): await daily.advance_day()
		expected = {"war": daily.war.export_state(), "places": daily.scenario["places"].duplicate(true), "chronicles": daily.chronicles.duplicate(true)}
		daily.queue_free()
	await _measure("six-armies", _fixture(), baseline_only, expected)
	if FileAccess.file_exists(Store.SAVE_PATH):
		var saved := MeasuredStore.new()
		saved.persist_enabled = false
		root.add_child(saved)
		saved._load_save()
		saved.save_path = "user://war-month-perf-%d.json" % Time.get_ticks_usec()
		await _measure("saved-campaign-copy", saved, baseline_only)
	if not baseline_only:
		var idle := MeasuredStore.new()
		idle.persist_enabled = false
		idle.save_path = "user://war-month-perf-%d.json" % Time.get_ticks_usec()
		root.add_child(idle)
		await _measure("idle-month", idle, false)
		var urgent := _fixture()
		urgent.war._report(urgent.war.active_armies()[0], "重要军情测试", "暂停月度推进", true)
		await _measure("urgent-stop", urgent, false)
	if failures.is_empty():
		print("WAR_MONTH_PERFORMANCE_OK" if not baseline_only else "WAR_MONTH_BASELINE_OK")
	quit(0 if failures.is_empty() else 1)

func _measure(label: String, store: MeasuredStore, baseline_only: bool, expected: Dictionary = {}) -> void:
	var ui := MeasuredUI.new()
	ui.store = store
	root.add_child(ui)
	ui.show_reports()
	await process_frame
	await process_frame
	ui.rebuilds = 0
	ui.rebuild_usec = 0
	store.saves = 0
	store.save_usec = 0
	store.persist_enabled = true
	var observations := {"changes": 0}
	store.campaign_changed.connect(func():
		observations["changes"] += 1
	)
	frames = 0
	max_frame_gap_usec = 0
	last_frame_usec = Time.get_ticks_usec()
	measuring = true
	advance_running = true
	watched_store = store
	var started := Time.get_ticks_usec()
	await store.advance_to_month()
	advance_running = false
	var elapsed := Time.get_ticks_usec() - started
	var advance_frames := frames
	await process_frame
	await process_frame
	measuring = false
	print("MONTH_PERF ", label, " ", JSON.stringify({"elapsed_ms": elapsed / 1000.0, "advance_frames": advance_frames, "max_frame_gap_ms": max_frame_gap_usec / 1000.0, "saves": store.saves, "save_ms": store.save_usec / 1000.0, "report_rebuilds": ui.rebuilds, "rebuild_ms": ui.rebuild_usec / 1000.0, "changes": observations["changes"]}))
	if not baseline_only:
		_check(store.saves == 1 and store.saved_while_busy, "月度推进应在结束或重要军情暂停时保持操作锁并只保存一次")
		_check(observations["changes"] <= 2, "月度推进不应每天反复发布完整界面刷新")
		if label == "six-armies":
			_check(advance_frames >= 2, "本地AI月度结算仍在单帧阻塞")
			_check(ui.rebuilds <= 2, "月度推进仍反复重建军报界面")
			_check(store.month == 10 and store.day == 1, "月度性能优化遗漏日期结算")
			_check(store.war.export_state() == expected["war"] and store.scenario["places"] == expected["places"] and store.chronicles == expected["chronicles"], "月度分帧结算与逐日推进的兵粮、决策或随机状态不一致")
		if label == "idle-month":
			_check(store.month == 10 and store.day == 1 and store.war.state["tick"] == 30, "空闲月度快进遗漏日期结算")
		if label == "urgent-stop":
			_check(store.month == 9 and store.day == 2 and store.war.state["tick"] == 1 and store.war.urgent_event, "重要军情没有及时暂停月度推进")
		var builds: int = ui.rebuilds
		ui.refresh()
		ui.show_reports()
		_check(ui.rebuilds == builds, "未变化的军报界面仍重复重建")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(store.save_path))
	ui.queue_free()
	store.queue_free()
	await process_frame
