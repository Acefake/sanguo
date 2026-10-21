extends Control

signal army_requested(id: String)
signal closed
const UISkin = preload("res://scripts/war/ui/war_ui_skin.gd")
const Feedback = preload("res://scripts/war/battle/battle_feedback.gd")
var store: Node
var window: PanelContainer
var report_list: VBoxContainer
var detail: VBoxContainer
var list_scroll: ScrollContainer
var detail_scroll: ScrollContainer
var subtitle: Label
var count_label: Label
var army_filter: OptionButton
var kind_filter: OptionButton
var report_tab: Button
var summary_tab: Button
var filter_army := ""
var selected_report := ""
var mode := "reports"
var signature := ""
var portraits: Dictionary = {}
var entries: Array = []

func _ready() -> void:
	name = "MilitaryReports"
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	mouse_filter = MOUSE_FILTER_STOP
	portraits = JSON.parse_string(FileAccess.get_file_as_string("res://data/officer_portraits.json"))
	var shade := ColorRect.new()
	shade.color = Color(0.07, 0.06, 0.045, 0.55)
	shade.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	shade.mouse_filter = MOUSE_FILTER_STOP
	add_child(shade)
	window = UISkin.framed_panel(22)
	window.set_anchors_and_offsets_preset(PRESET_CENTER)
	add_child(window)
	_resize()
	resized.connect(_resize)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 14)
	window.add_child(column)
	var header := HBoxContainer.new()
	var header_panel := PanelContainer.new()
	header_panel.add_theme_stylebox_override("panel", UISkin.ribbon(10))
	column.add_child(header_panel)
	header_panel.add_child(header)
	var title_box := VBoxContainer.new()
	title_box.size_flags_horizontal = SIZE_EXPAND_FILL
	header.add_child(title_box)
	var title := UISkin.label("军报簿", 23, Color("f2e5c6"))
	title.add_theme_font_override("font", UISkin.CitySkin.font())
	title_box.add_child(title)
	subtitle = UISkin.label("", 12, Color("cebd9c"))
	title_box.add_child(subtitle)
	var close := UISkin.button("关闭", close_view, true)
	close.name = "CloseReports"
	close.size_flags_vertical = SIZE_SHRINK_CENTER
	header.add_child(close)
	var nav := HBoxContainer.new()
	nav.add_theme_constant_override("separation", 6)
	column.add_child(nav)
	report_tab = UISkin.button("送达军报", func(): mode = "reports"; rebuild())
	report_tab.name = "ReportsTab"
	summary_tab = UISkin.button("当前总结", show_summary)
	summary_tab.name = "SummaryTab"
	nav.add_child(report_tab)
	nav.add_child(summary_tab)
	count_label = UISkin.label("", 12, UISkin.MUTED)
	count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	nav.add_child(count_label)
	var separator := HSeparator.new()
	column.add_child(separator)
	var content := HBoxContainer.new()
	content.size_flags_vertical = SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 24)
	column.add_child(content)
	var left := VBoxContainer.new()
	left.custom_minimum_size.x = 224
	left.add_theme_constant_override("separation", 8)
	content.add_child(left)
	army_filter = OptionButton.new()
	army_filter.name = "ReportArmyFilter"
	UISkin.field(army_filter)
	army_filter.item_selected.connect(func(index):
		filter_army = str(army_filter.get_item_metadata(index))
		selected_report = ""
		rebuild()
	)
	left.add_child(army_filter)
	kind_filter = OptionButton.new()
	kind_filter.name = "ReportKindFilter"
	UISkin.field(kind_filter)
	for title_text in ["全部军报", "交战与攻城", "军令与调动", "补给与求援"]: kind_filter.add_item(title_text)
	kind_filter.item_selected.connect(func(_index): selected_report = ""; rebuild())
	left.add_child(kind_filter)
	list_scroll = ScrollContainer.new()
	list_scroll.size_flags_vertical = SIZE_EXPAND_FILL
	UISkin.scroll(list_scroll)
	left.add_child(list_scroll)
	report_list = VBoxContainer.new()
	report_list.size_flags_horizontal = SIZE_EXPAND_FILL
	report_list.add_theme_constant_override("separation", 4)
	list_scroll.add_child(report_list)
	var divider := VSeparator.new()
	content.add_child(divider)
	detail_scroll = ScrollContainer.new()
	detail_scroll.size_flags_horizontal = SIZE_EXPAND_FILL
	detail_scroll.size_flags_vertical = SIZE_EXPAND_FILL
	UISkin.scroll(detail_scroll)
	var reading := UISkin.framed_panel(20)
	reading.size_flags_horizontal = SIZE_EXPAND_FILL
	reading.size_flags_vertical = SIZE_EXPAND_FILL
	content.add_child(reading)
	reading.add_child(detail_scroll)
	detail = VBoxContainer.new()
	detail.size_flags_horizontal = SIZE_EXPAND_FILL
	detail.add_theme_constant_override("separation", 14)
	detail_scroll.add_child(detail)
	var footer := UISkin.label("军报按送达时间归档；数值保留发报时的快照。", 11, UISkin.MUTED)
	column.add_child(footer)
	hide()
	get_viewport().size_changed.connect(_resize)

