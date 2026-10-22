extends CanvasLayer

signal closed

const CitySkin = preload("res://scripts/ui/city_ui_skin.gd")
const Layout = preload("res://scripts/ui/ui_layout.gd")
const IconEffects = preload("res://scripts/city/city_button_effects.gd")
const BuildingAtlas = preload("res://scripts/ui/building_sprite_atlas.gd")
const CouncilView = preload("res://scripts/city/council_view.gd")
const ActionView = preload("res://scripts/city/city_action_view.gd")
const CouncilLettering = preload("res://scripts/ui/council_label_atlas.gd")
const SceneCatalog = preload("res://scripts/city/city_scene_catalog.gd")
const StateKeys = preload("res://scripts/war/campaign/war_state_keys.gd")
const CITY_ART := "res://assets/city/han/panorama.png"
const LUOYANG_ART := "res://assets/city/luoyang/preview-perspective.png"
const LUOYANG_LOCATIONS := {
	"government": Vector2(658, 177), "market": Vector2(345, 565),
	"farm": Vector2(302, 233), "barracks": Vector2(1060, 409),
	"workshop": Vector2(395, 394), "tavern": Vector2(758, 418)
}
const OFFICER_ART := "res://assets/city/han/officer-user.png"
const COUNCIL_ACTIONS := {
	"civil": ["govern", "develop", "tax"],
	"military": ["recruit", "train", "fortify"],
}
const COUNCIL_INFO := {
	"people": [{"title": "武将情报", "report": "personnel"}, {"title": "任免武将", "blocked": "人事任免暂未开放"}],
	"strategy": [{"title": "施政记录", "report": "records"}, {"title": "施行计略", "blocked": "计略指令暂未开放"}],
	"diplomacy": [{"title": "势力情报", "report": "faction"}, {"title": "派遣使者", "blocked": "外交交涉暂未开放"}],
	"intelligence": [{"title": "城池情报", "report": "city"}, {"title": "施政记录", "report": "records"}]
}
const BUILDINGS := {
	"government": {"name": "官府", "icon": 0, "position": Vector2(735, 135), "actions": ["govern", "tax"]},
	"market": {"name": "市场", "icon": 1, "position": Vector2(498, 284), "actions": ["buy_grain", "sell_grain"]},
	"farm": {"name": "农田", "icon": 2, "position": Vector2(412, 134), "actions": ["develop"]},
	"barracks": {"name": "兵营", "icon": 3, "position": Vector2(1074, 148), "actions": ["recruit", "train"]},
	"workshop": {"name": "工坊", "icon": 4, "position": Vector2(1001, 387), "actions": ["forge", "fortify"]},
	"tavern": {"name": "酒肆", "icon": 5, "position": Vector2(483, 447), "actions": ["visit"]}
}

var city_id := ""
var city_name := ""
var region_name := ""
var selected_building := ""
var store: Node = GameState
var root_ui: Control
var city_title: Label
var city_subtitle: Label
var date_label: Label
var ap_label: Label
var resource_labels: Dictionary = {}
var building_buttons: Dictionary = {}
var toolbar_buttons: Dictionary = {}
var building_labels: Array[Label] = []
var selection_rings: Dictionary = {}
var action_panel: PanelContainer
var action_heading: Label
var action_summary: Label
var action_list: BoxContainer
var command_tip: PanelContainer
var command_tip_label: Label
var command_summary: PanelContainer
var command_summary_label: Label
var notice_label: Label
var progress: ProgressBar
var report_panel: PanelContainer
var report_heading: Label
var report_text: Label
var settings_button: Button
var report_kind := ""
var toast: PanelContainer
var toast_tween: Tween
var show_building_names := true
var council_view: Control
var in_council := false
var council_category := "civil"
var building_holders: Array[Control] = []
var caption_title: Label
var back_button: Button
var end_month_button: Button
var notice_seal: Label
var action_view: Control
var report_stats: VBoxContainer
var report_nav: Dictionary = {}
var hidden_chrome: Dictionary = {}
var council_menu_leave_time := 0.0
var officer_page: CanvasLayer


func _process(delta: float) -> void:
	if not in_council or not action_panel.visible:
		council_menu_leave_time = 0.0
		return
	var pointer := root_ui.get_global_mouse_position()
	var category_button: Button = council_view.buttons[council_category]
	var hover_area := action_panel.get_global_rect().merge(category_button.get_global_rect()).grow(6)
	if hover_area.has_point(pointer):
		council_menu_leave_time = 0.0
	else:
		council_menu_leave_time += delta
		if council_menu_leave_time >= 0.2:
			_hide_menu()


func _ready() -> void:
	_build_ui()
	hide()


func open_city(place_id: String, place_name: String, region: String) -> void:
	city_id = store.canonical_city_id(place_id)
	if city_id == "": return
	city_name = place_name
	region_name = region
	var background: TextureRect = root_ui.get_node("CityBackground")
	background.texture = load(SceneCatalog.art_for(city_id))
	var index := 0
	for building_id in BUILDINGS:
		building_holders[index].position = _building_location(building_id) - Vector2(40, 29)
		index += 1
	_leave_government()
	_hide_menu()
	report_panel.hide()
	toast.hide()
	_refresh()
	show()


