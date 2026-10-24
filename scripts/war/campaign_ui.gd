extends CanvasLayer

signal army_dispatched(id: String)

const CitySkin = preload("res://scripts/city_ui_skin.gd")
const ACTION_NAMES := {"march": "行军", "continue": "继续行军", "hold": "驻守整顿", "scout": "侦察", "resupply": "补給", "engage": "接战", "besiege": "围城", "pursue": "追击", "withdraw": "撤退", "request_support": "求援", "flank": "侧翼绕行", "support": "协同支援", "reposition":"战术换位", "local_disengage":"准备局部脱离"}
var store: Node
var drawer: PanelContainer
var body: VBoxContainer
var heading: Label
var date_label: Label
var status_label: Label
var next_button: Button
var target_id := ""
var page := "reports"
var source_choice: OptionButton
var companion_checks: Dictionary = {}
var officer_choice: OptionButton
var faction_choice: OptionButton
var preview_label: Label
var confirm_button: Button
var notice_label: Label
var selected_army := ""
var scenario_picker: Button
var toolbar_offset := Vector2(14, 14)
var dispatch_home := ""
var flow_button: Button
var speed_choice: OptionButton
var dispatch_view: Control
var inspector: Control
var reports_view: Control
var drawer_chrome: Array[Control] = []
var drawer_scroll: ScrollContainer
var panel_timer := 0.0
var battle_label: Label
var result_dialog: AcceptDialog


func _ready() -> void:
	layer = 15
	var canvas := Control.new()
	canvas.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(canvas)
	var toolbar := HBoxContainer.new()
	toolbar.position = toolbar_offset
	toolbar.add_theme_constant_override("separation", 8)
	canvas.add_child(toolbar)
	if store.battle_test:
		var scenario_button := _button("战场：" + str(store.war.state.get("battlefield", {}).get("scenario_name", "官渡列阵决战")) + "  ▾", store.open_battle_scenarios)
		scenario_picker = scenario_button
		scenario_button.name = "BattleScenarioPicker"
		scenario_button.position = Vector2(470, 112)
		scenario_button.add_theme_font_size_override("font_size", 13)
		canvas.add_child(scenario_button)
		battle_label = _label("", 15)
		battle_label.position = Vector2(16, 158)
		battle_label.size = Vector2(760, 48)
		battle_label.autowrap_mode = TextServer.AUTOWRAP_OFF
		battle_label.add_theme_color_override("font_color", Color.WHITE)
		battle_label.add_theme_color_override("font_shadow_color", Color.BLACK)
		battle_label.add_theme_constant_override("shadow_offset_x", 1)
		battle_label.add_theme_constant_override("shadow_offset_y", 1)
		canvas.add_child(battle_label)
		if is_instance_valid(store.war_presentation): battle_label.hide()
	toolbar.add_child(_button("军情", show_reports))
	if not store.battle_test: toolbar.add_child(_button("城务与人事", show_city_policy))
	if not store.battle_test: toolbar.add_child(_button("人才", show_talents))
	var targets := OptionButton.new()
	targets.add_item("选择出征目标")
	for id in store.war.graph.places:
		targets.add_item(store.war.graph.name_of(str(id)))
		targets.set_item_metadata(targets.item_count - 1, id)
	targets.item_selected.connect(func(index):
		if index > 0: show_dispatch(str(targets.get_item_metadata(index)))
	)
	_style_field(targets)
	toolbar.add_child(targets)
	# 3D 下点城即出征，这个下拉框没有意义；但整条 toolbar 不能隐藏——全项目唯一的
	# 1×/2×/4× 速度选择器就建在这条 toolbar 里，隐藏后 3D 模式速度完全不可调。
	if is_instance_valid(store.war_presentation): targets.hide()
	next_button = _button("进行", _next_turn)
	next_button.tooltip_text = "推进十天"
	toolbar.add_child(next_button)
	if not is_instance_valid(store.war_presentation): toolbar.add_child(_button("设置", store.open_settings))
	if is_instance_valid(store.war_presentation):
		flow_button = next_button
		var speed := OptionButton.new()
		speed_choice = speed
		for value in ["1×", "2×", "4×"]: speed.add_item(value)
		speed.select(clampi(int(round(log(store.time_scale) / log(2.0))), 0, 2))
		speed.item_selected.connect(func(index): store.time_scale = pow(2.0, index))
		_style_field(speed)
		toolbar.add_child(speed)
	date_label = _label("", 16)
	date_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	date_label.add_theme_color_override("font_color", Color("fff2d0"))
	date_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	toolbar.add_child(date_label)
	drawer = PanelContainer.new()
	drawer.set_anchors_and_offsets_preset(Control.PRESET_RIGHT_WIDE)
	drawer.offset_left = -350
	drawer.offset_right = -16
	drawer.offset_top = 60
	drawer.offset_bottom = -12
	drawer.add_theme_stylebox_override("panel", CitySkin.paper(0.98, 16))
	canvas.add_child(drawer)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	drawer.add_child(column)
	var top := HBoxContainer.new()
	column.add_child(top)
	drawer_chrome.append(top)
	heading = _label("军情", 18)
	heading.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(heading)
	top.add_child(_button("关闭", func(): drawer.hide()))
	var tabs := HBoxContainer.new()
	column.add_child(tabs)
	drawer_chrome.append(tabs)
	tabs.add_child(_button("军报", show_reports))
	status_label = _label("", 13)
	column.add_child(status_label)
	drawer_chrome.append(status_label)
	var divider := HSeparator.new()
	column.add_child(divider)
	drawer_chrome.append(divider)
	var scroll := ScrollContainer.new()
	drawer_scroll = scroll
	preload("res://scripts/war/war_ui_skin.gd").scroll(scroll)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	column.add_child(scroll)
	body = VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 10)
	scroll.add_child(body)
	drawer.hide()
	reports_view = _create_reports_view()
	reports_view.store = store
	canvas.add_child(reports_view)
	reports_view.army_requested.connect(show_army)
	store.campaign_changed.connect(refresh)
	store.campaign_progress.connect(_refresh_status)
	store.city_changed.connect(func(_id):
		if not store.busy and drawer.visible and page == "dispatch": _update_preview()
	)
	refresh()


