extends RefCounted
## 旧的战争面板皮肤，现为薄适配层：每个函数转调 scripts/ui/theme/ 的令牌与控件工厂。
##
## 仍在调用它的面板（军情、军团详情、军报等）迁到 UiWidgets 后即可删除本文件。
## 旧接口传的是字号与颜色；这里按字号档与颜色语义映射到主题变体，不再逐个覆盖样式。

const CitySkin = preload("res://scripts/ui/city_ui_skin.gd")
const Tokens = preload("res://scripts/ui/theme/ui_tokens.gd")
const Builder = preload("res://scripts/ui/theme/ui_theme_builder.gd")
const Widgets = preload("res://scripts/ui/theme/ui_widgets.gd")

static var INK: Color = Tokens.color("text")
static var MUTED: Color = Tokens.color("muted")
static var GOLD: Color = Tokens.color("label")
static var RED: Color = Tokens.color("accent")
static var GREEN: Color = Tokens.color("green")
static var PALE: Color = Tokens.color("on_accent")


static func font() -> SystemFont:
	return Tokens.body_font()


## 旧签名的文字：颜色决定语义变体，其余按字号分标题 / 正文 / 小字三档。
static func label(text: String, size: int = 13, color: Color = INK) -> Label:
	var variant := ""
	if color == MUTED: variant = "MutedLabel"
	elif color == RED: variant = "AccentLabel"
	elif color == GOLD: variant = "CaptionLabel"
	elif size >= 20: variant = "TitleLabel"
	elif size <= 13: variant = "NoteLabel"
	return Widgets.label(text, variant, true)


static func paper(margin: int = 12) -> StyleBox:
	var style := Builder.panel_box(0)
	style.set_content_margin_all(margin)
	return style


static func ribbon(margin: int = 10) -> StyleBox:
	return paper(margin)


static func button(text: String, action: Callable, primary: bool = false) -> Button:
	return Widgets.primary(text, action) if primary else Widgets.secondary(text, action)


## 旧接口给下拉框套样式；主题已覆盖 OptionButton，这里只补高度。
static func field(item: OptionButton) -> void:
	item.custom_minimum_size.y = Tokens.control("height")


static func framed_panel(margin: int = 16) -> PanelContainer:
	var panel := Widgets.panel()
	panel.add_theme_stylebox_override("panel", paper(margin))
	return panel


static func rule(parent: Control) -> void:
	parent.add_child(Widgets.rule())


## 选中态用 PillButton 的按下样式表达。
static func style_button(item: Button, selected: bool = false) -> void:
	item.theme_type_variation = "PillButton"
	item.toggle_mode = true
	item.set_pressed_no_signal(selected)
	item.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND


static func section(parent: Control, title: String) -> VBoxContainer:
	var box := Widgets.vbox(1)
	parent.add_child(box)
	box.add_child(Widgets.caption(title))
	return box


static func scroll(item: ScrollContainer) -> void:
	item.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED


static func clear(parent: Node) -> void:
	Widgets.clear(parent)