func _build_ui() -> void:
	root_ui = Control.new()
	root_ui.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root_ui.mouse_filter = Control.MOUSE_FILTER_STOP
	var theme := Theme.new()
	theme.default_font = CitySkin.font()
	CitySkin.apply_theme(theme)
	root_ui.theme = theme
	root_ui.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	root_ui.gui_input.connect(_on_background_input)
	add_child(root_ui)
	var background := TextureRect.new()
	background.name = "CityBackground"
	background.texture = load(CITY_ART)
	background.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	background.stretch_mode = TextureRect.STRETCH_SCALE
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	background.self_modulate = Color(0.93, 0.95, 0.97)
	root_ui.add_child(background)
	council_view = CouncilView.new()
	root_ui.add_child(council_view)
	council_view.category_requested.connect(_choose_council_category)
	council_view.closed.connect(_leave_government)
	council_view.hide()
	var portrait := TextureRect.new()
	portrait.texture = load(OFFICER_ART)
	portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	portrait.anchor_top = 1.0
	portrait.anchor_bottom = 1.0
	portrait.offset_left = -26
	portrait.offset_top = -minf(505.0, 343.0 * float(portrait.texture.get_height()) / float(portrait.texture.get_width()))
	portrait.offset_right = 317
	portrait.offset_bottom = 0
	portrait.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root_ui.add_child(portrait)
	_build_top_bar()
	_build_hotspots()
	_build_caption()
	_build_action_panel()
	_build_report_panel()
	_build_footer()
	action_view = ActionView.new()
	root_ui.add_child(action_view)
	action_view.confirmed.connect(_confirm_action)
	action_view.cancelled.connect(_cancel_action)


func _build_top_bar() -> void:
	var top := _paper_panel(Rect2(0, 15, 820, 33), 0.88, 7)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 13)
	top.add_child(row)
	date_label = CitySkin.label("", 16)
	row.add_child(date_label)
	_add_separator(row)
	city_title = CitySkin.label("", 19)
	row.add_child(city_title)
	for key in ["population", "grain", "garrison", "order"]:
		_add_separator(row)
		_add_resource(row, key)
	var second := _paper_panel(Rect2(0, 51, 800, 31), 0.86, 6)
	var details := HBoxContainer.new()
	details.add_theme_constant_override("separation", 12)
	second.add_child(details)
	city_subtitle = CitySkin.label("", 15, Color("714729"))
	details.add_child(city_subtitle)
	_add_separator(details)
	ap_label = CitySkin.label("", 15)
	details.add_child(ap_label)
	for key in ["treasury", "economy", "training", "defense", "equipment"]:
		_add_separator(details)
		_add_resource(details, key)
	var tasks := _paper_panel(Rect2(14, 96, 289, 27), 0.70, 5)
	var status := HBoxContainer.new()
	status.add_theme_constant_override("separation", 12)
	tasks.add_child(status)
	status.add_child(CitySkin.label("城内诸务", 15))
	progress = ProgressBar.new()
	progress.custom_minimum_size = Vector2(165, 7)
	progress.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	progress.max_value = 3
	progress.show_percentage = false
	progress.tooltip_text = "本月剩余行动力"
	progress.add_theme_stylebox_override("background", CitySkin.sprite_style("bar_track", 0, 0))
	progress.add_theme_stylebox_override("fill", CitySkin.sprite_style("bar_fill", 0, 0))
	status.add_child(progress)
	var toolbar := HBoxContainer.new()
	toolbar.anchor_left = 1.0
	toolbar.anchor_right = 1.0
	toolbar.offset_left = -269
	toolbar.offset_right = -14
	toolbar.offset_top = 11
	toolbar.offset_bottom = 51
	toolbar.add_theme_constant_override("separation", 3)
	root_ui.add_child(toolbar)
	var commands := [
		[6, "返回大地图", _close],
		[7, "城池情报", func() -> void: _show_report("city")],
		[8, "施政记录", func() -> void: _show_report("records")],
		[9, "显示设置", func() -> void: _show_report("settings")],
		[10, "操作说明", func() -> void: _show_report("help")],
		[11, "返回上一层", _back]
	]
	for entry in commands:
		var button := _icon_button(int(entry[0]), Vector2(40, 40), entry[2])
		button.tooltip_text = str(entry[1])
		toolbar.add_child(button)
		toolbar_buttons[int(entry[0])] = button


func _add_resource(row: HBoxContainer, key: String) -> void:
	var captions := {"population": "人口", "grain": "粮草", "garrison": "兵力", "order": "民心", "treasury": "金钱", "economy": "经济", "training": "训练", "defense": "城防", "equipment": "军备"}
	var item := HBoxContainer.new()
	item.add_theme_constant_override("separation", 5)
	var pictogram := TextureRect.new()
	pictogram.texture = load("res://assets/city/han/ui/glyph-%s.svg" % key)
	pictogram.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	pictogram.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	pictogram.custom_minimum_size = Vector2(18, 18)
	pictogram.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	pictogram.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	pictogram.mouse_filter = Control.MOUSE_FILTER_IGNORE
	item.add_child(pictogram)
	item.tooltip_text = str(captions[key])
	var value := CitySkin.label("", 16)
	item.add_child(value)
	row.add_child(item)
	resource_labels[key] = value


