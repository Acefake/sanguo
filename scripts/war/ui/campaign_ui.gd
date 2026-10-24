extends CanvasLayer
## 军务界面：右侧唯一抽屉（部队概况 / 军令 / 战报、派将、军情、城务、敌军信息）与底部军报浮条。
##
## 3D 大地图上推进、速度、日期由 world_map_hud 的顶栏负责；2D 地图（map_slice）没有顶栏，
## 这里自建一条简化工具行。抽屉每次只显示一页：部队详情等文字页共用 body，
## 军报簿与出阵编组是常驻页面，切换时复用，不重建。

signal army_dispatched(id: String)

const SideDrawer = preload("res://scripts/ui/shell/side_drawer.gd")
const ToastFeed = preload("res://scripts/ui/shell/toast_feed.gd")
const Minimap = preload("res://scripts/ui/shell/minimap.gd")
const Tokens = preload("res://scripts/ui/theme/ui_tokens.gd")
const Widgets = preload("res://scripts/ui/theme/ui_widgets.gd")
const ACTION_NAMES := {"march": "行军", "continue": "继续行军", "hold": "驻守整顿", "scout": "侦察", "resupply": "补給", "engage": "接战", "besiege": "围城", "pursue": "追击", "withdraw": "撤退", "request_support": "求援", "flank": "侧翼绕行", "support": "协同支援", "reposition":"战术换位", "local_disengage":"准备局部脱离"}
const ARMY_TABS := [["army", "概况"], ["orders", "军令"], ["reports", "战报"]]
## 抽屉的纵向留位：顶栏下方到窗口底边（军报浮条让在抽屉左侧，不再压在抽屉下面）。
const DRAWER_TOP := 88
const DRAWER_BOTTOM := 16
var store: Node
var drawer: PanelContainer
var body: VBoxContainer
var heading: Label
var date_label: Label
var status_label: Label
var next_button: Button
var page := "reports"
var notice_label: Label
var selected_army := ""
var scenario_picker: Button
var toolbar_offset := Vector2(14, 14)
var dispatch_home := ""
var dispatch_view: Control
var inspector: Control
var reports_view: Control
var toast: PanelContainer
var drawer_scroll: ScrollContainer
var panel_timer := 0.0
var battle_label: Label
var result_dialog: AcceptDialog
var _body_page: Control
var _toast_signature := ""


func _ready() -> void:
	layer = 15
	var canvas := Control.new()
	canvas.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	Widgets.adopt_theme(canvas, "glass")
	add_child(canvas)
	if not is_instance_valid(store.war_presentation): _build_toolbar(canvas)
	drawer = SideDrawer.new()
	drawer.offset_top = DRAWER_TOP
	drawer.offset_bottom = -DRAWER_BOTTOM
	canvas.add_child(drawer)
	heading = drawer.title_label
	drawer.tab_selected.connect(_army_tab)
	_body_page = Widgets.vbox(1)
	status_label = Widgets.muted("", true)
	_body_page.add_child(status_label)
	drawer_scroll = ScrollContainer.new()
	drawer_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	drawer_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body_page.add_child(drawer_scroll)
	body = Widgets.vbox(1)
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	drawer_scroll.add_child(body)
	reports_view = _create_reports_view()
	reports_view.store = store
	drawer.host(reports_view)
	drawer.host(_body_page)
	reports_view.army_requested.connect(show_army)
	reports_view.closed.connect(drawer.hide)
	toast = ToastFeed.new()
	toast.anchor_left = 0.0
	toast.anchor_right = 1.0
	toast.offset_left = Tokens.space(4) + Minimap.SIZE.x
	toast.offset_right = -SideDrawer.WIDTH - Tokens.space(4)
	toast.open_requested.connect(show_reports)
	canvas.add_child(toast)
	store.campaign_changed.connect(refresh)
	store.campaign_progress.connect(_refresh_status)
	refresh()


