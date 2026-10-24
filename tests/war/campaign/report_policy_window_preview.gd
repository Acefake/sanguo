extends SceneTree
func _initialize(): call_deferred("run")
func run() -> void:
	root.size = Vector2i(1280, 720)
	var store = root.get_node("GameState")
	store.persist_enabled = false
	store.prepare_battle_test()
	await store.war.step(null)
	var view = preload("res://scripts/war/ui/military_reports.gd").new()
	view.store = store
	root.add_child(view)
	view.show_summary()
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://orchestration/runs/2026-10-11-report-policy/report-policy-summary.png")
	view.show_review(str(store.war.active_armies("liu_bei")[0]["id"]))
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://orchestration/runs/2026-10-11-report-policy/report-policy-current-review.png")
	print("REPORT_POLICY_WINDOW_PREVIEW_OK")
	view.free()
	quit()