func _build_hotspots() -> void:
	for building_id in BUILDINGS:
		var spec: Dictionary = BUILDINGS[building_id]
		var location: Vector2 = spec["position"]
		var holder := Control.new()
		holder.position = location - Vector2(40, 29)
		holder.size = Vector2(80, 88)
		holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
		root_ui.add_child(holder)
		building_holders.append(holder)
		var ring := Panel.new()
		ring.position = Vector2(9, -2)
		ring.size = Vector2(62, 62)
		ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var ring_style := StyleBoxEmpty.new()
		ring.add_theme_stylebox_override("panel", ring_style)
		ring.hide()
		holder.add_child(ring)
		selection_rings[building_id] = ring
		var chosen_id := str(building_id)
		var button := _icon_button(int(spec["icon"]), Vector2(74, 74), func() -> void: _select_building(chosen_id))
		button.position = Vector2(3, -6)
		button.tooltip_text = ""
		button.set_meta("fixed_icon_size", true)
		holder.add_child(button)
		building_buttons[building_id] = button
		var caption := CitySkin.label(str(spec["name"]), 17, CitySkin.PALE)
		caption.position = Vector2(0, 60)
		caption.size = Vector2(80, 23)
		caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		caption.add_theme_color_override("font_shadow_color", Color("161b1b", 0.96))
		caption.add_theme_constant_override("shadow_offset_x", 1)
		caption.add_theme_constant_override("shadow_offset_y", 2)
		holder.add_child(caption)
		building_labels.append(caption)
		caption.hide()


func _build_caption() -> void:
	var caption := PanelContainer.new()
	caption.anchor_top = 1.0
	caption.anchor_bottom = 1.0
	caption.offset_left = 28
	caption.offset_top = -180
	caption.offset_right = 57
	caption.offset_bottom = -73
	caption.add_theme_stylebox_override("panel", CitySkin.nameplate())
	caption.mouse_filter = Control.MOUSE_FILTER_IGNORE
	caption_title = CitySkin.label("城\n守\n参\n议", 16, CitySkin.PALE)
	caption_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	caption.add_child(caption_title)
	root_ui.add_child(caption)


func _build_action_panel() -> void:
	action_panel = _paper_panel(Rect2(0, 0, 224, 100), 0.96, 11)
	action_panel.custom_minimum_size.x = 224
	action_panel.add_theme_stylebox_override("panel", CitySkin.window(14))
	action_panel.hide()
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 5)
	action_panel.add_child(column)
	var header := HBoxContainer.new()
	var title_plate := PanelContainer.new()
	title_plate.add_theme_stylebox_override("panel", CitySkin.section_header())
	column.add_child(title_plate)
	title_plate.add_child(header)
	action_heading = CitySkin.label("", 19, CitySkin.PALE)
	action_heading.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(action_heading)
	var close_button := _close_button(_hide_menu)
	close_button.tooltip_text = "关闭建筑菜单"
	header.add_child(close_button)
	action_summary = CitySkin.label("", 12, Color("79664b"))
	column.add_child(action_summary)
	column.add_child(HSeparator.new())
	action_list = BoxContainer.new()
	action_list.vertical = true
	action_list.add_theme_constant_override("separation", 5)
	column.add_child(action_list)
	column.add_child(_menu_button("查看城池情报", func() -> void: _show_report("city")))
	column.add_child(CitySkin.label("每项命令消耗 1 点行动力", 12, Color("79664b")))
	command_summary = PanelContainer.new()
	command_summary.mouse_filter = Control.MOUSE_FILTER_IGNORE
	command_summary.add_theme_stylebox_override("panel", _command_style("summary"))
	command_summary.custom_minimum_size = Vector2(235, 30)
	command_summary_label = CitySkin.label("", 14, Color("352e25"))
	command_summary.add_child(command_summary_label)
	root_ui.add_child(command_summary)
	command_summary.hide()
	command_tip = PanelContainer.new()
	command_tip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	command_tip.add_theme_stylebox_override("panel", _command_style("tip"))
	command_tip_label = CitySkin.label("", 16, CitySkin.PALE)
	command_tip.add_child(command_tip_label)
	root_ui.add_child(command_tip)
	command_tip.hide()


func _command_style(kind: String) -> StyleBoxTexture:
	var style := StyleBoxTexture.new()
	style.texture = load("res://assets/city/han/ui/user-atlas/command-%s.png" % kind)
	if kind == "summary":
		style.texture = load("res://assets/city/han/ui/user-atlas/detail-paper.png")
	if kind == "tip":
		style.modulate_color = Color(0.56, 0.52, 0.50, 1.0)
	style.texture_margin_left = 3
	style.texture_margin_right = 3
	style.texture_margin_top = 3
	style.texture_margin_bottom = 3
	style.content_margin_left = 10
	style.content_margin_right = 10
	style.content_margin_top = 2
	style.content_margin_bottom = 2
	return style


