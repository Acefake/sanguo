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
	var ui = load("res://scripts/war/ui/campaign_ui.gd").new()
	ui.store = campaign
	root.add_child(ui)
	ui.show_dispatch("hongnong")
	for index in range(ui.officer_choice.item_count):
		if ui.officer_choice.get_item_text(index).begins_with("关羽"):
			ui.officer_choice.select(index)
			ui._update_preview()
	if ui.confirm_button.disabled or not ui.preview_label.text.contains("自动动员"):
		push_error("派遣界面没有显示可执行预览")
		quit(1)
		return
	await _save("res://docs/validation/war-dispatch.png")
	ui._dispatch()
	ui.show_army(str(campaign.war.active_armies("liu_bei")[0]["id"]))
	var effect_label: Label
	for child in ui.body.get_children():
		if child is Label and child.text.begins_with("将领作战修正"): effect_label = child
	assert(effect_label != null)
	var scroll := effect_label.get_parent()
	while scroll != null and not scroll is ScrollContainer: scroll = scroll.get_parent()
	await process_frame
	if scroll is ScrollContainer: scroll.ensure_control_visible(effect_label)
	await _save("res://docs/validation/war-officer-effects.png")
	for index in range(18): await campaign.advance_day()
	ui.show_reports()
	await _save("res://docs/validation/war-reports.png")
	ui.show_settings()
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