func _resize() -> void:
	if not is_instance_valid(window): return
	var extent := Vector2(minf(980, size.x - 48), minf(600, size.y - 48))
	window.offset_left = -extent.x / 2
	window.offset_right = extent.x / 2
	window.offset_top = -extent.y / 2
	window.offset_bottom = extent.y / 2

func close_view() -> void:
	hide()
	closed.emit()

func open(army_id: String = "") -> void:
	if visible and mode == "reports" and filter_army == army_id:
		refresh()
		return
	filter_army = army_id
	selected_report = ""
	mode = "reports"
	kind_filter.select(0)
	_populate_filters()
	show()
	rebuild()

func show_summary() -> void:
	mode = "summary"
	show()
	rebuild()

func _populate_filters() -> void:
	army_filter.clear()
	army_filter.add_item("全部部队")
	army_filter.set_item_metadata(0, "")
	for army in store.war.state["armies"].values():
		if army["faction"] != store.war.state["player_faction"]: continue
		army_filter.add_item(str(army["name"]))
		army_filter.set_item_metadata(army_filter.item_count - 1, army["id"])
		if army["id"] == filter_army: army_filter.select(army_filter.item_count - 1)

func refresh() -> void:
	if not visible: return
	# Archive pages update at the end of an advance, rather than rebuilding the
	# whole list for every intermediate day. The live inspector updates separately.
	if store.busy: return
	if mode == "review": return
	var changed := JSON.stringify([store.war.state["tick"], store.war.state["reports"].size(), store.war.visible_reports().size(), store.war.state["armies"].size()])
	if changed == signature: return
	var previous_report := selected_report
	var list_position := list_scroll.scroll_vertical
	var detail_position := detail_scroll.scroll_vertical
	_populate_filters()
	rebuild()
	list_scroll.set_deferred("scroll_vertical", list_position)
	if previous_report == selected_report: detail_scroll.set_deferred("scroll_vertical", detail_position)

func _matches(report: Dictionary) -> bool:
	var army: Dictionary = store.war.state["armies"].get(report.get("army_id", ""), {})
	if report.get("faction", army.get("faction", "")) != store.war.state["player_faction"]: return false
	if filter_army != "" and report["army_id"] != filter_army: return false
	var kind := str(report["kind"])
	if kind_filter.selected == 1: return kind.contains("战") or kind.contains("城") or kind.contains("追击") or kind.contains("单挑")
	if kind_filter.selected == 2: return kind.contains("令") or kind.contains("出征") or kind.contains("撤退") or kind.contains("请示") or kind.contains("变阵")
	if kind_filter.selected == 3: return kind.contains("粮") or kind.contains("援") or kind.contains("补给") or kind.contains("通路")
	return true