func _command_button(title: String, callback: Callable, hint: String, blocked: bool = false) -> void:
	var card := VBoxContainer.new()
	var button := Button.new()
	button.text = title
	button.custom_minimum_size = Vector2(96, 23)
	button.add_theme_font_override("font", CitySkin.font())
	button.add_theme_font_size_override("font_size", 13)
	button.add_theme_color_override("font_color", CitySkin.PALE)
	button.add_theme_color_override("font_hover_color", Color("703a26"))
	button.add_theme_color_override("font_pressed_color", Color("703a26"))
	button.add_theme_color_override("font_disabled_color", Color("aaaaaa"))
	for pair in [["normal", "red"], ["hover", "hover"], ["pressed", "hover"], ["disabled", "disabled"]]:
		button.add_theme_stylebox_override(str(pair[0]), _command_style(str(pair[1])))
	button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	button.disabled = blocked
	button.pressed.connect(callback)
	button.mouse_entered.connect(func() -> void:
		command_tip_label.text = preload("res://scripts/ui/ui_text.gd").clean(hint)
		command_tip.reset_size()
		command_tip.position = Vector2(maxf(8, action_panel.position.x - command_tip.size.x - 8), button.global_position.y)
		command_tip.show())
	button.mouse_exited.connect(func() -> void:
		command_tip.hide())
	card.add_child(button)
	action_list.add_child(card)


func _build_report_panel() -> void:
	report_panel = _paper_panel(Rect2(Vector2.ZERO, Layout.DESIGN), 0.0, 0)
	report_panel.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	report_panel.hide()
	var page := Control.new()
	page.custom_minimum_size = Layout.DESIGN
	page.mouse_filter = Control.MOUSE_FILTER_STOP
	report_panel.add_child(page)
	var dim := ColorRect.new()
	dim.color = Color("1b2027", 0.54)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	page.add_child(dim)
	var title_band := _report_paper(page, Rect2(0, 0, 1260, 78), CitySkin.sheet(1.0, 10))
	report_heading = CitySkin.label("", 42)
	report_heading.position = Vector2(32, 4)
	var title_holder := Control.new()
	title_holder.custom_minimum_size.y = 57
	title_band.add_child(title_holder)
	title_holder.add_child(report_heading)
	var index := _report_paper(page, Rect2(29, 110, 260, 502), CitySkin.sheet(0.92, 15))
	var nav := VBoxContainer.new()
	nav.add_theme_constant_override("separation", 14)
	index.add_child(nav)
	nav.add_child(CitySkin.label("城 内 诸 务", 25, Color("78533f")))
	nav.add_child(HSeparator.new())
	for entry in [["city", "城池情报"], ["records", "施政记录"], ["settings", "显示设置"], ["help", "操作说明"]]:
		var kind := str(entry[0])
		var button := _menu_button(str(entry[1]), func() -> void: _show_report(kind))
		button.custom_minimum_size.y = 39
		nav.add_child(button)
		report_nav[kind] = button
	var details := _report_paper(page, Rect2(314, 110, 913, 502), CitySkin.sheet(0.93, 17))
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 14)
	details.add_child(column)
	var section := PanelContainer.new()
	section.add_theme_stylebox_override("panel", CitySkin.section_header())
	section.add_child(CitySkin.label("城市档案  /  城内事务", 21, CitySkin.PALE))
	column.add_child(section)
	report_stats = VBoxContainer.new()
	report_stats.add_theme_constant_override("separation", 4)
	column.add_child(report_stats)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size.y = 110
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	column.add_child(scroll)
	report_text = CitySkin.label("", 18)
	report_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	report_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(report_text)
	settings_button = _menu_button("切换建筑名称显示", _toggle_building_names)
	column.add_child(settings_button)
	var back := Button.new()
	back.text = "返回"
	back.position = Vector2(598, 636)
	CitySkin.style_confirm_button(back)
	back.pressed.connect(_close_report)
	page.add_child(back)


func _report_paper(parent: Control, rect: Rect2, style: StyleBox) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.position = rect.position
	panel.size = rect.size
	panel.add_theme_stylebox_override("panel", style)
	parent.add_child(panel)
	return panel


func _fill_city_stats(state: Dictionary) -> void:
	var pairs := [["人口", "population", "经济", "economy"], ["金钱", "treasury", "粮草", "grain"], ["兵力", "garrison", "训练", "training"], ["城防", "defense", "军备", "equipment"], ["民心", "order", "行动力", "ap"]]
	for pair in pairs:
		var row := HBoxContainer.new()
		row.custom_minimum_size.y = 38
		row.add_theme_constant_override("separation", 18)
		for offset in [0, 2]:
			var caption := CitySkin.label(str(pair[offset]), 20, Color("875d45"))
			caption.custom_minimum_size.x = 90
			row.add_child(caption)
			var key := str(pair[offset + 1])
			var count := str(store.action_points) + " / 3" if key == "ap" else str(int(state.get(key, 50 if key == "equipment" else 0)))
			var value := CitySkin.label(count, 22)
			value.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.add_child(value)
		report_stats.add_child(row)
		report_stats.add_child(HSeparator.new())


