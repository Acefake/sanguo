extends SceneTree

const Overlay = preload("res://scripts/war/duel_gold_presentation.gd")
var failures: Array[String] = []

class VisibleNotice extends Node:
	var presenting := false
	var duel_checks := 0
	func duel_active() -> bool:
		duel_checks += 1
		return false
	func begin_day(_before: Dictionary) -> void:
		pass

func _initialize() -> void:
	call_deferred("run")

func check(ok: bool, message: String) -> void:
	if not ok:
		failures.append(message)
		push_error(message)

func run() -> void:
	var store = root.get_node("GameState")
	store.persist_enabled = false
	store.agent.enabled = false
	var overlay = Overlay.new()
	root.add_child(overlay)
	var left := {"name":"测试甲"}
	var right := {"name":"测试乙"}
	var outcome := {"result":"victory", "winner":1, "max_hp":[120.0,127.0], "initial_hp":[120.0,127.0], "final_hp":[0.0,63.0], "rounds":[{"hp_a":0.0,"hp_b":63.0,"damage_a":120.0,"damage_b":64.0}]}
	overlay.present_record(outcome, left, right, null, null)
	check(overlay.card.elapsed < overlay.card.result_at, "Combat must start with round playback")
	check(not overlay.continue_button.visible, "Do not show the result button before playback ends")
	check(is_equal_approx(overlay.card.health_at(1, overlay.card.playback()), 127.0), "Playback starts at initial HP")
	overlay.close()
	check(overlay.visible, "Combat cannot be dismissed before its rounds finish")
	overlay.elapsed = float(overlay.card.timeline[0]["at"]) + 0.35
	overlay._update_stage()
	check(is_equal_approx(overlay.card.health_at(1, overlay.card.playback()), 63.0), "Round damage must be presented at impact")
	overlay.elapsed = overlay.combat_end_at - 0.01
	overlay._update_stage()
	check(not overlay.continue_button.visible, "Still playing immediately before the final event ends")
	overlay.elapsed = overlay.combat_end_at
	overlay._update_stage()
	check(overlay.continue_button.visible and not overlay.continue_button.disabled, "No six-second wait after playback")
	check(is_equal_approx(overlay.card.health_at(1, overlay.card.playback()), 63.0), "Final HP follows completed playback")
	overlay.close()
	check(not overlay.visible, "Result is dismissible at the exact playback end")
	# Seed heavyweight presentation state so refusal must prove it does not rebuild it.
	var old_faces: Array = overlay.card.faces.duplicate()
	var old_timeline: Array = overlay.card.timeline.duplicate(true)
	overlay.present_record({"result":"refused", "winner":-1, "rounds":[]}, left, right, null, null)
	check(overlay.card.refused and overlay.card.visible, "Refusal uses the material dialogue")
	check(overlay.mask.mouse_filter == Control.MOUSE_FILTER_IGNORE, "Refusal must not block map input")
	check(overlay.card.faces == old_faces and overlay.card.timeline == old_timeline, "Refusal must skip portrait and timeline processing")
	check(not overlay.continue_button.visible, "Refusal must not show a result button")
	overlay.elapsed = overlay.REFUSAL_SECONDS
	overlay._update_stage()
	check(not overlay.visible, "Refusal notice expires automatically")
	# Refusal after a result must not leak refusal layout into the next result.
	overlay.present_record(outcome, left, right, null, null)
	check(not overlay.card.refused, "Normal results reset the refusal layout")
	overlay.elapsed = overlay.combat_end_at
	overlay._update_stage()
	overlay.close()
	# A nonblocking refusal notice must not gate the real campaign turn.
	store.prepare_battle_test(true)
	var notice := VisibleNotice.new()
	root.add_child(notice)
	store.war_presentation = notice
	var day_before: int = store.day
	var completed := [false]
	create_timer(15.0).timeout.connect(func():
		if not completed[0]:
			push_error("Campaign turn blocked on a visible duel report")
			quit(1))
	await store._advance_one_day()
	completed[0] = true
	check(store.day != day_before, "Campaign progresses with an open report")
	check(notice.duel_checks > 0, "Campaign checks playback state without blocking on a refusal")
	store.war_presentation = null
	notice.queue_free()
	print("DUEL_PLAYBACK_NO_WAIT_VALIDATION failures=", failures.size())
	quit(0 if failures.is_empty() else 1)