func rebuild() -> void:
	signature = JSON.stringify([store.war.state["tick"], store.war.state["reports"].size(), store.war.visible_reports().size(), store.war.state["armies"].size()])
	subtitle.text = "%s  %s  第%d日" % [store.scenario["factions"].get(store.war.state["player_faction"], {}).get("name", "本军"), store.date_text(), store.war.state["tick"]]
	UISkin.style_button(report_tab, mode == "reports")
	UISkin.style_button(summary_tab, mode == "summary")
	army_filter.visible = mode == "reports"
	kind_filter.visible = mode == "reports"
	UISkin.clear(report_list)
	if mode == "summary":
		_build_summary()
		return
	entries = store.war.visible_reports().filter(_matches)
	count_label.text = "%d 份送达军报" % entries.size()
	if entries.is_empty():
		report_list.add_child(UISkin.label("暂无送达军报", 14, UISkin.MUTED))
		UISkin.clear(detail)
		detail.add_child(UISkin.label("军报尚未送达", 21))
		detail.add_child(UISkin.label("仅关键节点和重大战役结束送达军报。可随时点击当前总结，或在部队详情查看当前复盘。", 14, UISkin.MUTED))
		if not filter_army.is_empty(): detail.add_child(UISkin.button("查看当前复盘", func(): show_review(filter_army)))
		return
	if not entries.any(func(item): return str(item["id"]) == selected_report): selected_report = str(entries[0]["id"])
	for report in entries:
		var id := str(report["id"])
		var army: Dictionary = store.war.state["armies"].get(report["army_id"], {})
		var button := UISkin.button("", func(): select_report(id))
		var row_style := StyleBoxFlat.new()
		row_style.bg_color = Color("e1d4b8") if selected_report == id else Color(0.9, 0.87, 0.78, 0.15)
		row_style.border_width_left = 3
		row_style.border_color = UISkin.GOLD if selected_report == id else Color.TRANSPARENT
		row_style.content_margin_left = 10
		row_style.content_margin_right = 10
		button.add_theme_stylebox_override("normal", row_style)
		button.name = "Report_" + id
		button.custom_minimum_size.y = 64
		button.tooltip_text = preload("res://scripts/ui/ui_text.gd").clean(str(report["message"]))
		var box := VBoxContainer.new()
		box.mouse_filter = MOUSE_FILTER_IGNORE
		box.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
		box.offset_left = 10
		box.offset_top = 7
		box.offset_right = -10
		box.offset_bottom = -7
		button.add_child(box)
		var name_label := UISkin.label("%s  %s" % [army.get("name", "部队"), report["kind"]], 13)
		name_label.autowrap_mode = TextServer.AUTOWRAP_OFF
		name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		box.add_child(name_label)
		box.add_child(UISkin.label("第%d日  %s%s" % [report["sent_tick"], report.get("received_date", report["sent_date"]), "  急报" if report.get("urgent", false) else ""], 11, UISkin.MUTED))
		report_list.add_child(button)
	_show_report(selected_report)

func select_report(id: String) -> void:
	mode = "reports"
	selected_report = id
	# Preserve the list position while highlighting a different report.
	var previous := list_scroll.scroll_vertical
	rebuild()
	list_scroll.set_deferred("scroll_vertical", previous)
	detail_scroll.scroll_vertical = 0

func _metric_row(parent: Control, values: Array) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	parent.add_child(row)
	for pair in values:
		var box := VBoxContainer.new()
		box.size_flags_horizontal = SIZE_EXPAND_FILL
		row.add_child(box)
		box.add_child(UISkin.label(str(pair[0]), 11, UISkin.MUTED))
		box.add_child(UISkin.label(str(pair[1]), 19))

func _section(title: String, text: String) -> void:
	var box := UISkin.section(detail, title)
	box.add_child(UISkin.label(text, 13))