func _build_footer() -> void:
	var footer := HBoxContainer.new()
	footer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	footer.anchor_left = 1.0
	footer.anchor_right = 1.0
	footer.anchor_top = 1.0
	footer.anchor_bottom = 1.0
	footer.offset_left = -240
	footer.offset_top = -46
	footer.offset_right = -15
	footer.offset_bottom = -15
	footer.add_theme_constant_override("separation", 8)
	footer.alignment = BoxContainer.ALIGNMENT_END
	root_ui.add_child(footer)
	back_button = _button("返回地图", _back)
	footer.add_child(back_button)
	end_month_button = _button("结束本月", _end_month, true)
	end_month_button.custom_minimum_size = Vector2(88, 32)
	end_month_button.tooltip_text = "进行：结束本月并结算城内资源"
	footer.add_child(end_month_button)
	toast = _paper_panel(Rect2(320, 650, 630, 36), 0.88, 8)
	toast.hide()
	toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var announcement := HBoxContainer.new()
	announcement.mouse_filter = Control.MOUSE_FILTER_IGNORE
	announcement.add_theme_constant_override("separation", 9)
	toast.add_child(announcement)
	var seal := PanelContainer.new()
	seal.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var seal_style := CitySkin.sprite_style("button_red", 0, 4)
	seal_style.content_margin_left = 5
	seal_style.content_margin_right = 5
	seal_style.content_margin_top = 1
	seal_style.content_margin_bottom = 1
	seal.add_theme_stylebox_override("panel", seal_style)
	notice_seal = CitySkin.label("令", 14, CitySkin.PALE)
	notice_seal.mouse_filter = Control.MOUSE_FILTER_IGNORE
	seal.add_child(notice_seal)
	announcement.add_child(seal)
	notice_label = CitySkin.label("", 14)
	notice_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	notice_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	notice_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	announcement.add_child(notice_label)


func _select_building(building_id: String) -> void:
	if not BUILDINGS.has(building_id):
		return
	if building_id == "government":
		_enter_government()
		return
	if in_council:
		_leave_government()
	_close_report()
	selected_building = building_id
	_refresh_building_icon_styles()
	for key in selection_rings:
		selection_rings[key].visible = key == building_id
	action_heading.text = str(BUILDINGS[building_id]["name"])
	_refresh_actions()
	_refresh_summary()
	var location: Vector2 = _building_location(building_id)
	action_panel.custom_minimum_size.x = 96
	action_panel.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	var column := action_list.get_parent()
	for child in column.get_children():
		child.visible = child == action_list
	action_panel.position = Vector2(location.x - 48, location.y + 57)
	command_summary.custom_minimum_size.x = minf(235, 1246 - location.x - 36)
	command_summary.size.x = command_summary.custom_minimum_size.x
	command_summary.position = Vector2(location.x + 36, location.y - 13)
	command_summary_label.text = action_summary.text
	command_summary.show()
	action_panel.reset_size()
	action_panel.show()
	_reveal_menu.call_deferred()


func _reveal_menu() -> void:
	action_panel.reset_size()
	action_panel.position.y = minf(action_panel.position.y, 648 - action_panel.size.y)
	action_panel.position.x = minf(action_panel.position.x, 1246 - action_panel.size.x)
	_focus_command()


func _focus_command(preferred: String = "") -> void:
	if not action_panel.visible:
		return
	var fallback: Button
	for card in action_list.get_children():
		var button: Button = card.get_child(0)
		if button.disabled:
			continue
		if fallback == null:
			fallback = button
		if str(button.get_meta("action_id", "")) == preferred:
			button.grab_focus()
			return
	if fallback != null:
		fallback.grab_focus()


func _hide_menu() -> void:
	action_panel.hide()
	command_summary.hide()
	command_tip.hide()
	selected_building = ""
	_refresh_building_icon_styles()
	for ring in selection_rings.values():
		ring.hide()


func _refresh() -> void:
	if city_id == "":
		return
	var state: Dictionary = store.city_state(city_id)
	var faction: Dictionary = store.faction_for(city_id)
	city_title.text = city_name
	city_subtitle.text = "%s  %s军" % [region_name, str(faction.get("name", "无主"))]
	var seasons := ["春", "春", "春", "夏", "夏", "夏", "秋", "秋", "秋", "冬", "冬", "冬"]
	date_label.text = "%d年  %d月  %s" % [store.year, store.month, seasons[store.month - 1]]
	ap_label.text = "行动力 %d/3" % store.action_points
	ap_label.add_theme_color_override("font_color", Color("944133") if store.action_points == 0 else CitySkin.INK)
	progress.value = store.action_points
	if in_council:
		CouncilLettering.apply(end_month_button, "proceed")
	else:
		CouncilLettering.clear(end_month_button, "结束本月")
	for key in resource_labels:
		var amount := int(state.get(key, 50 if key == "equipment" else 0))
		resource_labels[key].text = (_format_count(amount) if key in ["population", "grain"] else str(amount)) if store.war.player_has_city_access(city_id) else "未知"
	_refresh_actions()
	_refresh_summary()
	if report_panel.visible:
		_fill_report()


func _refresh_summary() -> void:
	if selected_building == "":
		return
	if not store.war.player_has_city_access(city_id):
		action_summary.text = "本城信息 · 可查看实时数据，政令由所属势力下达"
		command_summary_label.text = action_summary.text
		return
	var state: Dictionary = store.city_state(city_id)
	if in_council:
		action_summary.text = "民心 %d    经济 %d    军备 %d" % [int(state.get("order", 0)), int(state.get("economy", 0)), int(state.get("equipment", 50))]
		return
	var summaries := {
		"government": "民心 %d / 100" % int(state.get("order", 0)),
		"market": "民心 %d / 100" % int(state.get("order", 0)),
		"farm": "粮草 %s" % _format_count(int(state.get("grain", 0))),
		"barracks": "兵力 %d    训练 %d" % [int(state.get("garrison", 0)), int(state.get("training", 0))],
		"workshop": "军备 %d    城防 %d" % [int(state.get("equipment", 50)), int(state.get("defense", 0))],
		"tavern": "民心 %d    人口 %s" % [int(state.get("order", 0)), _format_count(int(state.get("population", 0)))]
	}
	action_summary.text = str(summaries[selected_building])
	command_summary_label.text = action_summary.text


