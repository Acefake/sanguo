extends PanelContainer
## 地图顶栏：势力 · 日期 · 推进与速度 · 入口，一条横贯顶部。
##
## 只显示、不读游戏状态：持有者在状态变化时调用 set_faction / set_date / set_flow 写入文字；
## 按钮只发信号。入口按 add_entry 的顺序排在右侧。

signal flow_pressed
signal speed_selected(scale: float)
signal entry_pressed(id: String)

const Tokens = preload("res://scripts/ui/theme/ui_tokens.gd")
const Widgets = preload("res://scripts/ui/theme/ui_widgets.gd")
const SPEEDS := [1.0, 2.0, 4.0]
const HEIGHT := 48

var _badge_style: StyleBoxFlat
var _badge: Label
var _ruler: Label
var _summary: Label
var _date: Label
var _phase: Label
var _flow: Button
var _speed_group := ButtonGroup.new()
var _speeds: Array[Button] = []
var _entries: HBoxContainer
var _entry_buttons: Dictionary = {}


func _init() -> void:
	theme_type_variation = "BarPanel"
	set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	offset_left = Tokens.space(2)
	offset_right = -Tokens.space(2)
	offset_top = Tokens.space(1) + 4
	custom_minimum_size.y = HEIGHT
	mouse_filter = Control.MOUSE_FILTER_STOP
	var row := Widgets.hbox(2)
	add_child(row)
	row.add_child(_faction_block())
	row.add_child(Widgets.spring())
	var when := Widgets.vbox(0)
	when.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_child(when)
	_date = Widgets.label("")
	_date.theme_type_variation = "TitleLabel"
	_date.add_theme_font_size_override("font_size", Tokens.font_size("body") + 2)
	_date.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	when.add_child(_date)
	_phase = Widgets.label("", "DimLabel")
	_phase.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	when.add_child(_phase)
	var flow_row := Widgets.hbox(1)
	flow_row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_child(flow_row)
	_flow = Widgets.primary("进行", func() -> void: flow_pressed.emit())
	_flow.name = "FlowButton"
	_flow.custom_minimum_size = Vector2(72, Tokens.control("height_small") + 4)
	_flow.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_flow.tooltip_text = "推进十天 / 暂停（空格）"
	flow_row.add_child(_flow)
	for scale in SPEEDS:
		var pill := Widgets.pill("%d×" % int(scale), _speed_group, func() -> void: speed_selected.emit(scale))
		pill.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		flow_row.add_child(pill)
		_speeds.append(pill)
	row.add_child(Widgets.spring())
	_entries = Widgets.hbox(0)
	_entries.alignment = BoxContainer.ALIGNMENT_END
	row.add_child(_entries)


func _faction_block() -> Control:
	var block := Widgets.hbox(1)
	var badge := PanelContainer.new()
	badge.custom_minimum_size = Vector2(32, 32)
	badge.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_badge_style = StyleBoxFlat.new()
	_badge_style.set_corner_radius_all(Tokens.radius("control"))
	badge.add_theme_stylebox_override("panel", _badge_style)
	block.add_child(badge)
	_badge = Widgets.title("")
	_badge.add_theme_font_size_override("font_size", Tokens.font_size("body") + 2)
	# 徽记底是势力色（深），字固定用浅色，不随浅色面板的墨色正文。
	_badge.add_theme_color_override("font_color", Tokens.color("on_accent"))
	_badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_badge.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	badge.add_child(_badge)
	var text := Widgets.vbox(0)
	text.alignment = BoxContainer.ALIGNMENT_CENTER
	block.add_child(text)
	_ruler = Widgets.label("")
	text.add_child(_ruler)
	_summary = Widgets.label("", "MutedLabel")
	text.add_child(_summary)
	return block


## 右侧入口（文字按钮）。返回按钮以便持有者按场景显隐。
func add_entry(id: String, text: String) -> Button:
	var item := Widgets.text_button(text, func() -> void: entry_pressed.emit(id))
	item.name = "Entry_" + id
	item.add_theme_font_size_override("font_size", Tokens.font_size("body_small"))
	_entries.add_child(item)
	_entry_buttons[id] = item
	return item


func set_faction(short: String, name: String, color: Color, summary: String) -> void:
	_badge.text = short
	_badge_style.bg_color = color
	_ruler.text = name
	_summary.text = summary


func set_date(date: String, phase: String) -> void:
	_date.text = date
	_phase.text = phase
	_phase.visible = not phase.is_empty()


## 推进按钮文字与可用性；速度胶囊高亮当前倍速。
func set_flow(text: String, enabled: bool, scale: float) -> void:
	_flow.text = text
	_flow.disabled = not enabled
	for i in SPEEDS.size(): _speeds[i].set_pressed_no_signal(is_equal_approx(SPEEDS[i], scale))