## 2D 地图用的简化工具行：军情、城务、推进、设置与日期。
func _build_toolbar(canvas: Control) -> void:
	var bar := PanelContainer.new()
	bar.theme_type_variation = "BarPanel"
	bar.position = toolbar_offset
	canvas.add_child(bar)
	var toolbar := Widgets.hbox(1)
	bar.add_child(toolbar)
	if store.battle_test:
		scenario_picker = Widgets.secondary("", store.open_battle_scenarios)
		scenario_picker.name = "BattleScenarioPicker"
		toolbar.add_child(scenario_picker)
		battle_label = Widgets.muted("")
		battle_label.position = Vector2(toolbar_offset.x, toolbar_offset.y + 56)
		canvas.add_child(battle_label)
	toolbar.add_child(Widgets.secondary("军情", show_reports))
	if not store.battle_test: toolbar.add_child(Widgets.secondary("城务与人事", show_city_policy))
	if not store.battle_test: toolbar.add_child(Widgets.secondary("人才", show_talents))
	var targets := OptionButton.new()
	targets.add_item("选择出征目标")
	for id in store.war.graph.places:
		targets.add_item(store.war.graph.name_of(str(id)))
		targets.set_item_metadata(targets.item_count - 1, id)
	targets.item_selected.connect(func(index):
		if index > 0: show_dispatch(str(targets.get_item_metadata(index)))
	)
	toolbar.add_child(targets)
	next_button = Widgets.primary("进行", _next_turn)
	next_button.tooltip_text = "推进十天"
	toolbar.add_child(next_button)
	toolbar.add_child(Widgets.secondary("设置", store.open_settings))
	date_label = Widgets.label("")
	date_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	toolbar.add_child(date_label)


func _create_reports_view() -> Control:
	return preload("res://scripts/war/ui/military_reports.gd").new()


func _label(value: String, size: int = 13) -> Label:
	return Widgets.label(value, "NoteLabel" if size <= 13 else "", true)


func _button(value: String, action: Callable) -> Button:
	return Widgets.secondary(value, action)


func _clear() -> void:
	Widgets.clear(body)
	notice_label = null


## 打开抽屉的文字页（部队详情、军令、城务、敌军信息共用），清空 body 供调用方填写。
func open_body(title: String, subtitle := "", tabs: Array = [], active := "") -> void:
	drawer.present(title, subtitle, tabs, active)
	drawer.host(_body_page)
	if is_instance_valid(dispatch_view):
		dispatch_view.queue_free()
		dispatch_view = null
	status_label.hide()
	drawer_scroll.scroll_vertical = 0
	_clear()


func refresh() -> void:
	_refresh_status()
	_refresh_toast()
	if is_instance_valid(reports_view): reports_view.refresh()
	if not drawer.visible:
		return
	if page == "army":
		if is_instance_valid(inspector): inspector.update_info()
	elif page == "army_orders":
		if not store.busy: show_army_orders(selected_army)


func _refresh_status() -> void:
	if is_instance_valid(scenario_picker): scenario_picker.text = "战场：" + str(store.war.state.get("battlefield",{}).get("scenario_name","平原会战")) + "  ▾"
	if not store.war.state.get("campaign_result", {}).is_empty():
		status_label.text = str(store.war.state["campaign_result"]["message"])
		if is_instance_valid(next_button): next_button.disabled = true
		if not is_instance_valid(result_dialog):
			result_dialog = AcceptDialog.new()
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
	if is_instance_valid(date_label): date_label.text = "%s  %s" % [store.date_text(), time_phase_text()]
	if is_instance_valid(next_button): next_button.disabled = store.busy
	if store.agent != null:
		status_label.text = "主帅后台推演  军队沿用当前军令" if store.war.planner.running else str(store.agent.last_status)


## 底部浮条：本方最新送达的一份军报。只在军报数变化时改字。
func _refresh_toast() -> void:
	var player := str(store.war.state["player_faction"])
	var mine: Array = store.war.visible_reports().filter(func(report: Dictionary) -> bool:
		var army: Dictionary = store.war.state["armies"].get(report.get("army_id", ""), {})
		return report.get("faction", army.get("faction", "")) == player)
	var signature := "%d:%s" % [mine.size(), str(mine.back()["id"]) if not mine.is_empty() else ""]
	if signature == _toast_signature: return
	_toast_signature = signature
	if mine.is_empty():
		toast.show_latest("", 0)
		return
	var latest: Dictionary = mine.back()
	var army: Dictionary = store.war.state["armies"].get(latest.get("army_id", ""), {})
	var text := "%s  %s：%s" % [army.get("name", "部队"), latest["kind"], preload("res://scripts/ui/ui_text.gd").clean(str(latest["message"])).replace("\n", " ")]
	toast.show_latest(text, mine.size(), bool(latest.get("urgent", false)))


