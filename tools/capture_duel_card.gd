extends SceneTree
func _initialize() -> void:
	call_deferred("capture")
func capture() -> void:
	root.size = Vector2i(2048, 1194)
	var scene = load("res://scenes/duel_preview.tscn").instantiate()
	root.add_child(scene)
	while scene.presentation == null:
		await process_frame
	var overlay = scene.presentation
	var store = root.get_node("GameState")
	var army_world = store.war_presentation
	var battle_clock: float = army_world.animation_time
	var day_before: int = store.day
	var old_pause: bool = store.time_paused
	store.time_paused = true
	overlay.demo = false
	await create_timer(1.2).timeout
	assert(overlay.elapsed >= 1.0 and overlay.card.elapsed < overlay.card.result_at, "Round playback continues on its real-time clock while the battle is paused")
	assert(is_equal_approx(army_world.animation_time, battle_clock), "Battle clock must honor the explicit user pause")
	assert(store.day == day_before)
	store.time_paused = old_pause
	overlay.set_process(false)
	var end: float = overlay.combat_seconds
	var strike: float = 2.0 + (end - 2.0) / maxf(overlay.active_record.get("rounds", []).size(), 1) * 0.22
	for pair in [[strike, "duel-card-strike"], [5.0, "duel-card"], [end + 3.0, "duel-card-result"]]:
		overlay.elapsed = pair[0]
		overlay._update_stage()
		await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("res://docs/validation/gold-duel/" + pair[1] + ".png")
	assert((overlay.card.get_global_transform() * Vector2(310, 225)).is_equal_approx(overlay.get_viewport().get_visible_rect().size * 0.5))
	overlay.elapsed = end - 0.01
	overlay._update_stage()
	assert(overlay.visible)
	overlay.elapsed = end
	overlay._update_stage()
	assert(overlay.visible)
	assert(not overlay.continue_button.disabled)
	overlay.close()
	assert(not overlay.visible)
	print("DUEL_CARD_CAPTURE_OK centered, round playback, explicit pause respected, no result countdown")
	quit()
