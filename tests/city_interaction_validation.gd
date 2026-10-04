extends SceneTree


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var sandbox = load("res://scripts/game_state.gd").new()
	sandbox.persist_enabled = false
	sandbox._load_demo()
	var interior = load("res://scenes/city_interior.tscn").instantiate()
	interior.store = sandbox
	root.add_child(interior)
	interior.open_city("xuchang", "许昌", "豫州")
	await process_frame
	await process_frame
	for building_id in interior.BUILDINGS:
		await _click_control(interior.building_buttons[building_id])
		if building_id != "government" and (not interior.action_panel.visible or interior.selected_building != building_id):
			_fail("真实鼠标点击未打开建筑菜单：%s，selected=%s，panel=%s，council=%s" % [building_id, interior.selected_building, interior.action_panel.visible, interior.in_council])
			return
		if building_id == "government":
			if not interior.in_council or not interior.council_view.visible:
				_fail("点击官府未进入独立政厅")
				return
			await _click_control(interior.council_view.buttons["military"])
			if interior.action_heading.text != "军事" or interior.action_list.get_child_count() != 3:
				_fail("政厅底部菜单未切换军事命令")
				return
			await _click_control(interior.council_view.buttons["civil"])
			var order_before := int(sandbox.city_state("xuchang")["order"])
			await _click_control(interior.action_list.get_child(0).get_child(0))
			if not interior.action_view.visible or sandbox.action_points != 3 or int(sandbox.city_state("xuchang")["order"]) != order_before:
				_fail("命令预览未打开或确认前已改变游戏状态")
				return
			var portrait_bounds: Rect2 = interior.action_view.get_node("ActionPortrait").get_global_rect()
			if portrait_bounds.end.x > 1021 or portrait_bounds.end.y > 278:
				_fail("执行人物立绘溢出预览栏")
				return
			await _click_control(interior.action_view.return_button)
			if interior.action_view.visible or sandbox.action_points != 3:
				_fail("返回命令菜单未取消预览")
				return
			await _click_control(interior.action_list.get_child(0).get_child(0))
			await _escape()
			if interior.action_view.visible or not interior.action_panel.visible or sandbox.action_points != 3:
				_fail("Esc 未取消操作预览并返回命令菜单")
				return
			await _click_control(interior.action_list.get_child(0).get_child(0))
			await _click_control(interior.action_view.confirm_button)
			if int(sandbox.city_state("xuchang")["order"]) != order_before + 8 or sandbox.action_points != 2:
				_fail("政厅内政按钮未执行治理并扣除行动力")
				return
			var focus_owner := root.gui_get_focus_owner()
			if focus_owner == null or str(focus_owner.get_meta("action_id", "")) != "govern":
				_fail("命令执行后没有恢复可用按钮的键盘焦点")
				return
		var bounds: Rect2 = interior.action_panel.get_global_rect()
		if bounds.position.x < 0 or bounds.position.y < 0 or bounds.end.x > 1260 or bounds.end.y > 648 or bounds.size.y > 350:
			_fail("建筑菜单溢出视口或不合理地拉长：" + building_id)
			return
		await _click_at(Vector2(900, 615))
		if interior.action_panel.visible:
			_fail("点击空白处未关闭菜单")
			return
		if building_id == "government":
			await _escape()
			if interior.in_council or not interior.visible:
				_fail("Esc 未从政厅返回城内")
				return
			await _click_control(interior.building_buttons["government"])
			await _click_control(interior.council_view.buttons["return"])
			if interior.in_council or interior.council_view.visible:
				_fail("无法从政厅返回城内")
				return
	await _click_control(interior.building_buttons["workshop"])
	var before := int(sandbox.city_state("xuchang")["equipment"])
	var before_ap: int = sandbox.action_points
	await _click_control(interior.action_list.get_child(0).get_child(0))
	await _click_control(interior.action_view.confirm_button)
	if int(sandbox.city_state("xuchang")["equipment"]) != before + 6 or sandbox.action_points != before_ap - 1 or interior.resource_labels["equipment"].text != str(before + 6):
		_fail("真实点击锻造未执行命令或实时刷新资源")
		return
	await _escape()
	if interior.action_panel.visible or not interior.visible:
		_fail("Esc 未先关闭建筑菜单")
		return
	await _click_control(interior.toolbar_buttons[7])
	if not interior.report_panel.visible or interior.report_text.text.find("军备") < 0:
		_fail("工具栏点击未打开城市情报")
		return
	await _escape()
	if interior.report_panel.visible or not interior.visible:
		_fail("Esc 未先关闭情报窗口")
		return
	await _click_control(interior.toolbar_buttons[9])
	await _click_control(interior.settings_button)
	if interior.building_labels[0].visible:
		_fail("真实点击显示设置未隐藏名称")
		return
	await _escape()
	await _click_control(interior.building_buttons["government"])
	if interior.council_view.CATEGORIES.size() != 6:
		_fail("官府底部不是六个栏目")
		return
	for category in ["people", "strategy", "diplomacy", "intelligence"]:
		await _click_control(interior.council_view.buttons[category])
		if interior.council_category != category or not interior.action_panel.visible:
			_fail("新增栏目无法切换：" + category)
			return
		var ap_before: int = sandbox.action_points
		await _click_control(interior.action_list.get_child(0).get_child(0))
		var info_visible: bool = interior.officer_page != null and interior.officer_page.visible if category == "people" else interior.report_panel.visible
		if not info_visible or sandbox.action_points != ap_before:
			_fail("栏目资料未打开或错误扣除行动力：" + category)
			return
		await _escape()
	var month_before: int = sandbox.month
	await _click_control(interior.end_month_button)
	if sandbox.month != month_before % 12 + 1 or sandbox.action_points != 3:
		_fail("进行按钮未完成月度结算")
		return
	await _click_control(interior.council_view.buttons["return"])
	if interior.in_council or interior.end_month_button.text != "结束本月":
		_fail("返回城内未恢复普通月末按钮")
		return
	await _escape()
	if interior.visible:
		_fail("Esc 未退出城内界面")
		return
	interior.queue_free()
	sandbox.free()
	await process_frame
	print("城内交互检查通过：六个官府栏目、资料页面、进行结算、命令确认与分层返回。")
	quit(0)


func _click_control(control: Control) -> void:
	await _click_at(control.get_global_rect().get_center())


func _click_at(point: Vector2) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = point
	motion.global_position = point
	root.push_input(motion, true)
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.position = point
		event.global_position = point
		event.pressed = pressed
		root.push_input(event, true)
	await process_frame
	await process_frame


func _escape() -> void:
	var event := InputEventKey.new()
	event.keycode = KEY_ESCAPE
	event.pressed = true
	root.push_input(event, true)
	await process_frame


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
