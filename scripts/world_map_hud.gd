extends Control

const HudSkin = preload("res://scripts/city_ui_skin.gd")
const Layout = preload("res://scripts/ui_layout.gd")
const DIR := "res://assets/ui/world_hud/"
# Right-hand furniture is authored against the design canvas and then anchored,
# so it stays flush against the window edge at any width.
const RIGHT_MARGIN := 10.0
const TOOL_SIZE := Vector2(35, 25)
const SIDE_SIZE := Vector2(212, 76)
var map: Node3D
var root: Control
var tools: PopupPanel
var tool_list: VBoxContainer
var ruler: Label
var date: Label
var orders: Label
var emblem: Label
var portrait: TextureRect
var rank: Label
var advance: TextureButton
var advance_label: Label
var dispatch: Label
var last_ruler := ""
var crest_style: StyleBoxFlat
var portrait_paths: Dictionary

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	root = Control.new()
	# Anchored children below resolve against this rect, so it must track the
	# HUD rather than staying at its default zero size.
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	portrait_paths = JSON.parse_string(FileAccess.get_file_as_string(DIR + "portraits.json"))
	portrait = _image("", Vector2(26, 23), Vector2(142, 142))
	_image("header", Vector2(6, 8), Vector2(465, 165))
	_image("flag", Vector2(179, 24), Vector2(35, 68))
	var crest := Panel.new()
	crest.position = Vector2(181, 30)
	crest.size = Vector2(31, 37)
	crest.mouse_filter = Control.MOUSE_FILTER_IGNORE
	crest_style = StyleBoxFlat.new()
	crest_style.bg_color = Color("426744")
	crest_style.border_color = Color("b8a351")
	crest_style.set_border_width_all(2)
	crest.add_theme_stylebox_override("panel", crest_style)
	root.add_child(crest)
	emblem = _text("", Rect2(180, 33, 34, 32), 23)
	emblem.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	date = _text("", Rect2(229, 25, 168, 26), 19)
	ruler = _text("", Rect2(230, 51, 150, 26), 22)
	_image("icon-orders", Vector2(229, 82), Vector2(21, 21)).modulate = Color("f4df77")
	orders = _text("", Rect2(253, 79, 145, 28), 21)
	rank = _text("势力\n城池 0", Rect2(399, 34, 65, 64), 19)
	rank.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	advance = TextureButton.new()
	advance.position = Vector2(42, 125)
	advance.size = Vector2(102, 102)
	advance.ignore_texture_size = true
	advance.stretch_mode = TextureButton.STRETCH_SCALE
	advance.texture_normal = load(DIR + "advance-normal.png")
	advance.texture_hover = load(DIR + "advance-highlight.png")
	advance.texture_pressed = advance.texture_hover
	var mask := BitMap.new()
	mask.create_from_image_alpha(advance.texture_normal.get_image(), 0.1)
	advance.texture_click_mask = mask
	advance.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	advance.pressed.connect(func():
		if is_instance_valid(map.army_world): map.army_world.ui._next_turn())
	root.add_child(advance)
	advance_label = _text("进行\n▶", Rect2(0, 20, 102, 66), 27, Color("362a23"), advance)
	advance_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tools = PopupPanel.new()
	HudSkin.theme_window(tools)
	tools.add_theme_stylebox_override("panel", HudSkin.paper(1.0, 10))
	add_child(tools)
	tool_list = VBoxContainer.new()
	tool_list.custom_minimum_size.x = 180
	tool_list.add_theme_constant_override("separation", 5)
	tools.add_child(tool_list)
	var tool_strip := HBoxContainer.new()
	tool_strip.add_theme_constant_override("separation", 4)
	tool_strip.anchor_left = 1.0
	tool_strip.anchor_right = 1.0
	tool_strip.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	tool_strip.offset_top = 12
	root.add_child(tool_strip)
	var actions := [
		["trade", "在外军队", _show_armies],
		["advantage", "地图工具", _show_tools],
		["build", "出阵", _dispatch_selected],
		["city", "进入选中城池", _enter_selected],
		["north", "朝北", _north],
		["help", "操作说明", _help],
		["list", "军情与战报", _reports],
		["settings", "设置", _settings]]
	for i in range(actions.size()):
		var entry: Array = actions[i]
		var button := Button.new()
		button.custom_minimum_size = TOOL_SIZE
		HudSkin.style_button(button)
		for state in ["normal", "hover", "pressed", "disabled"]:
			var style: StyleBox = button.get_theme_stylebox(state).duplicate()
			style.content_margin_left = 4
			style.content_margin_right = 4
			style.content_margin_top = 2
			style.content_margin_bottom = 2
			button.add_theme_stylebox_override(state, style)
		button.icon = load(DIR + "icon-" + str(entry[0]) + ".png")
		button.expand_icon = true
		button.add_theme_constant_override("icon_max_width", 21)
		button.add_theme_color_override("icon_normal_color", Color("4a3530"))
		button.tooltip_text = entry[1]
		button.pressed.connect(entry[2])
		tool_strip.add_child(button)
	var side := PanelContainer.new()
	var border := StyleBoxFlat.new()
	border.bg_color = Color(0.12, 0.11, 0.06, 0.76)
	border.border_color = Color("c8b570")
	border.set_border_width_all(1)
	border.content_margin_top = 5
	border.content_margin_bottom = 5
	border.content_margin_left = 7
	border.content_margin_right = 7
	side.add_theme_stylebox_override("panel", border)
	# Anchored under the tool strip rather than positioned by hand.
	side.anchor_left = 1.0
	side.anchor_right = 1.0
	side.offset_left = Layout.right_offset(SIDE_SIZE.x, RIGHT_MARGIN)
	side.offset_right = -RIGHT_MARGIN
	side.offset_top = TOOL_SIZE.y + 14.0
	side.offset_bottom = side.offset_top + SIDE_SIZE.y
	root.add_child(side)
	var column := VBoxContainer.new()
	side.add_child(column)
	var tabs := HBoxContainer.new()
	column.add_child(tabs)
	for title in ["派遣", "武将"]:
		var tab := Button.new()
		tab.text = title
		tab.custom_minimum_size = Vector2(96, 20)
		tab.add_theme_font_size_override("font_size", 16)
		HudSkin.style_button(tab)
		var style := StyleBoxTexture.new()
		style.texture = load(DIR + "tab-highlight.png" if title == "派遣" else DIR + "tab-normal.png")
		tab.add_theme_stylebox_override("normal", style)
		tab.pressed.connect(_reports if title == "派遣" else map._open_officers)
		tabs.add_child(tab)
	dispatch = HudSkin.label("无派遣中武将", 19, Color("f1edda"))
	dispatch.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(dispatch)
	_resize()
	get_viewport().size_changed.connect(_resize)