## 抽屉的「派将」页（出阵编组）：派出或返回后释放，抽屉随之关闭。
func show_dispatch(target: String) -> void:
	if store.busy: return
	if is_instance_valid(dispatch_view): dispatch_view.queue_free()
	var view = preload("res://scripts/war/ui/dispatch_view.gd").new()
	dispatch_view = view
	view.store = store
	view.target = target
	view.home_hint = dispatch_home
	view.dispatched.connect(func(id): dispatch_home = ""; army_dispatched.emit(id); show_reports())
	view.tree_exiting.connect(func() -> void:
		if dispatch_view == view and page == "dispatch": drawer.hide())
	page = "dispatch"
	drawer.present("派将", "出征目标  " + store.war.graph.name_of(target))
	drawer.host(view)


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
	page = "reports"
	drawer.present("军情", _faction_date())
	drawer.host(reports_view)
	reports_view.open()


func show_army_reports(id: String) -> void:
	_present_army(id, "reports")
	page = "army_reports"
	drawer.host(reports_view)
	reports_view.open(id)


func show_review(id: String) -> void:
	_present_army(id, "reports")
	page = "army_reports"
	drawer.host(reports_view)
	reports_view.show_review(id)


func _faction_date() -> String:
	return "%s  ·  %s" % [store.scenario["factions"].get(store.war.state["player_faction"], {}).get("name", "本军"), store.date_text()]


## 部队抽屉的抬头：名称、任务一行与「概况 / 军令 / 战报」分页。
func _present_army(id: String, active: String) -> void:
	var army: Dictionary = store.war.state["armies"].get(id, {})
	selected_army = id
	var action: String = "已结束" if army.get("status", "") == "ended" else "撤往友城" if army.get("returning", false) else ACTION_NAMES.get(str(army.get("action", {}).get("type", "")), "行动中")
	var subtitle := "%s  →  %s" % [action, store.war.graph.name_of(str(army.get("target", "")))]
	drawer.present(str(army.get("name", "部队")), subtitle, ARMY_TABS, active)
	drawer.set_avatar(preload("res://scripts/war/ui/army_inspector.gd").avatar_texture(store, army))


func _army_tab(id: String) -> void:
	match id:
		"army": show_army(selected_army)
		"orders": show_army_orders(selected_army)
		"reports": show_army_reports(selected_army)


## 旧调用方（敌军信息）用的入口；现在等同 open_body 的文字页。
func _prepare_drawer(_kind: String) -> void:
	drawer.host(_body_page)
	status_label.hide()
	drawer_scroll.scroll_vertical = 0


func show_army(id: String) -> void:
	var army: Dictionary = store.war.state["armies"].get(id, {})
	if army.is_empty(): return
	var same: bool = page == "army" and selected_army == id and is_instance_valid(inspector) and drawer.visible
	if same:
		inspector.update_info()
		return
	open_body("", "", [], "")
	_present_army(id, "army")
	page = "army"
	inspector = preload("res://scripts/war/ui/army_inspector.gd").new()
	inspector.store = store
	inspector.army_id = id
	inspector.orders_requested.connect(show_army_orders)
	inspector.reports_requested.connect(show_army_reports)
	inspector.close_requested.connect(drawer.close)
	body.add_child(inspector)


func show_army_orders(id: String) -> void:
	var army: Dictionary = store.war.state["armies"].get(id, {})
	if army.is_empty(): return
	open_body("")
	_present_army(id, "orders")
	page = "army_orders"
	var ended: bool = army["status"] == "ended"
	var corps: Dictionary = store.war.state["corps"].get(army.get("corps_id", ""), {})
	if not corps.is_empty():
		body.add_child(_label("军团编制\n" + preload("res://scripts/war/ui/army_inspector.gd").personnel_text(store.war, corps), 13))
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