func _show_report(id: String) -> void:
	UISkin.clear(detail)
	var report: Dictionary = {}
	for item in entries:
		if str(item["id"]) == id: report = item; break
	if report.is_empty(): return
	var army: Dictionary = store.war.state["armies"].get(report["army_id"], {})
	var snapshot: Dictionary = report.get("snapshot", {})
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 12)
	detail.add_child(header)
	var officer: Dictionary = store.war.roster.officers.get(army.get("officer_id", ""), {})
	var path := str(portraits.get(officer.get("name", ""), {}).get("thumbnail", ""))
	if FileAccess.file_exists(path):
		var face := TextureRect.new()
		face.texture = load(path)
		face.custom_minimum_size = Vector2(55, 64)
		face.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		face.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		header.add_child(face)
	var title_box := VBoxContainer.new()
	title_box.size_flags_horizontal = SIZE_EXPAND_FILL
	header.add_child(title_box)
	var title := UISkin.label(str(report["kind"]), 24)
	title.add_theme_font_override("font", UISkin.CitySkin.font())
	title.name = "ReportDetailTitle"
	title_box.add_child(title)
	title_box.add_child(UISkin.label("%s → %s" % [army.get("name", "部队"), store.war.graph.name_of(str(army.get("target", "")))], 13, UISkin.MUTED))
	detail.add_child(UISkin.label("发报  %s    /    收到  %s" % [report["sent_date"], report.get("received_date", "尚未送达")], 12, UISkin.MUTED))
	_metric_row(detail, [["兵力", snapshot.get("strength", "—")], ["士气", "%d / 100" % int(snapshot.get("morale", 0))]])
	detail.add_child(UISkin.label("战斗主将  " + str(snapshot.get("commander", "未记录")), 13))
	_metric_row(detail, [["主将杀敌", snapshot.get("commander_killed", "未记录")], ["部队杀敌", snapshot.get("troop_killed", snapshot.get("enemy_killed", 0))]])
	var message := str(report["message"])
	var factors: Array = snapshot.get("battle_factors", [])
	if not factors.is_empty(): message = message.trim_suffix(" " + "；".join(factors))
	_section("军报正文", message)
	var reason := str(snapshot.get("reason", ""))
	if not reason.is_empty(): _section("发报时的判断", reason)
	if not factors.is_empty(): _section("战斗影响因素", "\n".join(factors))
	if snapshot.has("wounded") or snapshot.has("daily_loss"):
		_metric_row(detail, [["本日损失", snapshot.get("daily_loss", "—")], ["伤兵", snapshot.get("wounded", "—")], ["组织", "%d / 100" % int(snapshot.get("organization", 0))]])
	var terrain := str(snapshot.get("terrain", ""))
	if terrain != "": detail.add_child(UISkin.label("交战地形  " + store.war.Terrain.name_of(terrain), 12, UISkin.MUTED))
	var actions := HBoxContainer.new()
	detail.add_child(actions)
	var army_id := str(report["army_id"])
	actions.add_child(UISkin.button("查看部队", func(): close_view(); army_requested.emit(army_id)))
	if not army.is_empty(): actions.add_child(UISkin.button("战役复盘" if snapshot.get("ended", false) else "当前复盘", func(): show_review(army_id)))

func _visible_side(row: Dictionary, summary: Dictionary) -> bool:
	return store.battle_test or summary["winner"] != "交战中" or row["faction"] == store.war.state["player_faction"]