func _refresh_actions() -> void:
	action_list.vertical = not in_council
	action_list.add_theme_constant_override("separation", 0 if in_council else 5)
	var preferred := ""
	var focus_owner := get_viewport().gui_get_focus_owner()
	if focus_owner != null and focus_owner.has_meta("action_id"):
		preferred = str(focus_owner.get_meta("action_id"))
	for child in action_list.get_children():
		action_list.remove_child(child)
		child.queue_free()
	if selected_building == "":
		return
	if not in_council:
		if selected_building == "market":
			_command_button("见闻", func() -> void: _show_report("records"), "查看城内见闻与施政记录。")
			_command_button("武将情报", func() -> void: _show_report("personnel"), "查看武将资料与能力。")
			_command_button("买卖", _show_trade_commands, "买卖粮草，补充城内物资。")
			_command_button("强借", func() -> void: pass, "强借命令暂未开放。", true)
			_command_button("投资", func() -> void: _prepare_action("develop"), str(store.ACTIONS["develop"]["description"]), store.action_error(city_id, "develop") != "")
		else:
			for action_id in BUILDINGS[selected_building]["actions"]:
				var chosen := str(action_id)
				var spec: Dictionary = store.ACTIONS[chosen]
				_command_button(str(spec["title"]), func() -> void: _prepare_action(chosen), str(spec["description"]), store.action_error(city_id, chosen) != "")
		return
	if in_council and COUNCIL_INFO.has(council_category):
		_build_council_info()
		_focus_command.call_deferred("")
		return
	for action_id in COUNCIL_ACTIONS[council_category]:
		var chosen_id := str(action_id)
		var spec: Dictionary = store.ACTIONS[chosen_id]
		var error: String = store.action_error(city_id, chosen_id)
		_command_button(str(spec["title"]), func() -> void: _prepare_action(chosen_id), error if error != "" else str(spec["description"]) + "  行动力 -1", error != "")
		action_list.get_child(-1).get_child(0).set_meta("action_id", chosen_id)
	_focus_command.call_deferred(preferred)


func _build_council_info() -> void:
	for entry in COUNCIL_INFO[council_category]:
		var page := str(entry.get("report", ""))
		_command_button(str(entry["title"]), func() -> void: _show_report(page), str(entry.get("blocked", "查阅资料，不消耗行动力")), entry.has("blocked"))
		action_list.get_child(-1).get_child(0).set_meta("action_id", "report:" + page)

func _show_trade_commands() -> void:
	command_tip.hide()
	for child in action_list.get_children():
		action_list.remove_child(child)
		child.queue_free()
	for action_id in ["buy_grain", "sell_grain"]:
		var chosen := str(action_id)
		var spec: Dictionary = store.ACTIONS[chosen]
		_command_button(str(spec["title"]), func() -> void: _prepare_action(chosen), str(spec["description"]), store.action_error(city_id, chosen) != "")
	_command_button("返回", _refresh_actions, "返回市场命令。")


func _do_action(action_id: String) -> void:
	var result: Dictionary = store.apply_action(city_id, action_id)
	_show_notice(str(result["message"]), bool(result["ok"]))
	_refresh()


func _prepare_action(action_id: String) -> void:
	_set_modal(true)
	action_view.present(store, city_id, city_name, action_id)


func _confirm_action(action_id: String) -> void:
	action_view.hide()
	_set_modal(false)
	_do_action(action_id)
	_focus_command.call_deferred(action_id)


func _cancel_action() -> void:
	var previous: String = action_view.action_id
	action_view.hide()
	_set_modal(false)
	_focus_command.call_deferred(previous)


func _set_modal(active: bool) -> void:
	if active:
		if not hidden_chrome.is_empty():
			return
		for child in root_ui.get_children():
			if child == council_view or child == report_panel or child == action_view or child.name == "CityBackground":
				continue
			if child is Control:
				hidden_chrome[child] = child.visible
				child.hide()
		var menu := council_view.get_node("CouncilCategories")
		hidden_chrome[menu] = menu.visible
		menu.hide()
	else:
		for control in hidden_chrome:
			if is_instance_valid(control):
				control.visible = bool(hidden_chrome[control])
		hidden_chrome.clear()


func _close_report() -> void:
	report_panel.hide()
	_set_modal(false)


func _end_month() -> void:
	if store.busy:
		return
	end_month_button.disabled = true
	end_month_button.text = "正在推进…"
	_show_notice(await store.advance_to_month())
	end_month_button.disabled = false
	end_month_button.text = "结束本月"
	_refresh()


func _show_notice(message: String, success: bool = true) -> void:
	notice_label.text = message
	notice_seal.text = "令" if success else "阻"
	if toast_tween != null:
		toast_tween.kill()
	toast.modulate.a = 1.0
	toast.show()
	toast_tween = create_tween()
	toast_tween.tween_interval(4.5)
	toast_tween.tween_property(toast, "modulate:a", 0.0, 0.5)
	toast_tween.tween_callback(toast.hide)


