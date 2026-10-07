extends SceneTree


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var campaign := root.get_node("GameState")
	campaign.persist_enabled = false
	campaign._load_demo()
	var sandbox = load("res://scripts/game_state.gd").new()
	sandbox.persist_enabled = false
	sandbox._load_demo()
	sandbox.war.state["player_faction"] = "dong_zhuo"
	sandbox.war.rules["strategy"] = {}
	var before: Dictionary = sandbox.city_state("luoyang").duplicate(true)
	var result: Dictionary = sandbox.apply_action("luoyang", "govern")
	var after: Dictionary = sandbox.city_state("luoyang")
	if not bool(result["ok"]) or int(after["treasury"]) != int(before["treasury"]) - 200 or int(after["order"]) != int(before["order"]) + 8 or sandbox.action_points != 2:
		_fail("治理命令未正确扣费、提升民心或消耗行动力")
		return
	result = sandbox.apply_action("luoyang", "recruit")
	after = sandbox.city_state("luoyang")
	if not bool(result["ok"]) or int(after["garrison"]) != int(before["garrison"]) + 1000 or int(after["population"]) != int(before["population"]) - 1000:
		_fail("征兵命令未正确改变人口和驻军")
		return
	result = sandbox.apply_action("luoyang", "train")
	if not bool(result["ok"]) or sandbox.action_points != 0:
		_fail("第三项命令未耗尽本月行动力")
		return
	result = sandbox.apply_action("luoyang", "fortify")
	if bool(result["ok"]) or sandbox.action_points != 0:
		_fail("行动力耗尽后仍可执行命令")
		return
	var old_money := int(sandbox.city_state("luoyang")["treasury"])
	await sandbox.advance_month()
	if sandbox.month != 10 or sandbox.action_points != 3 or int(sandbox.city_state("luoyang")["treasury"]) <= old_money:
		_fail("月度结算未推进时间、恢复行动力或产生税收")
		return
	var interior = load("res://scenes/city_interior.tscn").instantiate()
	interior.store = sandbox
	root.add_child(interior)
	interior.open_city("luoyang", "洛阳", "司隶")
	if interior.city_title.text != "洛阳" or interior.date_label.text.find("10月") < 0 or interior.building_buttons.size() != 6 or interior.action_panel.visible:
		_fail("城内界面未展示城市、月份、六处建筑或误开启菜单")
		return
	interior.building_buttons["government"].pressed.emit()
	var order_before_ui := int(sandbox.city_state("luoyang")["order"])
	_click_action(interior, "安民治政")
	if int(sandbox.city_state("luoyang")["order"]) != order_before_ui + 8:
		_fail("点击治理按钮未执行对应命令")
		return
	var economy_before_ui := int(sandbox.city_state("luoyang")["economy"])
	interior.building_buttons["farm"].pressed.emit()
	_click_action(interior, "开垦田土")
	if int(sandbox.city_state("luoyang")["economy"]) != economy_before_ui + 4:
		_fail("点击开垦按钮未执行对应命令")
		return
	interior.building_buttons["barracks"].pressed.emit()
	if interior.action_list.get_child_count() != 2 or interior.action_heading.text != "兵营":
		_fail("兵营命令未正确切换")
		return
	var troops_before_ui := int(sandbox.city_state("luoyang")["garrison"])
	_click_action(interior, "征募兵员")
	if int(sandbox.city_state("luoyang")["garrison"]) != troops_before_ui + 1000 or sandbox.action_points != 0:
		_fail("军事按钮未执行征兵或消耗行动力")
		return
	for card in interior.action_list.get_children():
		var button: Button = card.get_child(0)
		if not button.disabled:
			_fail("行动力耗尽后按钮仍可点击")
			return
	interior._show_report("records")
	if not interior.report_panel.visible or interior.report_text.text.find("安民治政") < 0:
		_fail("施政记录未展示刚刚执行的命令")
		return
	interior._show_report("settings")
	interior.settings_button.pressed.emit()
	if interior.show_building_names or interior.building_labels[0].visible:
		_fail("建筑名称显示开关未生效")
		return
	await sandbox.advance_month()
	var trade_before: Dictionary = sandbox.city_state("luoyang").duplicate(true)
	interior.building_buttons["market"].pressed.emit()
	interior.action_list.get_child(2).get_child(0).pressed.emit()
	_click_action(interior, "购入粮草")
	interior.action_list.get_child(2).get_child(0).pressed.emit()
	_click_action(interior, "出售余粮")
	var trade_after: Dictionary = sandbox.city_state("luoyang")
	if int(trade_after["grain"]) != int(trade_before["grain"]) or int(trade_after["treasury"]) != int(trade_before["treasury"]) - 60 or sandbox.action_points != 1:
		_fail("粮草买卖未按成本结算或消耗行动力")
		return
	interior.building_buttons["workshop"].pressed.emit()
	_click_action(interior, "锻造兵装")
	if int(sandbox.city_state("luoyang")["equipment"]) != 56:
		_fail("锻造未提升军备")
		return
	await sandbox.advance_month()
	interior.building_buttons["tavern"].pressed.emit()
	var order_before_visit := int(sandbox.city_state("luoyang")["order"])
	_click_action(interior, "访察民情")
	if int(sandbox.city_state("luoyang")["order"]) != order_before_visit + 5:
		_fail("访察民情未改变民心")
		return
	var guarded: Dictionary = sandbox.city_state("luoyang")
	guarded["grain"] = 0
	var rejected_before := guarded.duplicate(true)
	var ap_before: int = sandbox.action_points
	result = sandbox.apply_action("luoyang", "sell_grain")
	if bool(result["ok"]) or guarded != rejected_before or sandbox.action_points != ap_before:
		_fail("资源不足时交易仍改变了资源或行动力")
		return
	guarded["equipment"] = 100
	result = sandbox.apply_action("luoyang", "forge")
	if bool(result["ok"]) or sandbox.action_points != ap_before:
		_fail("军备达到上限后仍可锻造")
		return
	var saved = load("res://scripts/game_state.gd").new()
	saved.save_path = "user://city_validation_temp.json"
	saved._load_demo()
	saved.war.state["player_faction"] = "dong_zhuo"
	saved.apply_action("luoyang", "govern")
	saved.apply_action("luoyang", "forge")
	var restored = load("res://scripts/game_state.gd").new()
	restored.save_path = saved.save_path
	restored._load_demo()
	restored._load_save()
	var persisted: bool = restored.action_points == 1 and int(restored.city_state("luoyang")["order"]) == 66 and int(restored.city_state("luoyang")["equipment"]) == 56 and restored.chronicles.size() == 2
	DirAccess.remove_absolute(ProjectSettings.globalize_path(saved.save_path))
	saved.free()
	restored.free()
	if not persisted:
		_fail("城池命令未正确保存并恢复")
		return
	var map = load("res://scenes/map_slice.tscn").instantiate()
	root.add_child(map)
	map.selected_id = "luoyang"
	map._enter_selected_city()
	if map.city_view == null or not map.city_view.visible:
		_fail("从大地图无法进入城市")
		return
	map.city_view._close()
	if map.city_view != null:
		_fail("无法返回大地图")
		return
	map.queue_free()
	interior.queue_free()
	sandbox.free()
	await process_frame
	print("城内检查通过：六处建筑、资源交易、军备、施政记录、行动力、保存与地图往返。")
	quit(0)


func _fail(message: String) -> void:
	push_error(message)
	quit(1)


func _click_action(interior, title: String) -> void:
	for card in interior.action_list.get_children():
		var button: Button = card.get_child(0)
		if button.text == title:
			button.pressed.emit()
			interior.action_view.confirm_button.pressed.emit()
			return