func _build_summary() -> void:
	UISkin.clear(detail)
	var summary: Dictionary = store.war.request_battle_summary()
	count_label.text = "持续%d日  单挑%d次" % [summary["days"], summary["duels"]]
	detail.add_child(UISkin.label("会战兵员账本", 22))
	var result := str(store.scenario["factions"].get(summary["winner"], {}).get("name", summary["winner"]))
	if result == "draw": result = "平局"
	detail.add_child(UISkin.label("%s  %d日  挑战%d次 / 单挑%d次" % [result, summary["days"], summary["challenges"], summary["duels"]], 13, UISkin.MUTED))
	for side in summary["sides"]:
		if not _visible_side(side, summary): continue
		var box := UISkin.section(detail, str(store.scenario["factions"].get(side["faction"], {}).get("name", side["faction"])))
		_metric_row(box, [["初始兵力", side["initial"]], ["当前兵力", side["strength"]], ["阵亡", side["dead"]]])
		box.add_child(UISkin.label("伤兵 %d    被俘 %d    溃散 %d    归队 / 留驻 %d\n截获粮草 %d    兵员核对：%s" % [side["wounded"], side["captured"], side.get("dispersed", 0), side["deposited"], summary["loot"].get(side["faction"], 0), "守恒" if side["initial"] == side["accounted"] else "需核对"], 13))
	for siege in summary["sieges"]:
		if not store.battle_test and summary["winner"] == "交战中" and siege["attacker"] != store.war.state["player_faction"]: continue
		_section(store.war.graph.name_of(siege["city"]) + "  城池攻防", "%s  城墙%d/%d\n守军累计损失%d  攻城部队累计损失%d" % [siege["phase"], siege["wall"], siege["wall_max"], siege["defender_losses"], siege["losses"]])
		var guard: Dictionary = store.war.state["garrison_commanders"].get(siege["city"], {})
		if not guard.is_empty(): detail.add_child(UISkin.label("守城主将 %s  主将杀敌 %d  部队杀敌 %d" % [guard["name"], store.war.state["officer_personal_kills"].get(guard["officer_id"], 0), int(guard.get("enemy_killed", 0)) - int(guard.get("personal_soldier_kills", 0))], 13))
	var officers := UISkin.section(detail, "杀敌战绩  主将与部队")
	var credited: Dictionary = store.war.state.get("officer_kills", {}).duplicate()
	credited.merge(store.war.state["officer_personal_kills"])
	for officer_id in credited:
		var card: Dictionary = store.war.roster.officers.get(officer_id, {})
		if not store.battle_test and card.get("faction", "") != store.war.state["player_faction"] and summary["winner"] == "交战中": continue
		officers.add_child(UISkin.label("%s    主将杀敌 %d    部队杀敌 %d" % [card.get("name", officer_id), store.war.state["officer_personal_kills"].get(officer_id, 0), int(store.war.state["officer_kills"].get(officer_id, 0)) - int(store.war.state["officer_personal_soldiers"].get(officer_id, 0))], 13))
	var fates := UISkin.section(detail, "武将战死与俘虏")
	for officer_id in store.war.state.get("officer_fates", {}):
		var fate: Dictionary = store.war.state["officer_fates"][officer_id]
		if not store.battle_test and fate["faction"] != store.war.state["player_faction"] and fate.get("captor_faction", "") != store.war.state["player_faction"] and summary["winner"] == "交战中": continue
		fates.add_child(UISkin.label("第%d日  %s  %s\n%s" % [fate["tick"], fate["name"], {"dead":"战死", "captured":"被俘", "released":"已释放"}.get(fate["status"], fate["status"]), fate["cause"]], 13, UISkin.RED if fate["status"] == "dead" else UISkin.INK))
		if fate["status"] == "captured" and fate.get("captor_faction", "") == store.war.state["player_faction"]:
			var prisoner_id: String = str(officer_id)
			fates.add_child(UISkin.button("释放 " + str(fate["name"]), func(): preload("res://scripts/war/campaign/officer_fate.gd").release(store.war, prisoner_id); store._save(); rebuild()))
	if fates.get_child_count() <= 1: fates.add_child(UISkin.label("暂无武将战死或被俘。", 13, UISkin.MUTED))
	detail.add_child(UISkin.label("逐日战况", 16))
	if summary["log"].is_empty(): detail.add_child(UISkin.label("会战尚未开始，暂无每日结算。", 13, UISkin.MUTED))
	var timeline: Array = summary["log"].duplicate()
	timeline.reverse()
	for entry in timeline:
		var lines := PackedStringArray()
		for side in entry["sides"]:
			if not _visible_side(side, summary): continue
			lines.append("%s  %d人  士气%.0f  组织%.0f  损失%d" % [store.scenario["factions"].get(side["faction"], {}).get("name", side["faction"]), side["strength"], side["morale"], side["org"], entry["losses"].get(side["faction"], 0)])
		for event in entry["events"]:
			if store.battle_test or event["faction"] in ["", store.war.state["player_faction"]] or summary["winner"] != "交战中": lines.append(event["kind"] + "  " + event["message"])
		_section("第%d日" % entry["tick"], "\n".join(lines))
	for army in store.war.active_armies(str(store.war.state["player_faction"])):
		var id := str(army["id"])
		report_list.add_child(UISkin.button(str(army["name"]) + "  当前复盘", func(): show_review(id)))
	for army in store.war.state["armies"].values():
		if army["faction"] != store.war.state["player_faction"] or army["status"] != "ended": continue
		var id := str(army["id"])
		report_list.add_child(UISkin.button(str(army["name"]) + "  复盘", func(): show_review(id)))