func _show_report(kind: String) -> void:
	if kind == "personnel":
		_hide_menu()
		_set_modal(true)
		if officer_page == null:
			officer_page = load("res://scenes/officer_page.tscn").instantiate()
			add_child(officer_page)
			officer_page.closed.connect(func() -> void: _set_modal(false))
		officer_page.open_page(true)
		return
	_hide_menu()
	_set_modal(true)
	report_kind = kind
	_fill_report()
	report_panel.show()


func _fill_report() -> void:
	var state: Dictionary = store.city_state(city_id)
	settings_button.visible = report_kind == "settings"
	for child in report_stats.get_children():
		report_stats.remove_child(child)
		child.queue_free()
	report_stats.visible = report_kind == "city"
	if not store.war.player_has_city_access(city_id) and report_kind in ["records", "personnel", "faction"]:
		report_heading.text = city_name + " · 公开情报"
		report_text.text = "所属势力：%s\n\n内部人事、资源与施政记录尚未获知。" % str(store.faction_for(city_id).get("name", "无主"))
		return
	for kind in report_nav:
		CitySkin.style_tab_button(report_nav[kind], kind == report_kind)
	match report_kind:
		"city":
			report_heading.text = city_name + "  城池情报"
			_fill_city_stats(state)
			report_text.text = city_subtitle.text + "\n\n人口、经济、兵力、粮草、城防与军备随城内命令实时更新。\n当前为演示剧本，城池数值与势力归属待校定。"
		"records":
			report_heading.text = "施政记录"
			var lines: PackedStringArray = []
			var records: Array = store.chronicles.duplicate()
			records.reverse()
			for record in records:
				if str(record.get("city_id", "")) in ["", city_id]:
					lines.append("%d年 %d月  %s" % [int(record["year"]), int(record["month"]), str(record["message"])])
			report_text.text = "\n\n".join(lines) if not lines.is_empty() else "本城暂无施政记录。\n\n执行城内命令后，记录会自动保留。"
		"personnel":
			report_heading.text = city_name + "  人事"
			var governor: Dictionary = store.war.roster.officers.get(str(state.get("governor_id", "")), {})
			var guard: Dictionary = store.war.state[StateKeys.GARRISON_COMMANDERS].get(city_id, {})
			report_text.text = "所属势力：%s\n\n主政：%s\n守城主将：%s\n\n可在军情面板派遣本方可用武将。" % [str(store.faction_for(city_id).get("name", "无主")), str(governor.get("name", "地方吏员代管")), str(guard.get("name", "尚未任命"))]
		"faction":
			report_heading.text = "势力情报"
			var faction_id := str(state.get("faction", ""))
			var cities := 0
			var soldiers := 0
			var population := 0
			for other in store.scenario.get("places", {}).values():
				if faction_id != "" and other.has("population") and str(other.get("faction", "")) == faction_id:
					cities += 1
					soldiers += int(other.get("garrison", 0))
					population += int(other.get("population", 0))
			report_text.text = "所属势力：%s\n\n控制城池：%d 座\n势力人口：%s\n驻军总数：%s\n\n外交交涉暂未开放。" % [str(store.faction_for(city_id).get("name", "无主")), cities, _format_count(population), _format_count(soldiers)]
			if faction_id == "":
				report_text.text = "本城尚无所属势力。\n\n外交交涉暂未开放。"
		"settings":
			report_heading.text = "显示设置"
			report_text.text = "建筑名称：%s\n\n关闭名称后，仍可通过悬停图标查看建筑。\n\n该设置仅影响本次城内界面。" % ("显示" if show_building_names else "隐藏")
		"help":
			report_heading.text = "城内操作"
			report_text.text = "点击建筑图标，打开该处事务菜单。\n\n官府  人事、军事、计略、外交、方针、谍报\n方针  安民、开垦、征税\n市场  购粮、售粮\n农田  开垦\n兵营  征募、操练\n工坊  锻造兵装、修筑城防\n酒肆  访察民情\n\n选择命令后先查看消耗与结果，按“决定”执行，按“返回”取消。\n每项命令消耗 1 点行动力，按“进行”结算本月并恢复行动力。\n\n灰色指令暂不可用。Esc 返回上一层。"


func _toggle_building_names() -> void:
	show_building_names = not show_building_names
	for caption in building_labels:
		caption.hide()
	_refresh_building_icon_styles()
	_fill_report()


func _refresh_building_icon_styles() -> void:
	for building_id in building_buttons:
		BuildingAtlas.style_button(building_buttons[building_id], int(BUILDINGS[building_id]["icon"]), show_building_names, building_id == selected_building and building_id != "government")
		var button: TextureButton = building_buttons[building_id]
		button.custom_minimum_size = Vector2(56, 56)
		button.size = button.custom_minimum_size
		button.position = Vector2(12, 4)
		var holder: Control = button.get_parent()
		var caption: Label = holder.get_child(holder.get_child_count() - 1)
		caption.visible = show_building_names
		caption.position.y = 59


func _on_background_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_hide_menu()
		report_panel.hide()


func _close() -> void:
	hide()
	closed.emit()


