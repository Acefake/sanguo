extends PanelContainer
## 底部军报浮条：一行最新送达的军报，右侧是军报数；点击整条打开军报簿。
##
## 持有者在推进结束或收到新军报时调用 show_latest，文字不变时不触发重排。

signal open_requested

const Tokens = preload("res://scripts/ui/theme/ui_tokens.gd")
const Widgets = preload("res://scripts/ui/theme/ui_widgets.gd")
const WIDTH := 620

var _dot: ColorRect
var _line: Label
var _count: Button


func _init() -> void:
	theme_type_variation = "BarPanel"
	anchor_left = 0.5
	anchor_right = 0.5
	anchor_top = 1.0
	anchor_bottom = 1.0
	offset_left = -WIDTH / 2.0
	offset_right = WIDTH / 2.0
	offset_top = -Tokens.space(7)
	offset_bottom = -Tokens.space(2)
	grow_vertical = Control.GROW_DIRECTION_BEGIN
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var row := Widgets.hbox(1)
	add_child(row)
	_dot = ColorRect.new()
	_dot.custom_minimum_size = Vector2(8, 8)
	_dot.color = Tokens.color("label")
	_dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(_dot)
	_line = Widgets.label("")
	_line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_line.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_line.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(_line)
	_count = Widgets.text_button("", func() -> void: open_requested.emit())
	row.add_child(_count)
	visible = false


## 显示最新一条；没有军报时隐藏整条。urgent 时圆点用强调色。
func show_latest(text: String, count: int, urgent := false) -> void:
	visible = count > 0
	if not visible: return
	if _line.text != text: _line.text = text
	_count.text = "军报 %d" % count
	_dot.color = get_theme_color("accent" if urgent else "label", "Tokens")


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		open_requested.emit()
		accept_event()