func show_review(id: String) -> void:
	mode = "review"
	UISkin.style_button(report_tab, false)
	UISkin.style_button(summary_tab, false)
	army_filter.hide()
	kind_filter.hide()
	show()
	UISkin.clear(detail)
	var requested: Dictionary = store.war.request_battle_summary(id)
	var army: Dictionary = requested.get("army", {})
	if army.is_empty(): return
	count_label.text = "战役复盘" if army["status"] == "ended" else "当前复盘"
	detail.add_child(UISkin.label(str(army["name"]) + "  " + str(army.get("outcome", "")), 22))
	_metric_row(detail, [["出征", army["initial_strength"]], ["阵亡", army["dead"]], ["伤兵", army["wounded"]]])
	_metric_row(detail, [["主将杀敌", store.war.state["officer_personal_kills"].get(army["officer_id"], 0)], ["部队杀敌", int(army.get("enemy_killed", 0)) - int(army.get("personal_soldier_kills", 0))]])
	detail.add_child(UISkin.label("被俘 %d  归队 %d" % [army["captured"], army.get("returned_strength", 0)], 13))
	for item in army.get("decision_history", []):
		var observation: Dictionary = item.get("observation", {})
		var observed_army: Dictionary = observation.get("army", {})
		var enemies: Array = observation.get("enemies", [])
		var estimates := PackedStringArray()
		for enemy in enemies: estimates.append("约%d人" % int(enemy.get("strength_estimate", 0)))
		var description := "当时情报：%s\n士气%d\n行动：%s\n依据：%s" % ["未发现敌军" if estimates.is_empty() else "；".join(estimates), observed_army.get("morale", 0), {"march":"行军", "continue":"继续行军", "hold":"驻守整顿", "engage":"接战", "withdraw":"撤退", "scout":"侦察", "resupply":"补给", "besiege":"围城", "pursue":"追击", "flank":"侧翼绕行", "support":"协同支援", "request_support":"求援"}.get(item.get("action", {}).get("type", ""), "临机行动"), item.get("reason_summary", "")]
		_section("第%d日  %s" % [item["tick"], "智能体" if item["source"] == "model" else "本地策略"], description)
	var corps: Dictionary = store.war.state["corps"].get(army.get("corps_id", ""), {})
	for order in corps.get("orders", []):
		_section("第%d日  主帅%s" % [order["tick"], "智能体判断" if order["source"] == "model" else "军令"], "%s\n%s" % [order.get("reason", ""), "已下达" if order.get("applied", {}).get("ok", false) else "执行条件不满足"])
	if army.get("decision_history", []).is_empty() and corps.get("orders", []).is_empty(): detail.add_child(UISkin.label("暂无决策记录。", 13, UISkin.MUTED))

func _unhandled_key_input(event: InputEvent) -> void:
	if visible and event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		close_view()
		get_viewport().set_input_as_handled()