func _create_reports_view() -> Control:
	return preload("res://scripts/war/military_reports.gd").new()


func _label(value: String, size: int = 13) -> Label:
	var label := preload("res://scripts/war/war_ui_skin.gd").label(value, size)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return label


func _button(value: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = value
	button.custom_minimum_size.y = 29
	button.add_theme_font_override("font", preload("res://scripts/war/war_ui_skin.gd").font())
	button.add_theme_font_size_override("font_size", 13)
	CitySkin.style_button(button)
	button.pressed.connect(action)
	return button


func _clear() -> void:
	for child in body.get_children():
		body.remove_child(child)
		child.queue_free()
	preview_label = null
	confirm_button = null
	notice_label = null


func refresh() -> void:
	_refresh_status()
	if is_instance_valid(reports_view): reports_view.refresh()
	if not drawer.visible:
		return
	if page == "dispatch":
		if not store.busy: _update_preview()
	elif page == "army":
		if is_instance_valid(inspector): inspector.update_info()
	elif page == "army_orders":
		if not store.busy: show_army_orders(selected_army)


func _refresh_status() -> void:
	if is_instance_valid(scenario_picker): scenario_picker.text = "战场：" + str(store.war.state.get("battlefield",{}).get("scenario_name","平原会战")) + "  ▾"
	if not store.war.state.get("campaign_result", {}).is_empty():
		status_label.text = str(store.war.state["campaign_result"]["message"])
		next_button.disabled = true
		if is_instance_valid(flow_button): flow_button.disabled = true
		if not is_instance_valid(result_dialog):
			result_dialog = AcceptDialog.new()
			CitySkin.theme_window(result_dialog)
			result_dialog.theme.set_color("title_color", "Window", Color("f4ebd5"))
			result_dialog.title = "战役胜利" if store.war.state["campaign_result"]["status"] == "victory" else "战役结束"
			result_dialog.dialog_text = str(store.war.state["campaign_result"]["message"])
			result_dialog.ok_button_text = "检视战役"
			result_dialog.add_button("返回开始页", false, "restart")
			result_dialog.custom_action.connect(func(action):
				if action == "restart": get_tree().change_scene_to_file("res://scenes/battle_start.tscn")
			)
			add_child(result_dialog)
			result_dialog.popup_centered(Vector2i(520, 180))
		return
	_refresh_time_label()
	if is_instance_valid(flow_button):
		flow_button.text = ("继续" if store.time_paused else "暂停") if store.busy else "进行"
	next_button.disabled = store.busy and not is_instance_valid(flow_button)
	if store.agent != null:
		status_label.text = "主帅后台推演  军队沿用当前军令" if store.war.planner.running else str(store.agent.last_status)
	if store.busy and is_instance_valid(confirm_button):
		confirm_button.disabled = true


func show_dispatch(target: String) -> void:
	if store.busy: return
	if is_instance_valid(dispatch_view): dispatch_view.queue_free()
	var view = preload("res://scripts/war/dispatch_view.gd").new()
	dispatch_view = view
	view.store = store
	view.target = target
	view.home_hint = dispatch_home
	view.dispatched.connect(func(id): dispatch_home = ""; army_dispatched.emit(id); show_reports())
	add_child(view)
	drawer.hide()


func _show_dispatch_legacy(target: String) -> void:
	if store.busy:
		return
	target_id = target
	page = "dispatch"
	heading.text = "派将  " + store.war.graph.name_of(target)
	drawer.show()
	_clear()
	body.add_child(_label("军团人数、岗位、兵力和指挥层级由玩家自由设置；各角色按自身性格与立场决定服从、异议或自行行动。", 15))
	body.add_child(_label("出征目标", 14))
	var target_choice := OptionButton.new()
	_style_field(target_choice)
	for id in store.war.graph.places:
		target_choice.add_item(store.war.graph.name_of(str(id)))
		target_choice.set_item_metadata(target_choice.item_count - 1, id)
		if str(id) == target: target_choice.select(target_choice.item_count - 1)
	target_choice.item_selected.connect(func(index): show_dispatch(str(target_choice.get_item_metadata(index))))
	body.add_child(target_choice)
	body.add_child(_label("当前势力", 14))
	faction_choice = OptionButton.new()
	_style_field(faction_choice)
	var factions: Array = store.scenario["factions"].keys()
	factions.sort()
	for faction in factions:
		faction_choice.add_item(str(store.scenario["factions"][faction]["name"]))
		faction_choice.set_item_metadata(faction_choice.item_count - 1, faction)
		if faction == store.war.state["player_faction"]:
			faction_choice.select(faction_choice.item_count - 1)
	faction_choice.disabled = store.war.state.get("campaign_started", false) or not store.war.active_armies(str(store.war.state["player_faction"])).is_empty()
	faction_choice.item_selected.connect(func(index):
		if store.war.set_player_faction(str(faction_choice.get_item_metadata(index))):
			store._save()
			show_dispatch(target_id)
	)
	body.add_child(faction_choice)
	body.add_child(_label("出发城", 14))
	source_choice = OptionButton.new()
	_style_field(source_choice)
	var best_cost: float = INF
	var best_index: int = -1
	for id in store.war.graph.places:
		var city: Dictionary = store.city_state(str(id))
		if not city.has("population") or str(city.get("faction", "")) != str(store.war.state["player_faction"]):
			continue
		source_choice.add_item("%s  驻军%d" % [store.war.graph.name_of(str(id)), int(city.get("garrison", 0))])
		source_choice.set_item_metadata(source_choice.item_count - 1, id)
		var path: Dictionary = store.war.graph.path(str(id), target)
		if str(id) != target and bool(path["found"]) and float(path["cost"]) < best_cost:
			best_cost = float(path["cost"])
			best_index = source_choice.item_count - 1
	if best_index >= 0: source_choice.select(best_index)
	for index in range(source_choice.item_count):
		if str(source_choice.get_item_metadata(index)) == dispatch_home: source_choice.select(index)
	source_choice.item_selected.connect(func(_index): _update_preview())
	body.add_child(source_choice)
	body.add_child(_label("主将", 14))
	officer_choice = OptionButton.new()
	_style_field(officer_choice)
	for officer in store.war.available_officers(str(store.war.state["player_faction"])):
		officer_choice.add_item("%s  带兵%d" % [officer["name"], int(officer["skills"].get("带兵", 50))])
		officer_choice.set_item_metadata(officer_choice.item_count - 1, officer["id"])
	officer_choice.item_selected.connect(func(_index): _update_preview())
	body.add_child(officer_choice)
	body.add_child(_label("随军人员  最多选五人，按职位能力任命", 16))
	companion_checks.clear()
	for officer in store.war.available_officers(str(store.war.state["player_faction"])):
		var check := CheckButton.new()
		check.text = officer["name"] + "  " + str(officer.get("positions", "")).split("\n")[0]
		check.button_pressed = store.war.Corps.select_members(store.war, str(officer_choice.get_item_metadata(officer_choice.selected)), store.war.available_officers(str(store.war.state["player_faction"])).map(func(o): return o["id"])).has(officer["id"])
		check.tooltip_text = officer.get("positions", "")
		check.add_theme_font_override("font", CitySkin.font())
		check.add_theme_color_override("font_color", CitySkin.INK)
		check.toggled.connect(func(_pressed): _update_preview())
		companion_checks[officer["id"]] = check
		body.add_child(check)
	preview_label = _label("", 16)
	body.add_child(preview_label)
	confirm_button = _button("派遣", _dispatch)
	body.add_child(confirm_button)
	notice_label = _label("", 15)
	body.add_child(notice_label)
	body.add_child(_label("演示人物与势力配置，尚未按历史年份校定。", 12))
	_update_preview()


func _update_preview() -> void:
	if preview_label == null or not is_instance_valid(preview_label): return
	if source_choice.item_count == 0 or officer_choice.item_count == 0:
		preview_label.text = "暂无可派遣的城池或主将。执行任务中的将领需归营后再次任命。"
		confirm_button.disabled = true
		return
	var home: String = str(source_choice.get_item_metadata(source_choice.selected))
	var id: String = str(officer_choice.get_item_metadata(officer_choice.selected))
	if companion_checks.has(id): companion_checks[id].set_pressed_no_signal(false)
	var selected_count := 0
	for officer in companion_checks:
		if companion_checks[officer].button_pressed: selected_count += 1
	for officer in companion_checks:
		companion_checks[officer].disabled = officer == id or (selected_count >= 5 and not companion_checks[officer].button_pressed)
	var preview: Dictionary = store.war.preview_dispatch(home, target_id, id)
	confirm_button.disabled = store.busy or not bool(preview["ok"])
	if not bool(preview["ok"]):
		preview_label.text = str(preview["message"])
		return
	var officer: Dictionary = store.war.roster.officers[id]
	var personality: Dictionary = officer["personality"]
	preview_label.text = "%s%s\n\n自动动员 %d 人\n留守 %d 人\n最短通路约 %d 日，实际路线由主将决定\n\n风险承受 %d  耐心 %d  决断 %d\n%s" % ["守援" if preview["mission_type"] == "defend" else "攻取", store.war.graph.name_of(target_id), int(preview["strength"]), int(preview["reserve"]), int(preview["travel_days"]), int(personality["风险承受"]), int(personality["耐心"]), int(personality["决断"]), str(officer["profile_note"])]


func _dispatch() -> void:
	if confirm_button.disabled: return
	var commander: String = str(officer_choice.get_item_metadata(officer_choice.selected))
	var companions: Array = []
	for officer in companion_checks:
		if officer != commander and companion_checks[officer].button_pressed: companions.append(officer)
	var result: Dictionary = store.war.dispatch(str(source_choice.get_item_metadata(source_choice.selected)), target_id, commander, companions, true)
	if bool(result["ok"]):
		dispatch_home = ""
		show_reports()
		army_dispatched.emit(str(result["army_id"]))
	else:
		notice_label.text = str(result["message"])


func show_dispatch_from(home: String) -> void:
	dispatch_home = home
	var target := ""
	var cost := INF
	for id in store.war.graph.places:
		if str(id) == home: continue
		var path: Dictionary = store.war.graph.path(home, str(id))
		if not path["found"]: continue
		var value: float = float(path["cost"]) + (1000 if store.city_state(str(id)).get("faction", "") == store.war.state["player_faction"] else 0)
		if value < cost:
			target = str(id)
			cost = value
	if target != "": show_dispatch(target)


func show_reports() -> void:
	drawer.hide()
	reports_view.open()


func show_army_reports(id: String) -> void:
	drawer.hide()
	reports_view.open(id)


func show_review(id: String) -> void:
	drawer.hide()
	reports_view.show_review(id)


func _prepare_drawer(kind: String) -> void:
	for item in drawer_chrome: item.visible = kind != "army"
	status_label.hide()
	drawer.add_theme_stylebox_override("panel", StyleBoxEmpty.new() if kind == "army" else preload("res://scripts/war/war_ui_skin.gd").paper(12))
	drawer_scroll.scroll_vertical = 0


func show_army(id: String) -> void:
	var army: Dictionary = store.war.state["armies"].get(id, {})
	if army.is_empty(): return
	if is_instance_valid(dispatch_view):
		dispatch_view.queue_free()
		dispatch_view = null
	if is_instance_valid(reports_view): reports_view.hide()
	var same: bool = page == "army" and selected_army == id and is_instance_valid(inspector)
	selected_army = id
	page = "army"
	heading.text = str(army["name"])
	drawer.show()
	if same:
		inspector.update_info()
		return
	_clear()
	_prepare_drawer("army")
	inspector = preload("res://scripts/war/army_inspector.gd").new()
	inspector.store = store
	inspector.army_id = id
	inspector.orders_requested.connect(show_army_orders)
	inspector.reports_requested.connect(show_army_reports)
	inspector.close_requested.connect(func(): drawer.hide())
	body.add_child(inspector)


func show_army_orders(id: String) -> void:
	var army: Dictionary = store.war.state["armies"].get(id, {})
	if army.is_empty(): return
	selected_army = id
	page = "army_orders"
	drawer.show()
	_clear()
	_prepare_drawer("army_orders")
	heading.text = "军令  " + str(army["name"])
	body.add_child(_button("返回部队信息", func(): show_army(id)))
	var ended: bool = army["status"] == "ended"
	var corps: Dictionary = store.war.state["corps"].get(army.get("corps_id", ""), {})
	if not corps.is_empty():
		body.add_child(_label("军团编制\n" + preload("res://scripts/war/army_inspector.gd").personnel_text(store.war, corps), 13))
	var withdraw_button := _button("全军撤退" if not corps.is_empty() and corps["root_id"] == id else "本队撤退", func():
		var result: Dictionary = store.war.command_army(id, {}, true)
		show_army_orders(id)
		body.add_child(_label(str(result["message"]), 13))
	)
	withdraw_button.name = "WithdrawArmy"
	withdraw_button.disabled = ended or store.busy or bool(army["returning"])
	body.add_child(withdraw_button)
	body.add_child(_label("设定军令", 15))
	var request: Dictionary = army.get("pending_request", {})
	if not request.is_empty():
		body.add_child(_label("违令请示（第%d日）：建议%s\n把握 %d%%  未批复前按原军令执行" % [int(request.get("tick", 0)), str(request.get("reason", "")), int(float(request.get("probability", 0.0)) * 100.0)], 13))
		var request_row := HBoxContainer.new()
		body.add_child(request_row)
		# 批复期间日期可能正在推进；无 busy 保护时 resolve_request 直接返回失败，
		# 而失败消息被丢弃，玩家点了按钮看不到任何反馈。
		var resolve_request := func(approve: bool):
			if store.busy:
				status_label.text = "日期正在推进，请稍候再批复。"
				return
			var outcome: Dictionary = store.war.resolve_request(id, approve)
			if not bool(outcome.get("ok", false)):
				status_label.text = str(outcome.get("message", "批复失败"))
			show_army_orders(id)
		var approve_button := _button("批准", func(): resolve_request.call(true))
		var reject_button := _button("驳回", func(): resolve_request.call(false))
		approve_button.disabled = ended or store.busy
		reject_button.disabled = ended or store.busy
		request_row.add_child(approve_button)
		request_row.add_child(reject_button)
	var orders: Dictionary = store.war.orders_for(army)
	for setting in [["局部脱离整顿","local_disengage",bool(orders.get("local_disengage",orders["retreat"]))],["必须保持职责据点","must_hold_objective",bool(orders.get("must_hold_objective",false))]]:
		var permission := CheckButton.new()
		permission.text = setting[0]
		permission.button_pressed = setting[2]
		permission.disabled = ended or store.busy or bool(army["returning"])
		permission.toggled.connect(func(value): store.war.command_army(id,{setting[1]:value}))
		body.add_child(permission)
	for spec in [["敌军接近时", "engage", "攻击", "无视"], ["自主撤退", "retreat", "许可", "不许"], ["追击败军", "pursue", "许可", "不许"], ["攻取后命令", "after_battle", "撤退", "待命"]]:
		var row := HBoxContainer.new()
		body.add_child(row)
		row.add_child(_label(spec[0], 13))
		var choice := OptionButton.new()
		_style_field(choice)
		choice.add_item(spec[2])
		choice.add_item(spec[3])
		var key: String = spec[1]
		choice.select((0 if orders[key] == "withdraw" else 1) if key == "after_battle" else (0 if orders[key] else 1))
		choice.disabled = ended or store.busy or bool(army["returning"])
		choice.item_selected.connect(func(index):
			var value: Variant = ("withdraw" if index == 0 else "hold") if key == "after_battle" else index == 0
			store.war.command_army(id, {key: value})
		)
		row.add_child(choice)
	body.add_child(_label("主动撤退优先执行；溃败时仍会保命撤离。忽视敌军不能免于遭受攻击。", 13))
	# 军令书扩展项：意图进入AI评分偏置，冒险许可在候选生成阶段过滤，撤退线强制提醒撤军。
	for spec in [["作战意图", "intent", store.war.rules.get("orders", {}).get("intents", ["速胜", "稳扎", "牵制", "斩首", "保存实力"])], ["冒险许可", "risk_allowance", store.war.rules.get("orders", {}).get("risk_levels", ["保守", "常规", "放手"])]]:
		var order_row := HBoxContainer.new()
		body.add_child(order_row)
		order_row.add_child(_label(spec[0], 13))
		var order_choice := OptionButton.new()
		_style_field(order_choice)
		for value in spec[2]:
			order_choice.add_item(str(value))
			order_choice.set_item_metadata(order_choice.item_count - 1, str(value))
			if str(orders[spec[1]]) == str(value): order_choice.select(order_choice.item_count - 1)
		order_choice.disabled = ended or store.busy or bool(army["returning"])
		order_choice.item_selected.connect(func(index): store.war.command_army(id, {spec[1]: order_choice.get_item_metadata(index)}))
		order_row.add_child(order_choice)
	for spec in [["撤退兵力线", "strength", [["不设", 0.0], ["六成", 0.6], ["五成", 0.5], ["四成", 0.4]]], ["撤退士气线", "morale", [["不设", 0.0], ["30", 30.0], ["25", 25.0], ["20", 20.0]]]]:
		var line_row := HBoxContainer.new()
		body.add_child(line_row)
		line_row.add_child(_label(spec[0], 13))
		var line_choice := OptionButton.new()
		_style_field(line_choice)
		var current := float(orders["retreat_line"].get(spec[1], 0.0))
		for preset in spec[2]:
			line_choice.add_item(str(preset[0]))
			line_choice.set_item_metadata(line_choice.item_count - 1, float(preset[1]))
			if is_equal_approx(float(preset[1]), current): line_choice.select(line_choice.item_count - 1)
		line_choice.disabled = ended or store.busy or bool(army["returning"])
		line_choice.item_selected.connect(func(index):
			var line: Dictionary = {"strength": float(orders["retreat_line"].get("strength", 0.0)), "morale": float(orders["retreat_line"].get("morale", 0.0))}
			line[spec[1]] = float(line_choice.get_item_metadata(index))
			store.war.command_army(id, {"retreat_line": line})
		)
		line_row.add_child(line_choice)
	body.add_child(_label("意图是总体偏置：速胜更进取、牵制重守位、保存实力更早撤退；保守许可不生成侧击与追击候选。", 13))
	body.add_child(_button("查看战役复盘" if ended else "查看当前复盘", func(): show_review(id)))




func show_settings() -> void:
	store.open_settings()

func show_talents(selected: String = "") -> void:
	_prepare_drawer("talents")
	page = "talents"
	heading.text = "人才与履历"
	drawer.show()
	_clear()
	var war = store.war
	war.characters.sync(war)
	var faction_id := str(war.state["player_faction"])
	var owned: Array = war.Operations.cities(war, faction_id)
	if owned.is_empty(): body.add_child(_label("本方暂无城池", 16)); return
	if not owned.has(selected): selected = str(owned[0])
	var cities := OptionButton.new()
	_style_field(cities)
	for id in owned:
		cities.add_item(war.graph.name_of(id))
		cities.set_item_metadata(cities.item_count - 1, id)
		if id == selected: cities.select(cities.item_count - 1)
	cities.item_selected.connect(func(index): show_talents(str(cities.get_item_metadata(index))))
	body.add_child(cities)
	body.add_child(_label("安排寻访 · 1行动力，调查3日，另计往返时间", 13))
	var actors := OptionButton.new()
	_style_field(actors)
	for officer in war.available_officers(faction_id):
		actors.add_item(str(officer["name"]))
		actors.set_item_metadata(actors.item_count - 1, officer["id"])
	body.add_child(actors)
	var search_button := _button("派员寻访", func():
		var result: Dictionary = war.Talent.investigate(war, str(actors.get_item_metadata(actors.selected)), selected)
		show_talents(selected)
		notice_label.text = str(result["message"])
	)
	search_button.disabled = actors.item_count == 0 or store.busy
	body.add_child(search_button)
	for task in war.Talent.state(war)["tasks"].values():
		if task["faction"] == faction_id and task["phase"] != "complete":
			body.add_child(_label("%s · %s · 剩余%d日" % [war.roster.officers[task["actor"]]["name"], "寻访" if task["phase"] == "searching" else "归程", maxi(0, int(task["arrival_tick"]) - int(war.state["tick"]))], 13))
	body.add_child(_label("已发现的在野人才", 16))
	var count := 0
	for id in war.characters.states:
		var person: Dictionary = war.characters.states[id]
		if person["service_status"] != "wild" or not war.Talent.known(war, faction_id, str(id)): continue
		count += 1
		body.add_child(_label("%s · %s" % [war.characters.definitions[id]["name"], war.graph.name_of(str(person["availability"].get("city", "")))], 14))
		for spec in [["接洽待任", ""], ["接洽太守", "governor"], ["接洽守将", "guard"]]:
			var target := str(id)
			var job := str(spec[1])
			var button := _button(str(spec[0]) + " · 1行动力", func():
				var actor := ""
				for candidate in war.available_officers(faction_id):
					if str(war.state["officer_states"].get(candidate["id"], {}).get("city", "")) == selected:
						actor = str(candidate["id"])
						break
				var result: Dictionary = war.Talent.offer(war, target, selected, job, actor)
				show_talents(selected)
				notice_label.text = str(result["message"])
			)
			button.disabled = store.busy
			body.add_child(button)
	if count == 0: body.add_child(_label("尚无已发现的在野人才，可先派员寻访。", 13))
	body.add_child(_label("本方人物履历", 16))
	for id in war.characters.states:
		var person: Dictionary = war.characters.states[id]
		if person["faction_id"] != faction_id: continue
		var target := str(id)
		body.add_child(_button(str(war.characters.definitions[id]["name"]) + " · " + str(person["events"].size()) + "条记录", func(): show_character_history(target, selected)))
	notice_label = _label("人才接洽需要本城可用人员，岗位已有任职者时不能许诺该岗位。", 13)
	body.add_child(notice_label)

func show_character_history(id: String, city: String) -> void:
	_prepare_drawer("talents")
	page = "talents"
	heading.text = "人物履历"
	_clear()
	var system = store.war.characters
	var person: Dictionary = system.states[id]
	var view: Dictionary = system.view(id)
	body.add_child(_button("返回人才", func(): show_talents(city)))
	body.add_child(_label(str(view["name"]), 20))
	var names := ["军事", "谋略", "勇武", "政务", "影响"]
	for index in names.size():
		var dimension: Variant = view["dimensions"][index]
		body.add_child(_label(str(names[index]) + "  " + (str(roundi(float(dimension))) if dimension != null else "待标定"), 14))
	for job in system.JOBS:
		var fit: Dictionary = system.job_fit(id, str(job))
		var job_names := {"commander":"主将", "strategist":"军师", "vanguard":"先锋", "deputy":"副将", "governor":"太守", "diplomat":"外交使者"}
		body.add_child(_label(str(job_names[job]) + "适岗  " + ("%.0f%%" % (float(fit["score"]) * 100.0) if fit["known"] else "资料待补全"), 13))
	body.add_child(_label("经历与关系事件", 16))
	var kinds := {"appointment":"任命", "duty":"履职", "learning":"有效学习", "attribute_growth":"能力成长", "relation":"关系变化", "service_transition":"身份变化", "legacy_experience":"旧档经历", "talent_search":"寻访安排", "talent_discovered":"发现人才", "recruitment_offer":"招募接洽"}
	for event in person["events"].slice(maxi(0, person["events"].size() - 25)):
		var kind := str(event["kind"])
		var description := str(kinds.get(kind, "经历记录"))
		if kind == "attribute_growth": description += " · %s %.2f → %.2f" % [event["detail"]["attribute"], float(event["detail"]["before"]), float(event["detail"]["after"])]
		body.add_child(_label("第%d日 · %s" % [int(event["tick"]), description], 13))
	if person["events"].is_empty(): body.add_child(_label("尚无履职记录", 13))

func show_city_policy(selected: String = "") -> void:
	_prepare_drawer("city_policy")
	page = "city_policy"
	heading.text = "城务与人事"
	drawer.show()
	_clear()
	var owned: Array = store.war.Operations.cities(store.war, str(store.war.state["player_faction"]))
	if owned.is_empty(): body.add_child(_label("本方暂无城池", 16)); return
	if not owned.has(selected): selected = str(owned[0])
	var cities := OptionButton.new()
	for id in owned:
		cities.add_item(store.war.graph.name_of(id))
		cities.set_item_metadata(cities.item_count - 1, id)
		if id == selected: cities.select(cities.item_count - 1)
	_style_field(cities)
	body.add_child(cities)
	cities.item_selected.connect(func(index): show_city_policy(str(cities.get_item_metadata(index))))
	var policy: Dictionary = store.war.Operations.policy(store.war, selected)
	var defense := OptionButton.new()
	var rebuild := OptionButton.new()
	for spec in [[defense, "defense", [["adaptive", "守将判断出城或固守"], ["hold", "固守城墙"], ["sortie", "允许出城迎战"]]], [rebuild, "rebuild", [["balanced", "均衡整备"], ["civil", "优先恢复民心"], ["military", "优先补充军备"]]]]:
		var choice: OptionButton = spec[0]
		for item in spec[2]:
			choice.add_item(item[1])
			choice.set_item_metadata(choice.item_count - 1, item[0])
			if policy[spec[1]] == item[0]: choice.select(choice.item_count - 1)
		_style_field(choice)
		body.add_child(choice)
	var delegated := CheckButton.new()
	delegated.text = "委任太守经营"
	delegated.tooltip_text = "经营消耗本方行动力与城市资源"
	delegated.add_theme_font_override("font", preload("res://scripts/war/war_ui_skin.gd").font())
	delegated.add_theme_font_size_override("font_size", 13)
	delegated.add_theme_color_override("font_color", CitySkin.INK)
	delegated.button_pressed = policy["delegated"]
	body.add_child(delegated)
	body.add_child(_button("更新城池方针", func():
		var result: Dictionary = store.war.Operations.configure(store.war, selected, {"defense": defense.get_item_metadata(defense.selected), "rebuild": rebuild.get_item_metadata(rebuild.selected), "delegated": delegated.button_pressed})
		notice_label.text = result["message"]
	))
	var governor: Dictionary = store.war.roster.officers.get(store.city_state(selected).get("governor_id", ""), {})
	var guard: Dictionary = store.war.state["garrison_commanders"].get(selected, {})
	body.add_child(_label("太守：%s\n守将：%s" % [governor.get("name", "地方吏员代管"), guard.get("name", "临战任命")], 15))
	var officers := OptionButton.new()
	for officer in store.war.available_officers(str(store.war.state["player_faction"])):
		var home: String = str(store.war.state["officer_states"].get(officer["id"], {}).get("city", ""))
		officers.add_item("%s · %s" % [officer["name"], store.war.graph.name_of(home)])
		officers.set_item_metadata(officers.item_count - 1, officer["id"])
	_style_field(officers)
	body.add_child(officers)
	for spec in [["任命太守", "governor"], ["任命守将", "guard"], ["调任本城", ""]]:
		var role: String = spec[1]
		var button := _button(spec[0] + " · 1行动力", func():
			var result: Dictionary = store.war.Operations.assign(store.war, str(officers.get_item_metadata(officers.selected)), selected, role)
			notice_label.text = result["message"]
		)
		button.disabled = officers.item_count == 0
		body.add_child(button)
	for id in store.war.state["officer_states"]:
		var status: Dictionary = store.war.state["officer_states"][id]
		if status.get("status", "") == "transferring" and status.get("destination", "") == selected:
			body.add_child(_label("%s 正在调任，剩余%d日" % [store.war.roster.officers[id]["name"], maxi(0, int(status["arrives_at"]) - int(store.war.state["tick"]))], 14))
	notice_label = _label("异地任命需要实际调任时间；在役、负伤和被俘武将不可重复任命。", 13)
	body.add_child(notice_label)


func _style_field(control: Control) -> void:
	control.add_theme_font_override("font", preload("res://scripts/war/war_ui_skin.gd").font())
	control.add_theme_font_size_override("font_size", 13)
	var field := StyleBoxFlat.new()
	field.bg_color = Color("f5eedb")
	field.border_color = Color("bca878")
	field.border_width_bottom = 1
	field.set_content_margin_all(7)
	for type in ["normal", "hover", "pressed", "focus"]:
		control.add_theme_stylebox_override(type, field)
	for type in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		control.add_theme_color_override(type, CitySkin.INK)
	control.add_theme_color_override("font_placeholder_color", Color("8e8168"))
	if control is OptionButton:
		var popup: PopupMenu = control.get_popup()
		popup.add_theme_stylebox_override("panel", CitySkin.paper(0.99, 6))
		popup.add_theme_color_override("font_color", CitySkin.INK)


func _next_turn() -> void:
	if store.busy:
		if is_instance_valid(flow_button): store.toggle_time_pause()
		return
	await store.advance_turn()
	show_reports()


func _toggle_time() -> void:
	if store.busy:
		store.toggle_time_pause()
		return
	await store.advance_turn()
	show_reports()

func _refresh_time_label() -> void:
	var phase: String = "下令" if store.time_phase == "strategy" else "旬报" if store.time_phase == "report" else "暂停" if store.time_paused else "进行"
	var progress := ""
	if store.busy and store.turn_days_total > 0:
		var fraction := 0.0
		if is_instance_valid(store.war_presentation) and store.war_presentation.presenting:
			fraction = clampf(store.war_presentation.presentation_elapsed / store.war_presentation.DAY_SECONDS, 0, 1)
		progress = " %d%%" % int(100 * (store.turn_days_done + fraction) / store.turn_days_total)
	var period: String = ["上旬", "中旬", "下旬"][clampi((store.day - 1) / 10, 0, 2)]
	date_label.text = "%s %s  %s%s" % [store.date_text(), period, phase, progress]

func _process(_delta: float) -> void:
	panel_timer += _delta
	if panel_timer >= 0.3:
		panel_timer = 0.0
		if drawer.visible and page == "army" and is_instance_valid(inspector): inspector.update_info()
		if is_instance_valid(reports_view): reports_view.refresh()
	if is_instance_valid(date_label) and store.busy: _refresh_time_label()
	if store.busy and store.agent != null and is_instance_valid(status_label): status_label.text = str(store.agent.last_status)
	if is_instance_valid(battle_label) and store.agent != null and store.war.state.has("battlefield"):
		var metrics: Dictionary = store.agent.metrics
		battle_label.text = "%s  种子%d\n%s  累计请求%d / 失败%d / 回退%d" % [store.war.state["battlefield"].get("scenario_name", "小沛攻防"), store.war.state["battlefield"].get("seed", 1910901), "当前模型：" + str(store.agent.model) if store.agent.enabled else "本地策略（请在设置中启用模型）", metrics.get("calls", 0), metrics.get("failures", 0), metrics.get("fallbacks", 0)]

func _unhandled_key_input(event: InputEvent) -> void:
	if not is_instance_valid(flow_button): return
	if get_viewport().gui_get_focus_owner() is LineEdit or get_viewport().gui_get_focus_owner() is TextEdit: return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_SPACE:
		_toggle_time()
		get_viewport().set_input_as_handled()

func show_battle_summary() -> void:
	drawer.hide()
	reports_view.show_summary()
