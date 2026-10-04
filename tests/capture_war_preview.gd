extends SceneTree


func _initialize() -> void:
	call_deferred("_capture")


func _capture() -> void:
	var campaign: Node = root.get_node("GameState")
	campaign.persist_enabled = false
	campaign._load_demo()
	campaign.year = 191
	campaign.month = 9
	campaign.day = 1
	campaign.agent.configure({"enabled": false}, false)
	var home: Dictionary = campaign.city_state("luoyang")
	home["faction"] = "liu_bei"
	home["garrison"] = 10000
	home["grain"] = 10000
	home["units"] = {"infantry": 8000, "archers": 1500, "cavalry": 500}
	var target: Dictionary = campaign.city_state("hongnong")
	target["faction"] = "yuan_shao"
	target["garrison"] = 1600
	target["units"] = {"infantry": 1600, "archers": 0, "cavalry": 0}
	target["defense"] = 20
	var map = load("res://scenes/map_slice.tscn").instantiate()
	root.add_child(map)
	map.selected_id = "hongnong"
	map._refresh_ui()
	map.war_ui.show_dispatch("hongnong")
	for index in range(map.war_ui.officer_choice.item_count):
		if map.war_ui.officer_choice.get_item_text(index).begins_with("关羽"):
			map.war_ui.officer_choice.select(index)
			map.war_ui._update_preview()
	if map.war_ui.confirm_button.disabled or not map.war_ui.preview_label.text.contains("自动动员"):
		push_error("派遣界面没有显示可执行预览")
		quit(1)
		return
	await _save("res://docs/validation/war-dispatch.png")
	map.war_ui._dispatch()
	for index in range(18): await campaign.advance_day()
	map.war_ui.show_reports()
	await _save("res://docs/validation/war-reports.png")
	map.war_ui.show_settings()
	await _save("res://docs/validation/war-settings.png")
	print("WAR_UI_CAPTURE_OK: dispatch, reports, settings; isolated in-memory scenario")
	quit(0)


func _save(path: String) -> void:
	await process_frame
	await process_frame
	await create_timer(0.1).timeout
	await RenderingServer.frame_post_draw
	var error: int = root.get_texture().get_image().save_png(path)
	if error != OK:
		push_error("无法保存战争界面截图")
		quit(1)