func _enter_government() -> void:
	in_council = true
	council_view.show()
	for holder in building_holders:
		holder.hide()
	caption_title.text = "政\n厅"
	back_button.text = "返回城内"
	back_button.hide()
	_choose_council_category("civil")
	_hide_menu()


func _choose_council_category(category_id: String) -> void:
	if not in_council or not council_view.CATEGORIES.has(category_id):
		return
	council_menu_leave_time = 0.0
	council_category = category_id
	council_view.select_category(category_id)
	selected_building = "government"
	command_summary.hide()
	command_tip.hide()
	action_panel.custom_minimum_size = Vector2.ZERO
	action_panel.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	for child in action_list.get_parent().get_children():
		child.visible = child == action_list
	report_panel.hide()
	action_heading.text = str(council_view.CATEGORIES[category_id])
	_refresh_actions()
	_refresh_summary()
	var category_button: Button = council_view.buttons[category_id]
	action_panel.position = category_button.global_position - Vector2(0, 26)
	action_panel.show()
	CouncilLettering.apply(end_month_button, "proceed")
	_reveal_menu.call_deferred()


func _leave_government() -> void:
	in_council = false
	if council_view == null:
		return
	_set_modal(false)
	council_view.hide()
	for holder in building_holders:
		holder.show()
	caption_title.text = "城\n守\n参\n议"
	back_button.text = "返回地图"
	back_button.show()
	CouncilLettering.clear(end_month_button, "结束本月")
	_hide_menu()
	report_panel.hide()
	if action_view != null:
		action_view.hide()


func _back() -> void:
	if in_council:
		_leave_government()
	else:
		_close()


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		if action_view.visible:
			_cancel_action()
		elif report_panel.visible:
			_close_report()
		elif action_panel.visible:
			_hide_menu()
		elif in_council:
			_leave_government()
		else:
			_close()


func _format_count(value: int) -> String:
	return "%.1f万" % (float(value) / 10000.0) if value >= 10000 else str(value)


func _paper_panel(rect: Rect2, alpha: float, margin: int) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.position = rect.position
	panel.size = rect.size
	panel.add_theme_stylebox_override("panel", CitySkin.paper(alpha, margin))
	root_ui.add_child(panel)
	return panel


func _add_separator(row: HBoxContainer) -> void:
	var separator := VSeparator.new()
	separator.modulate = Color("8d7a59", 0.55)
	row.add_child(separator)


func _icon_button(index: int, dimensions: Vector2, callback: Callable) -> TextureButton:
	var button := TextureButton.new()
	CitySkin.style_icon_button(button, index)
	button.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	button.ignore_texture_size = true
	button.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
	button.custom_minimum_size = dimensions
	button.size = dimensions
	button.focus_mode = Control.FOCUS_NONE if index == 0 else Control.FOCUS_ALL
	button.pressed.connect(callback)
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	if index < 6 and not BuildingAtlas.CELLS.has(index):
		var symbol := TextureRect.new()
		symbol.texture = CitySkin.icon(index)
		symbol.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		symbol.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		symbol.mouse_filter = Control.MOUSE_FILTER_IGNORE
		symbol.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		symbol.offset_left = dimensions.x * 0.22
		symbol.offset_right = -dimensions.x * 0.22
		symbol.offset_top = dimensions.y * 0.22
		symbol.offset_bottom = -dimensions.y * 0.22
		button.add_child(symbol)
	IconEffects.bind_icon(button)
	return button


func _button(value: String, callback: Callable, primary: bool = false) -> Button:
	var button := Button.new()
	button.text = value
	button.pressed.connect(callback)
	button.add_theme_font_size_override("font_size", 13)
	button.add_theme_color_override("font_color", CitySkin.PALE)
	button.add_theme_color_override("font_hover_color", CitySkin.PALE)
	button.add_theme_color_override("font_pressed_color", CitySkin.PALE)
	CitySkin.style_button(button, primary)
	return button


func _menu_button(value: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = value
	button.pressed.connect(callback)
	button.add_theme_font_size_override("font_size", 16)
	CitySkin.style_button(button)
	button.add_theme_color_override("font_hover_color", CitySkin.INK)
	button.add_theme_color_override("font_pressed_color", CitySkin.INK)
	button.add_theme_stylebox_override("normal", CitySkin.menu_button())
	button.add_theme_stylebox_override("hover", CitySkin.menu_button(true))
	button.add_theme_stylebox_override("pressed", CitySkin.menu_pressed())
	button.add_theme_stylebox_override("disabled", CitySkin.menu_button(false, true))
	button.add_theme_stylebox_override("focus", CitySkin.focus_frame())
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	return button


func _close_button(callback: Callable) -> Button:
	var button := Button.new()
	button.text = "×"
	button.custom_minimum_size = Vector2(25, 25)
	button.pressed.connect(callback)
	button.tooltip_text = "关闭"
	button.add_theme_font_size_override("font_size", 19)
	CitySkin.style_button(button, true)
	for state in ["normal", "hover", "pressed", "disabled"]:
		var style := button.get_theme_stylebox(state).duplicate() as StyleBoxTexture
		style.set_content_margin_all(2)
		button.add_theme_stylebox_override(state, style)
	return button


func _building_location(building_id: String) -> Vector2:
	return SceneCatalog.location_for(city_id, building_id)