func _resize() -> void:
	# The HUD lays out in design pixels; canvas_items stretch already scales it
	# to the window, so no manual scaling is needed. Right-hand furniture uses
	# anchors, which re-solve automatically.
	pass

func _process(_delta: float) -> void:
	var store = get_node("/root/GameState")
	var faction_id: String = str(store.war.state.get("player_faction", "liu_bei"))
	var faction: Dictionary = store.scenario.get("factions", {}).get(faction_id, {})
	var name: String = str(faction.get("name", ""))
	if name != last_ruler:
		last_ruler = name
		portrait.texture = load(portrait_paths[name]) if portrait_paths.has(name) else null
		crest_style.bg_color = Color(str(faction.get("color", "#426744")))
		ruler.text = name
		emblem.text = str(faction.get("short", ""))
	date.text = "%d年 %d月 %s" % [store.year, store.month, ["上旬", "中旬", "下旬"][clampi((store.day - 1) / 10, 0, 2)]]
	orders.text = "命令书  %d" % store.action_points
	var count := 0
	for city in store.scenario.get("places", {}).values():
		if str(city.get("faction", "")) == faction_id: count += 1
	rank.text = "势力\n城池 %d" % count
	advance_label.text = ("继续" if store.time_paused else "暂停") + "\nⅡ" if store.busy else "进行\n▶"
	var active: Array = store.war.active_armies(faction_id)
	dispatch.text = "无派遣中武将" if active.is_empty() else "派遣中部队  %d" % active.size()

func add_tool(control: Control) -> void:
	tool_list.add_child(control)

func _image(key: String, pos: Vector2, dimensions: Vector2) -> TextureRect:
	var image := TextureRect.new()
	if not key.is_empty(): image.texture = load(DIR + key + ".png")
	image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	image.stretch_mode = TextureRect.STRETCH_SCALE
	image.position = pos
	image.size = dimensions
	image.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(image)
	return image

func _text(value: String, rect: Rect2, font_size: int, color := Color("f1edda"), parent: Control = null) -> Label:
	var label := HudSkin.label(value, font_size, color)
	label.position = rect.position
	label.size = rect.size
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	(parent if parent != null else root).add_child(label)
	return label

func _show_tools() -> void:
	# `tools` is a child of this full-rect Control, so size.x is the correct
	# coordinate space (it can exceed the design width under aspect="expand").
	tools.position = Vector2i(int(size.x) - 205, 55)
	tools.popup()

func _reports() -> void:
	if is_instance_valid(map.army_world): map.army_world.ui.show_reports()

func _show_armies() -> void:
	if is_instance_valid(map.army_world): map.army_world.army_choice.get_popup().popup(Rect2i(int(get_viewport_rect().size.x) - 320, 45, 300, 100))

func _dispatch_selected() -> void:
	map._deploy_selected_city()

func _enter_selected() -> void:
	map._enter_selected_city()

func _north() -> void:
	map.yaw = 0.0

func _settings() -> void:
	get_node("/root/GameState").open_settings()

func _help() -> void:
	var dialog := AcceptDialog.new()
	HudSkin.theme_window(dialog)
	dialog.title = "地图操作"
	dialog.dialog_text = "滚轮缩放，左键 / 中键拖动，右键旋转\n点选城池查看，WASD 移动，Q / E 环绕\nF 全国视野，Home 朝北，G 切换格线\n空格推进 / 暂停，城池菜单可出阵或进入"
	add_child(dialog)
	dialog.confirmed.connect(dialog.queue_free)
	dialog.popup_centered()