## 人才页：寻访在野人才、接洽任用、查看本方人物履历（功能同主线人才页，改用统一主题控件）。
func show_talents(selected: String = "") -> void:
	open_body("人才与履历", _faction_date())
	page = "talents"
	var war = store.war
	war.characters.sync(war)
	var faction_id := str(war.state["player_faction"])
	var owned: Array = war.Operations.cities(war, faction_id)
	if owned.is_empty(): body.add_child(_label("本方暂无城池", 16)); return
	if not owned.has(selected): selected = str(owned[0])
	var cities := OptionButton.new()
	for id in owned:
		cities.add_item(war.graph.name_of(id))
		cities.set_item_metadata(cities.item_count - 1, id)
		if id == selected: cities.select(cities.item_count - 1)
	cities.item_selected.connect(func(index): show_talents(str(cities.get_item_metadata(index))))
	body.add_child(cities)
	body.add_child(_label("安排寻访 · 1行动力，调查3日，另计往返时间", 13))
	var search_row := Widgets.hbox(1)
	body.add_child(search_row)
	var actors := OptionButton.new()
	actors.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for officer in war.available_officers(faction_id):
		actors.add_item(str(officer["name"]))
		actors.set_item_metadata(actors.item_count - 1, officer["id"])
	search_row.add_child(actors)
	var search_button := _button("派员寻访", func():
		var result: Dictionary = war.Talent.investigate(war, str(actors.get_item_metadata(actors.selected)), selected)
		show_talents(selected)
		notice_label.text = str(result["message"])
	)
	search_button.disabled = actors.item_count == 0 or store.busy
	search_row.add_child(search_button)
	for task in war.Talent.state(war)["tasks"].values():
		if task["faction"] == faction_id and task["phase"] != "complete":
			body.add_child(_label("%s · %s · 剩余%d日" % [war.roster.officers[task["actor"]]["name"], "寻访" if task["phase"] == "searching" else "归程", maxi(0, int(task["arrival_tick"]) - int(war.state["tick"]))], 13))
	body.add_child(Widgets.rule())
	body.add_child(_label("已发现的在野人才", 16))
	var count := 0
	for id in war.characters.states:
		var person: Dictionary = war.characters.states[id]
		if person["service_status"] != "wild" or not war.Talent.known(war, faction_id, str(id)): continue
		count += 1
		body.add_child(_label("%s · %s" % [war.characters.definitions[id]["name"], war.graph.name_of(str(person["availability"].get("city", "")))], 14))
		var offers := HFlowContainer.new()
		offers.add_theme_constant_override("h_separation", Tokens.space(1))
		offers.add_theme_constant_override("v_separation", Tokens.space(1))
		body.add_child(offers)
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
			offers.add_child(button)
	if count == 0: body.add_child(_label("尚无已发现的在野人才，可先派员寻访。", 13))
	body.add_child(Widgets.rule())
	body.add_child(_label("本方人物履历", 16))
	for id in war.characters.states:
		var person: Dictionary = war.characters.states[id]
		if person["faction_id"] != faction_id: continue
		var target := str(id)
		var entry := Widgets.text_button(str(war.characters.definitions[id]["name"]) + " · " + str(person["events"].size()) + "条记录", func(): show_character_history(target, selected))
		entry.alignment = HORIZONTAL_ALIGNMENT_LEFT
		body.add_child(entry)
	notice_label = _label("人才接洽需要本城可用人员，岗位已有任职者时不能许诺该岗位。", 13)
	body.add_child(notice_label)


## 人物履历：五维、各岗位适岗度与最近 25 条经历事件。
func show_character_history(id: String, city: String) -> void:
	var system = store.war.characters
	var person: Dictionary = system.states[id]
	var view: Dictionary = system.view(id)
	open_body("人物履历", str(view["name"]))
	page = "talents"
	body.add_child(_button("返回人才", func(): show_talents(city)))
	body.add_child(_label(str(view["name"]), 20))
	var names := ["军事", "谋略", "勇武", "政务", "影响"]
	var dims := GridContainer.new()
	dims.columns = 2
	dims.add_theme_constant_override("h_separation", Tokens.space(3))
	body.add_child(dims)
	for index in names.size():
		var dimension: Variant = view["dimensions"][index]
		dims.add_child(_label(str(names[index]) + "  " + (str(roundi(float(dimension))) if dimension != null else "待标定"), 14))
	var job_names := {"commander":"主将", "strategist":"军师", "vanguard":"先锋", "deputy":"副将", "governor":"太守", "diplomat":"外交使者"}
	var fits := GridContainer.new()
	fits.columns = 2
	fits.add_theme_constant_override("h_separation", Tokens.space(3))
	body.add_child(fits)
	for job in system.JOBS:
		var fit: Dictionary = system.job_fit(id, str(job))
		fits.add_child(_label(str(job_names[job]) + "适岗  " + ("%.0f%%" % (float(fit["score"]) * 100.0) if fit["known"] else "资料待补全"), 13))
	body.add_child(Widgets.rule())
	body.add_child(_label("经历与关系事件", 16))
	var kinds := {"appointment":"任命", "duty":"履职", "learning":"有效学习", "attribute_growth":"能力成长", "relation":"关系变化", "service_transition":"身份变化", "legacy_experience":"旧档经历", "talent_search":"寻访安排", "talent_discovered":"发现人才", "recruitment_offer":"招募接洽"}
	for event in person["events"].slice(maxi(0, person["events"].size() - 25)):
		var kind := str(event["kind"])
		var description := str(kinds.get(kind, "经历记录"))
		if kind == "attribute_growth": description += " · %s %.2f → %.2f" % [event["detail"]["attribute"], float(event["detail"]["before"]), float(event["detail"]["after"])]
		body.add_child(_label("第%d日 · %s" % [int(event["tick"]), description], 13))
	if person["events"].is_empty(): body.add_child(_label("尚无履职记录", 13))


