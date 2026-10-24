extends RefCounted
## 界面控件工厂：只设 theme_type_variation 与布局属性，外观全部来自根节点上的主题（ui_theme_builder）。
##
## 新界面一律从这里取控件，不再手写 StyleBox 或 add_theme_*_override。
## 间距参数以 8px 为一步（steps），与 theme.json 的 space.unit 对应。

const Tokens = preload("res://scripts/ui/theme/ui_tokens.gd")
const Text = preload("res://scripts/ui/ui_text.gd")
const Builder = preload("res://scripts/ui/theme/ui_theme_builder.gd")


## 给挂在 CanvasLayer 下的界面根节点挂统一主题。CanvasLayer 截断了 Control 的主题继承链，
## 它下面的控件拿不到根窗口的主题，所以每个 CanvasLayer 界面在自己的根 Control 上挂一次（同一个 Theme 实例）。
## palette 为 "glass" 时是地图 HUD 的浅纸色半透明外观（顶栏、抽屉、战况条、小地图、军报浮条）。
static func adopt_theme(root: Control, palette := "") -> void:
	root.theme = Builder.build(palette)


## 文字。variant 为空时是正文；可选 TitleLabel、DisplayLabel、MutedLabel、NoteLabel、CaptionLabel、DimLabel、AccentLabel。
static func label(text: String, variant := "", wrap := false) -> Label:
	var item := Label.new()
	item.text = Text.clean(text)
	item.theme_type_variation = variant
	item.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if wrap:
		item.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		item.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return item


static func title(text: String) -> Label:
	return label(text, "TitleLabel")


static func display(text: String) -> Label:
	return label(text, "DisplayLabel")


static func muted(text: String, wrap := false) -> Label:
	return label(text, "MutedLabel", wrap)


static func caption(text: String) -> Label:
	return label(text, "CaptionLabel")


static func _button(text: String, variant: String, action: Callable) -> Button:
	var item := Button.new()
	item.text = Text.clean(text)
	item.theme_type_variation = variant
	item.custom_minimum_size.y = Tokens.control("height")
	item.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	if action.is_valid():
		item.pressed.connect(action)
	return item


## 主按钮：朱红填充，每块界面最多一个。
static func primary(text: String, action := Callable()) -> Button:
	return _button(text, "PrimaryButton", action)


## 次按钮：描边胶囊。
static func secondary(text: String, action := Callable()) -> Button:
	return _button(text, "", action)


## 文字按钮：链接式，用于「重新检测」「更多」等弱操作。
static func text_button(text: String, action := Callable()) -> Button:
	var item := _button(text, "TextButton", action)
	item.custom_minimum_size.y = Tokens.control("height_small")
	return item


## 可切换胶囊（筛选、分页、速度、档位）。同组传同一个 ButtonGroup 即单选。
static func pill(text: String, group: ButtonGroup = null, action := Callable()) -> Button:
	var item := _button(text, "PillButton", action)
	item.toggle_mode = true
	item.button_group = group
	item.custom_minimum_size.y = Tokens.control("height_small") + 4
	return item


## 左侧分类导航项。
static func nav(text: String, group: ButtonGroup, action := Callable()) -> Button:
	var item := _button(text, "NavButton", action)
	item.toggle_mode = true
	item.button_group = group
	item.alignment = HORIZONTAL_ALIGNMENT_LEFT
	item.custom_minimum_size.y = Tokens.control("height") + 4
	return item


## 可点卡片（场景卡、档位卡）。内容由调用方加到返回的按钮下，子控件不拦截鼠标。
static func card_button(group: ButtonGroup = null, action := Callable()) -> Button:
	var item := _button("", "CardButton", action)
	item.toggle_mode = true
	item.button_group = group
	return item


## 浮层面板（默认面板样式：14 圆角、0.90 底色）。
static func panel() -> PanelContainer:
	return PanelContainer.new()


## 卡片面板：抬高一层底色，圆角 10。
static func card() -> PanelContainer:
	var item := PanelContainer.new()
	item.theme_type_variation = "CardPanel"
	return item


static func vbox(steps := 2) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", Tokens.space(steps) if steps > 0 else 4)
	return box


static func hbox(steps := 2) -> HBoxContainer:
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", Tokens.space(steps) if steps > 0 else 4)
	return box


## 撑满剩余空间的空白，用来把后面的控件推到行尾或底部。
static func spring() -> Control:
	var item := Control.new()
	item.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	item.size_flags_vertical = Control.SIZE_EXPAND_FILL
	item.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return item


## 固定高度的留白。
static func gap(steps := 1) -> Control:
	var item := Control.new()
	item.custom_minimum_size.y = Tokens.space(steps)
	item.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return item


static func rule() -> HSeparator:
	return HSeparator.new()


## 开关行：左文字右开关（CheckButton 原生把开关画在右侧）。
static func toggle_row(text: String, on := false) -> CheckButton:
	var item := CheckButton.new()
	item.text = Text.clean(text)
	item.button_pressed = on
	item.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	item.custom_minimum_size.y = Tokens.control("height") + Tokens.space(1)
	item.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	return item


## 数据格：小标签 + 大数字 + 可选单位。刷新数字用 stat_value(tile)。
static func stat_tile(caption_text: String, value := "", unit := "") -> PanelContainer:
	var tile := PanelContainer.new()
	tile.theme_type_variation = "TilePanel"
	tile.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var box := vbox(0)
	tile.add_child(box)
	box.add_child(label(caption_text, "DimLabel"))
	var row := hbox(1)
	box.add_child(row)
	var number := label(value, "TitleLabel")
	number.name = "Value"
	row.add_child(number)
	var suffix := label(unit, "DimLabel")
	suffix.name = "Unit"
	suffix.size_flags_vertical = Control.SIZE_SHRINK_END
	row.add_child(suffix)
	return tile


## stat_tile 里的数字与单位。
static func stat_value(tile: Control, value: String, unit := "") -> void:
	var row := tile.get_child(0).get_child(1)
	(row.get_node("Value") as Label).text = value
	(row.get_node("Unit") as Label).text = unit


## 滚动区域：只竖向滚动，内容横向撑满。
static func scroll(content: Control) -> ScrollContainer:
	var area := ScrollContainer.new()
	area.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	area.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var gutter := MarginContainer.new()
	gutter.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	gutter.add_theme_constant_override("margin_right", Tokens.space(2))
	area.add_child(gutter)
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	gutter.add_child(content)
	return area


## 半透明遮罩，铺满父节点，用于模态界面背后。
static func shade() -> ColorRect:
	var item := ColorRect.new()
	item.color = Tokens.color("shade")
	item.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	return item


## 移除并释放全部子节点。
static func clear(parent: Node) -> void:
	for item in parent.get_children():
		parent.remove_child(item)
		item.queue_free()
