extends SceneTree

class TestStore extends "res://scripts/game_state.gd":
	var saves := 0
	var inject_urgent := false
	func _ready() -> void: _load_demo()
	func _save() -> void: saves += 1
	func _advance_one_day() -> String:
		var result: String = await super._advance_one_day()
		if inject_urgent: war.urgent_event = true
		return result

var failures: Array[String] = []

func _initialize() -> void: call_deferred("_run")

func check(value: bool, message: String) -> void:
	if not value:
		failures.append(message)
		push_error(message)

func _run() -> void:
	root.get_node("GameState").persist_enabled = false
	var store := TestStore.new()
	store.persist_enabled = false
	root.add_child(store)
	store.day = 1
	await store.advance_turn()
	check(store.day == 11 and store.turn_days_done == 10 and store.saves == 1, "上旬没有十日结算或重复保存")
	check(not store.busy and store.time_phase == "report", "旬末没有回到可下令的汇报阶段")
	store.day = 18
	await store.advance_turn()
	check(store.day == 28 and store.turn_days_done == 10, "旬中开始没有完整推进十天")
	store.day = 21
	var old_month: int = store.month
	await store.advance_turn()
	check(store.day == 1 and store.month != old_month and store.turn_days_done == 10, "下旬没有正确跨月")
	check(store.saves == 3, "每旬保存次数错误")
	store.day = 23
	store.inject_urgent = true
	await store.advance_turn()
	check(store.day == 3 and store.turn_days_done == 10 and store.saves == 4, "军情或月末截断了十日执行")
	store.queue_free()
	if failures.is_empty(): print("WAR_TURN_TIME_OK: fixed ten days, mid-month start, month rollover, urgent reports do not truncate, report phase and one save")
	quit(0 if failures.is_empty() else 1)
