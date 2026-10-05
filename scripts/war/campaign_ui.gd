extends CanvasLayer

signal army_dispatched(id: String)

const CitySkin = preload("res://scripts/city_ui_skin.gd")
const Feedback = preload("res://scripts/war/battle_feedback.gd")
const Formation = preload("res://scripts/war/battle_formation.gd")
const ACTION_NAMES := {"march": "行军", "continue": "继续行军", "hold": "驻守整顿", "scout": "侦察", "resupply": "补給", "engage": "接战", "besiege": "围城", "pursue": "追击", "withdraw": "撤退", "request_support": "求援", "flank": "侧翼绕行", "support": "协同支援"}
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
var reports_signature: String = ""
var selected_army := ""
var toolbar_offset := Vector2(14, 14)
var dispatch_home := ""
var flow_button: Button
var speed_choice: OptionButton
var dispatch_view: Control
var battle_label: Label


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
	if is_instance_valid(store.war_presentation): toolbar.hide()
	if store.battle_test:
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
	drawer.offset_left = -440
	drawer.offset_right = -12
	drawer.offset_top = 60
	drawer.offset_bottom = -12
	drawer.add_theme_stylebox_override("panel", CitySkin.paper(0.98, 16))
	canvas.add_child(drawer)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	drawer.add_child(column)
	var top := HBoxContainer.new()
	column.add_child(top)
	heading = _label("军情", 24)
	heading.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(heading)
	top.add_child(_button("关闭", func(): drawer.hide()))
	var tabs := HBoxContainer.new()
	column.add_child(tabs)
	tabs.add_child(_button("军报", show_reports))
	status_label = _label("", 13)
	column.add_child(status_label)
	column.add_child(HSeparator.new())
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	column.add_child(scroll)
	body = VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 10)
	scroll.add_child(body)
	drawer.hide()
	store.campaign_changed.connect(refresh)
	store.campaign_progress.connect(_refresh_status)
	store.city_changed.connect(func(_id):
		if not store.busy and drawer.visible and page == "dispatch": _update_preview()
	)
	refresh()


func _label(value: String, size: int = 16) -> Label:
	var label := CitySkin.label(value, size)
	label.add_theme_font_override("font", CitySkin.font())
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return label