func show_city_policy(selected: String = "") -> void:
	open_body("城务与人事", _faction_date())
	page = "city_policy"
	var owned: Array = store.war.Operations.cities(store.war, str(store.war.state["player_faction"]))
	if owned.is_empty(): body.add_child(_label("本方暂无城池", 16)); return
	if not owned.has(selected): selected = str(owned[0])
	var cities := OptionButton.new()
	for id in owned:
		cities.add_item(store.war.graph.name_of(id))
		cities.set_item_metadata(cities.item_count - 1, id)
		if id == selected: cities.select(cities.item_count - 1)
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
		body.add_child(choice)
	var delegated := CheckButton.new()
	delegated.text = "委任太守经营"
	delegated.tooltip_text = "经营消耗本方行动力与城市资源"
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


func _next_turn() -> void:
	if store.busy:
		if _continuous(): store.toggle_time_pause()
		return
	await store.advance_turn()
	show_reports()


func _toggle_time() -> void:
	if store.busy:
		store.toggle_time_pause()
		return
	await store.advance_turn()
	show_reports()

## 时间阶段与推进进度，如「下令」「进行 40%」；顶栏与 2D 工具行共用。
func time_phase_text() -> String:
	var phase: String = "下令" if store.time_phase == "strategy" else "旬报" if store.time_phase == "report" else "暂停" if store.time_paused else "进行"
	if not store.busy or store.turn_days_total <= 0: return phase
	var fraction := 0.0
	if is_instance_valid(store.war_presentation) and store.war_presentation.presenting:
		fraction = clampf(store.war_presentation.presentation_elapsed / store.war_presentation.DAY_SECONDS, 0, 1)
	return "%s %d%%" % [phase, int(100 * (store.turn_days_done + fraction) / store.turn_days_total)]


## 3D 大地图上时间连续流动（空格暂停 / 继续）；2D 地图按十日一推。
func _continuous() -> bool:
	return is_instance_valid(store.war_presentation)


func _process(_delta: float) -> void:
	panel_timer += _delta
	if panel_timer >= 0.3:
		panel_timer = 0.0
		if drawer.visible and page == "army" and is_instance_valid(inspector): inspector.update_info()
		if is_instance_valid(reports_view): reports_view.refresh()
	if is_instance_valid(date_label) and store.busy: date_label.text = "%s  %s" % [store.date_text(), time_phase_text()]
	if store.busy and store.agent != null and is_instance_valid(status_label): status_label.text = str(store.agent.last_status)
	if is_instance_valid(battle_label) and store.agent != null and store.war.state.has("battlefield"):
		var metrics: Dictionary = store.agent.metrics
		battle_label.text = "%s  种子%d\n%s  累计请求%d / 失败%d / 回退%d" % [store.war.state["battlefield"].get("scenario_name", "小沛攻防"), store.war.state["battlefield"].get("seed", 1910901), "当前模型：" + str(store.agent.model) if store.agent.enabled else "本地策略（请在设置中启用模型）", metrics.get("calls", 0), metrics.get("failures", 0), metrics.get("fallbacks", 0)]

func _unhandled_key_input(event: InputEvent) -> void:
	if not _continuous(): return
	if get_viewport().gui_get_focus_owner() is LineEdit or get_viewport().gui_get_focus_owner() is TextEdit: return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_SPACE:
		_toggle_time()
		get_viewport().set_input_as_handled()

func show_battle_summary() -> void:
	page = "reports"
	drawer.present("会战总结", _faction_date())
	drawer.host(reports_view)
	reports_view.show_summary()