func _button(value: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = value
	button.custom_minimum_size.y = 34
	button.add_theme_font_override("font", CitySkin.font())
	button.add_theme_font_size_override("font_size", 16)
	CitySkin.style_button(button)
	button.pressed.connect(action)
	return button


func _clear() -> void:
	reports_signature = ""
	for child in body.get_children():
		body.remove_child(child)
		child.queue_free()
	preview_label = null
	confirm_button = null
	notice_label = null


func refresh() -> void:
	_refresh_status()
	if not drawer.visible:
		return
	if page == "dispatch":
		if not store.busy: _update_preview()
	elif page == "reports":
		var signature: String = _reports_signature()
		if signature != reports_signature:
			_build_reports()
			reports_signature = signature
	elif page == "army":
		show_army(selected_army)
	elif page == "battle_summary" and reports_signature != _reports_signature():
		show_battle_summary()


func _refresh_status() -> void:
	_refresh_time_label()
	if is_instance_valid(flow_button):
		flow_button.text = ("继续" if store.time_paused else "暂停") if store.busy else "进行"
	next_button.disabled = store.busy and not is_instance_valid(flow_button)
	if store.agent != null:
		status_label.text = "主帅后台推演 · 军队沿用当前军令" if store.war.planner.running else str(store.agent.last_status)
	if store.busy and is_instance_valid(confirm_button):
		confirm_button.disabled = true


func _reports_signature() -> String:
	# Only delivered reports and newly dispatched armies change this page.
	var ids: Array = [store.war.state["player_faction"]]
	ids.append([store.war.state["tick"], Feedback.book(store.war).get("log",[]).size()])
	for army in store.war.state["armies"].values():
		if str(army["faction"]) == str(store.war.state["player_faction"]):
			ids.append([army["id"], army.get("last_report", {}).get("id", "")])
	for report in store.war.visible_reports():
		ids.append(report["id"])
	return JSON.stringify(ids)


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
	heading.text = "派将 · " + store.war.graph.name_of(target)
	drawer.show()
	_clear()
	body.add_child(_label("选择主帅与随军人员，按人物位置编为一支军团；主帅统一下令、调兵与拆队。", 15))
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
	var factions: Array = store.war.rules["faction_mapping"].values()
	factions.sort()
	for faction in factions:
		faction_choice.add_item(str(store.scenario["factions"][faction]["name"]))
		faction_choice.set_item_metadata(faction_choice.item_count - 1, faction)
		if faction == store.war.state["player_faction"]:
			faction_choice.select(faction_choice.item_count - 1)
	faction_choice.disabled = not store.war.active_armies(str(store.war.state["player_faction"])).is_empty()
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
		source_choice.add_item("%s · 驻军%d" % [store.war.graph.name_of(str(id)), int(city.get("garrison", 0))])
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
		officer_choice.add_item("%s · 带兵%d" % [officer["name"], int(officer["skills"].get("带兵", 50))])
		officer_choice.set_item_metadata(officer_choice.item_count - 1, officer["id"])
	officer_choice.item_selected.connect(func(_index): _update_preview())
	body.add_child(officer_choice)
	body.add_child(_label("随军人员 · 按核心／次选位置任职", 16))
	companion_checks.clear()
	for officer in store.war.available_officers(str(store.war.state["player_faction"])):
		var check := CheckButton.new()
		check.text = officer["name"] + " · " + str(officer.get("positions", "")).split("\n")[0]
		check.button_pressed = true
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
	for officer in companion_checks:
		companion_checks[officer].disabled = officer == id
	var preview: Dictionary = store.war.preview_dispatch(home, target_id, id)
	confirm_button.disabled = store.busy or not bool(preview["ok"])
	if not bool(preview["ok"]):
		preview_label.text = str(preview["message"])
		return
	var officer: Dictionary = store.war.roster.officers[id]
	var personality: Dictionary = officer["personality"]
	preview_label.text = "%s%s\n\n自动动员 %d 人\n携粮 %d · 约 %d 日\n留守 %d 人\n最短通路约 %d 日，实际路线由主将决定\n\n风险承受 %d · 耐心 %d · 决断 %d\n%s" % ["守援" if preview["mission_type"] == "defend" else "攻取", store.war.graph.name_of(target_id), int(preview["strength"]), int(preview["grain"]), int(preview["grain_days"]), int(preview["reserve"]), int(preview["travel_days"]), int(personality["风险承受"]), int(personality["耐心"]), int(personality["决断"]), str(officer["profile_note"])]


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
	var was_reports: bool = page == "reports"
	page = "reports"
	heading.text = "军情与战报"
	drawer.show()
	if not was_reports: reports_signature = ""
	refresh()


func _build_reports() -> void:
	_clear()
	var faction: String = str(store.war.state["player_faction"])
	body.add_child(_label("%s · 军情截至收到的最新报告" % str(store.scenario["factions"].get(faction, {}).get("name", "")), 15))
	if not Feedback.book(store.war).get("log",[]).is_empty():
		var overview := Feedback.summary(store.war)
		body.add_child(_label("会战总结 · %d日 · 单挑%d次
%s" % [overview["days"],overview["duels"],overview["winner"]],18))
		body.add_child(_button("查看会战时间线与兵员账本",show_battle_summary))
	var own_armies: Array = []
	for army in store.war.state["armies"].values():
		if str(army["faction"]) == faction: own_armies.append(army)
	if own_armies.is_empty():
		body.add_child(_label("尚无出征军队。选择目标城后点击“派遣武将”。", 16))
	for army in own_armies:
		var report: Dictionary = army.get("last_report", {})
		var text: String = "%s → %s\n" % [army["name"], store.war.graph.name_of(str(army["target"]))]
		if report.is_empty():
			text += "军队已受命，首份军报尚未送达。"
		else:
			var snapshot: Dictionary = report["snapshot"]
			text += "%s · %s\n%s" % [report["sent_date"], report["kind"], report["message"]]
			if not str(snapshot.get("reason", "")).is_empty(): text += "\n将领判断：" + str(snapshot["reason"])
		body.add_child(_label(text, 16))
		var detail_id: String = str(army["id"])
		body.add_child(_button("军队详情与命令", func(): show_army(detail_id)))
		if not report.is_empty() and bool(report["snapshot"].get("ended", false)):
			var army_id: String = str(army["id"])
			body.add_child(_button("查看战役复盘", func(): show_review(army_id)))
		body.add_child(HSeparator.new())
	var reports: Array = store.war.visible_reports()
	if not reports.is_empty(): body.add_child(_label("最近军报", 20))
	for index in range(mini(reports.size(), 30)):
		var report: Dictionary = reports[index]
		body.add_child(_label("%s · %s\n%s\n收到：%s" % [report["sent_date"], report["kind"], report["message"], report.get("received_date", "")], 14))
		body.add_child(HSeparator.new())


func show_review(army_id: String) -> void:
	page = "review"
	heading.text = "战役复盘"
	_clear()
	var army: Dictionary = store.war.state["armies"].get(army_id, {})
	if army.is_empty(): return
	body.add_child(_label("%s · %s\n出征%d，阵亡%d，伤兵%d，被俘%d，归队%d。" % [army["name"], army["outcome"], int(army["initial_strength"]), int(army["dead"]), int(army["wounded"]), int(army["captured"]), int(army.get("returned_strength", 0))], 17))
	for decision in army.get("decision_history", store.war.state["decisions"]):
		if decision["army_id"] != army_id: continue
		var observation: Dictionary = decision.get("observation", {})
		var enemies: Array = observation.get("enemies", [])
		var seen: String = "未发现敌军" if enemies.is_empty() else "已知敌军："
		for enemy in enemies: seen += "约%d人；" % int(enemy.get("strength_estimate", 0))
		body.add_child(_label("%s · %s\n当时情报：%s\n余粮约%d日，士气%d\n决定：%s\n依据：%s" % [observation.get("date", ""), "智能体" if decision["source"] == "model" else "本地策略", seen, int(observation.get("army", {}).get("grain_days", 0)), int(observation.get("army", {}).get("morale", 0)), ACTION_NAMES.get(decision["action"]["type"], "行动"), decision["reason_summary"]], 14))


func show_army(id: String) -> void:
	var army: Dictionary = store.war.state["armies"].get(id, {})
	if army.is_empty(): return
	selected_army = id
	page = "army"
	heading.text = str(army["name"]) + ("" if army.has("corps_id") else "队")
	drawer.show()
	_clear()
	var army_header := HBoxContainer.new()
	army_header.add_theme_constant_override("separation", 12)
	body.add_child(army_header)
	var portrait_data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/officer_portraits.json"))
	var portrait_path: String = str(portrait_data.get(store.war.roster.officers[army["officer_id"]]["name"], {}).get("portrait", ""))
	if FileAccess.file_exists(portrait_path):
		var portrait := TextureRect.new()
		portrait.texture = load(portrait_path)
		portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		portrait.custom_minimum_size = Vector2(100, 115)
		army_header.add_child(portrait)
	var ended: bool = army["status"] == "ended"
	var troops: int = store.war.Combat.strength(army)
	army_header.add_child(_label("兵力  %d    伤兵  %d\n士气  %d    组织  %d\n余粮  约 %d 日\n疲劳  %d" % [troops, int(army["wounded"]), int(army["morale"]), int(army["organization"]), int(float(army["grain"]) / maxf(store.war.daily_food(army), 0.001)), int(army["fatigue"])], 19))
	body.add_child(_label("目标：%s\n状态：%s\n主将判断：%s" % [store.war.graph.name_of(str(army["target"])), str(army["outcome"]) if ended else ("撤往友城" if army["returning"] else ACTION_NAMES.get(army["action"]["type"], "待命")), army["last_reason"]], 16))
	var corps: Dictionary = store.war.state["corps"].get(army.get("corps_id", ""), {})
	var siege: Dictionary = store.war.state.get("sieges", {}).get(army["target"], {})
	if not siege.is_empty():
		body.add_child(_label("攻城 · %s\n城墙 %d / %d　准备 %d%%\n守军士气 %d　城内余粮约%d日\n方式：%s" % [siege["phase"], int(siege["wall"]), int(siege["wall_max"]), int(siege["preparation"]), int(siege["morale"]), int(siege.get("grain_days", 0)), "强攻" if siege["mode"] == "assault" else "围困"], 16))
	if not corps.is_empty():
		var overview: Dictionary = store.war.Corps.summary(store.war, corps)
		if overview["deployment_pending"]: body.add_child(_label("全军尚未展开：随军人员在军团内，主帅将决定分兵部署。", 16))
		body.add_child(_label("主阵：%s　熟练度 %.2f%s" % [Formation.name_of(corps.get("formation","none")),Formation.proficiency(army,store.war.rules)," · " + corps.get("formation_progress","整阵") + "，停止移动和攻击" if army.get("formation_locked",false) else ""],16))
		body.add_child(_label("所属：%s · 总兵力 %d · 分队 %d\n主帅：%s · 本队任务：%s\n粮道储备 %d · %s" % [corps["name"], overview["strength"], overview["units"].size(), store.war.roster.officers[corps["commander_id"]]["name"], store.war.Corps.TASKS.get(army.get("corps_task", {}).get("type", ""), "待命"), int(corps["supply"]["stock"]), "被截断至第%d日" % corps["supply"]["blocked_until"] if int(corps["supply"]["blocked_until"]) > int(store.war.state["tick"]) else "畅通"], 16))
		if not ended and not army["returning"]:
			var choice := OptionButton.new()
			choice.name = "FormationChoice"
			for formation in Formation.definitions(store.war.rules):
				choice.add_item(Formation.name_of(formation))
				choice.set_item_metadata(choice.item_count-1,formation)
				if formation == corps.get("formation","none"): choice.select(choice.item_count-1)
			body.add_child(choice)
			var change_button := _button("下令变阵 · 组织-%d，下一日整阵" % int(store.war.rules["formations"]["change_organization"]),func():
				var result: Dictionary = store.war.command_formation(id,choice.get_item_metadata(choice.selected))
				if not result.get("ok",false): body.add_child(_label(result.get("message","无法变阵"),14))
			)
			change_button.name = "ChangeFormation"
			change_button.disabled = store.busy or not Formation.can_change(store.war,corps,str(choice.get_item_metadata(choice.selected)))
			choice.item_selected.connect(func(index): change_button.disabled = store.busy or not Formation.can_change(store.war,corps,str(choice.get_item_metadata(index))))
			body.add_child(change_button)
		var appointments: String = "军团任职：\n"
		for officer in corps["appointments"]: appointments += "%s：%s  " % [store.war.roster.officers[officer]["name"], corps["appointments"][officer]]
		body.add_child(_label(appointments, 14))
		for unit in overview["units"]:
			if unit["id"] != id:
				var unit_id: String = unit["id"]
				body.add_child(_button("%s · %d · %s" % [unit["officer"], unit["strength"], store.war.Corps.TASKS.get(unit["task"]["type"], "待命")], func(): show_army(unit_id)))
		for order in corps["orders"].slice(-3): body.add_child(_label("第%d日主帅军令 · %s\n%s · %s" % [order["tick"], "主公" if order["source"] == "player" else "模型" if order["source"] == "model" else "本地策略", order["reason"], "已下达" if order["applied"].get("ok", false) else "执行条件不满足"], 14))
	if army.get("duel_wounded",false): body.add_child(_label("主将单挑负伤 · 带伤指挥攻击降低，战后休养%d日" % int(store.war.rules["duel"]["recover_days"]),16))
	if army.has("tactical"): body.add_child(_label("所在格地形：" + store.war.Terrain.name_of(store.war.Tactical.terrain_class(army["tactical"]["cell"])),15))
	var skills: Dictionary = army["skills"]
	var battle = preload("res://scripts/war/officer_battle.gd")
	var recovery := battle.recovery(army)
	body.add_child(_label("将领作战修正 · 步兵 %.0f%% / 弓兵 %.0f%% / 骑兵 %.0f%%\n休整恢复 · 疲劳 %.1f / 组织 %.1f / 士气 %.1f\n超过100的属性采用递减收益" % [battle.unit_attack(army, "infantry", "plains") * 100, battle.unit_attack(army, "archers", "plains") * 100, battle.unit_attack(army, "cavalry", "plains") * 100, recovery["fatigue"], recovery["organization"], recovery["morale"]], 14))
	var operation: Dictionary = army.get("operation", {})
	if not operation.is_empty():
		var names := preload("res://scripts/war/tactical_battlefield.gd").ROLES
		var commander: Dictionary = store.war.state["armies"].get(operation.get("commander", ""), {})
		var partner: Dictionary = store.war.state["armies"].get(operation.get("support_id", ""), {})
		var target: Dictionary = store.war.state["armies"].get(army.get("tactical", {}).get("attack_target", operation.get("suggested_target", "")), {})
		body.add_child(_label("职责：%s · 主帅：%s\n协同对象：%s · 攻击目标：%s\n当前阶段：%s\n计划依据：%s" % [names.get(operation.get("role", ""), "自主行动"), commander.get("name", "无"), partner.get("name", "无"), (target.get("name", "未接敌") if store.battle_test or target.is_empty() else "已发现敌军"), army.get("tactical", {}).get("phase", ACTION_NAMES.get(army["action"]["type"], "待命")), operation.get("change_reason", "")], 15))
		if army.has("tactical"):
			var contact: Dictionary = store.war.Tactical.contact_state(store.war, army)
			body.add_child(_label("接战敌军：%d · 掩护友军：%d\n脱离准备：%d/%d 日 · 当前阵线列：%d" % [contact["adjacent_enemies"], contact["covered_by"], army["tactical"].get("withdraw_preparation", 0), contact["required_preparation"] if contact["adjacent_enemies"] > 0 else 0, army["tactical"].get("lane", 0)], 15))
	if not ended:
		var context: Dictionary = store.war.context_for(army)
		var battlefield: Dictionary = context["battlefield"]
		var supporting: Array = context["allies"].filter(func(friend): return friend["can_support"])
		body.add_child(_label("邻近可协同友军 %d 支\n己方合计 %d · 附近敌军估计 %d" % [supporting.size(), battlefield["friendly_ready_strength"], battlefield["enemy_estimated_strength"]], 15))
	if army.has("morale_change") and int(army.get("combat_tick", -1)) == int(store.war.state["tick"]):
		body.add_child(_label("本日军心 %+.1f · %s" % [float(army["morale_change"]), army.get("morale_reason", "")], 14))
	if army["returning"]:
		body.add_child(_label("撤离原因：" + str(army.get("retreat_reason", army.get("outcome", "奉军令撤离"))), 14))
	body.add_child(_label("带兵 %d · 布阵 %d · 治军 %d\n训练 %d · 军备 %d" % [int(skills.get("带兵", 50)), int(skills.get("布阵", 50)), int(skills.get("治军", 50)), int(army["training"]), int(army["equipment"])], 15))
	body.add_child(HSeparator.new())
	var withdraw_button := _button("全军撤退" if not corps.is_empty() and corps["root_id"] == id else "本队撤退", func():
		var result: Dictionary = store.war.command_army(id, {}, true)
		show_army(id)
		body.add_child(_label(str(result["message"]), 15))
	)
	withdraw_button.name = "WithdrawArmy"
	withdraw_button.disabled = ended or store.busy or bool(army["returning"])
	body.add_child(withdraw_button)
	body.add_child(_label("设定军令", 20))
	var orders: Dictionary = store.war.orders_for(army)
	for spec in [["敌军接近时", "engage", "攻击", "无视"], ["自主撤退", "retreat", "许可", "不许"], ["追击败军", "pursue", "许可", "不许"], ["攻取后命令", "after_battle", "撤退", "待命"]]:
		var row := HBoxContainer.new()
		body.add_child(row)
		row.add_child(_label(spec[0], 16))
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
	if ended: body.add_child(_button("查看战役复盘", func(): show_review(id)))


func show_settings() -> void:
	store.open_settings()


func _style_field(control: Control) -> void:
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
	date_label.text = "%s %s · %s%s" % [store.date_text(), period, phase, progress]

func _process(_delta: float) -> void:
	if is_instance_valid(date_label) and store.busy: _refresh_time_label()
	if store.busy and store.agent != null and is_instance_valid(status_label): status_label.text = str(store.agent.last_status)
	if is_instance_valid(battle_label) and store.agent != null:
		var metrics: Dictionary = store.agent.metrics
		battle_label.text = "小沛军团测试 · 18人随军 · 2位主帅 · 双方各2万人\n%s · 累计请求%d / 失败%d / 回退%d" % ["当前模型：" + str(store.agent.model) if store.agent.enabled else "本地策略（请在设置中启用模型）", metrics.get("calls", 0), metrics.get("failures", 0), metrics.get("fallbacks", 0)]

func _unhandled_key_input(event: InputEvent) -> void:
	if not is_instance_valid(flow_button): return
	if get_viewport().gui_get_focus_owner() is LineEdit or get_viewport().gui_get_focus_owner() is TextEdit: return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_SPACE:
		_toggle_time()
		get_viewport().set_input_as_handled()

func show_battle_summary() -> void:
	page = "battle_summary"
	heading.text = "会战总结"
	drawer.show()
	_clear()
	reports_signature = _reports_signature()
	var summary := Feedback.summary(store.war)
	var winner_name: String = "平局" if summary["winner"] == "draw" else store.scenario["factions"].get(summary["winner"],{}).get("name",summary["winner"])
	body.add_child(_label("持续%d日 · %s
挑战%d次 / 单挑%d次 · 压倒胜出%d次（负伤）" % [summary["days"],winner_name,summary["challenges"],summary["duels"],summary["overwhelming"]],18))
	for row in summary["sides"]:
		if not store.battle_test and summary["winner"] == "交战中" and row["faction"] != store.war.state["player_faction"]: continue
		body.add_child(_label("%s
初始%d = 现存%d + 阵亡%d + 伤%d + 俘%d + 归队/留驻%d
账本：%s" % [store.scenario["factions"].get(row["faction"],{}).get("name",row["faction"]),row["initial"],row["strength"],row["dead"],row["wounded"],row["captured"],row["deposited"],"守恒" if row["initial"] == row["accounted"] else "需核对"],15))
		body.add_child(_label("截获粮草：%d" % int(summary["loot"].get(row["faction"],0)),15))
	for siege in summary["sieges"]:
		if not store.battle_test and summary["winner"] == "交战中" and siege["attacker"] != store.war.state["player_faction"]: continue
		body.add_child(_label("%s攻防：%s · 城墙%d/%d
城内守军累计损失%d · 攻城部队累计损失%d" % [store.war.graph.name_of(siege["city"]),"已夺城" if siege["phase"] == "occupied" else siege["phase"],siege["wall"],siege["wall_max"],siege["defender_losses"],siege["losses"]],15))
	body.add_child(_label("逐日时间线",18))
	for entry in summary["log"]:
		var lines := PackedStringArray(["第%d日" % entry["tick"]])
		for side in entry["sides"]:
			if not store.battle_test and summary["winner"] == "交战中" and side["faction"] != store.war.state["player_faction"]: continue
			lines.append("%s：%d人 · 士气%.0f · 组织%.0f · 本日损失%d" % [store.scenario["factions"].get(side["faction"],{}).get("name",side["faction"]),side["strength"],side["morale"],side["org"],entry["losses"].get(side["faction"],0)])
		for event in entry["events"]:
			if store.battle_test or event["faction"] in ["",store.war.state["player_faction"]] or summary["winner"] != "交战中": lines.append(event["kind"] + " · " + event["message"])
		body.add_child(_label("\n".join(lines),14))
		body.add_child(HSeparator.new())
	body.add_child(_button("返回军报",show_reports))
