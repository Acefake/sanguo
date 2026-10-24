extends RefCounted

## 旧的羊皮纸主题，迁移期保留给仍画在羊皮纸贴图上的界面（城内、议事、人物页、单挑演出）。
##
## 全局主题已改由 scripts/ui/theme/ui_theme_builder.gd 从 data/ui/theme.json 生成，挂在根节点；
## 本文件只剩两件事：羊皮纸色板常量（这些界面在浅底上写深字）与 build_parchment_theme()，
## 由 city_ui_skin.apply_theme 合并进它们各自的局部主题。字体转调 UiTokens。
## 那几个界面迁到新主题后即可删除本文件。

const Tokens = preload("res://scripts/ui/theme/ui_tokens.gd")

# --- Palette -----------------------------------------------------------------
# Matches the paper-and-bronze SAN8R art the rest of the interface uses.
const INK := Color("352e25")
const BRONZE := Color("9b8155")
const GOLD := Color("c8a951")
const PAPER := Color("eee7d7")
const PALE := Color("f8efd9")
const MUTED := Color("81735b")
const RED := Color("a04a3d")
const GREEN := Color("647d53")
const DISABLED_INK := Color("a7a397")

# --- Type scale --------------------------------------------------------------
const SIZE_CAPTION := 11
const SIZE_SMALL := 13
const SIZE_BODY := 15

const UI_DIR := "res://assets/ui/"

static func font() -> SystemFont:
	return Tokens.title_font()


static func text_font() -> SystemFont:
	return Tokens.body_font()


# --- Geometry ----------------------------------------------------------------
# Rounded corners read as modern UI and fight the antique art. Keep these tight.
static func _radius(style: StyleBoxFlat, value: int) -> void:
	style.set_corner_radius_all(value)


static func _flat(bg: Color, border := Color(0, 0, 0, 0), width := 0) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = bg
	if width > 0:
		style.border_color = border
		style.set_border_width_all(width)
	_radius(style, 2)
	return style


# --- Theme construction ------------------------------------------------------

## 羊皮纸局部主题。`button_styles` 传 SAN8R 贴图切片的按钮样式。
static func build_parchment_theme(button_styles: Dictionary = {}) -> Theme:
	var theme := Theme.new()
	theme.default_font = font()
	theme.default_font_size = SIZE_BODY

	_style_label(theme)
	_style_button(theme, button_styles)
	_style_inputs(theme)
	_style_panels(theme)
	_style_popups(theme)
	_style_scrolling(theme)
	_style_misc(theme)
	return theme


static func _style_label(theme: Theme) -> void:
	theme.set_color("font_color", "Label", INK)
	theme.set_font("font", "Label", font())


static func _style_button(theme: Theme, supplied: Dictionary) -> void:
	# Prefer the SAN8R atlas slices when the caller supplies them; fall back to a
	# flat bronze so a bare build still reads as part of the same interface.
	var normal: StyleBox = supplied.get("normal", _flat(Color(0.62, 0.52, 0.36, 0.10), Color(BRONZE, 0.55), 1))
	var hover: StyleBox = supplied.get("hover", _flat(Color(BRONZE, 0.24), GOLD, 1))
	var pressed: StyleBox = supplied.get("pressed", _flat(Color(BRONZE, 0.36), GOLD, 1))
	var disabled: StyleBox = supplied.get("disabled", _flat(Color(0.5, 0.47, 0.42, 0.06), Color(BRONZE, 0.22), 1))
	for pair in [["normal", normal], ["hover", hover], ["pressed", pressed], ["disabled", disabled]]:
		theme.set_stylebox(str(pair[0]), "Button", pair[1])
	# Keyboard focus was StyleBoxEmpty almost everywhere, so focus was invisible.
	theme.set_stylebox("focus", "Button", focus_ring())
	theme.set_stylebox("hover_pressed", "Button", pressed)
	for state in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		theme.set_color(state, "Button", INK)
	theme.set_color("font_disabled_color", "Button", DISABLED_INK)
	theme.set_color("font_outline_color", "Button", Color(PAPER, 0.0))
	theme.set_constant("h_separation", "Button", 4)

	# MenuButton and OptionButton inherit Button's box but need their own arrow.
	_style_option(theme, "OptionButton", normal, hover, pressed, disabled)


static func focus_ring() -> StyleBoxFlat:
	var ring := _flat(Color(0, 0, 0, 0), GOLD, 2)
	ring.set_corner_radius_all(2)
	ring.set_expand_margin_all(2)
	return ring


static func _style_option(theme: Theme, type: String, normal: StyleBox, hover: StyleBox, pressed: StyleBox, disabled: StyleBox) -> void:
	for pair in [["normal", normal], ["hover", hover], ["pressed", pressed], ["disabled", disabled]]:
		theme.set_stylebox(str(pair[0]), type, pair[1])
	theme.set_stylebox("focus", type, focus_ring())
	theme.set_color("font_color", type, INK)
	theme.set_color("font_hover_color", type, INK)
	theme.set_color("font_pressed_color", type, INK)
	theme.set_color("font_focus_color", type, INK)
	theme.set_color("font_disabled_color", type, DISABLED_INK)
	theme.set_color("arrow_color", type, INK)
	theme.set_color("arrow_pressed_color", type, INK)
	theme.set_color("arrow_hover_color", type, INK)
	theme.set_constant("arrow_margin", type, 8)


static func _style_inputs(theme: Theme) -> void:
	var field := _flat(Color(PALE, 0.55), Color(BRONZE, 0.60), 1)
	field.content_margin_left = 8
	field.content_margin_right = 8
	field.content_margin_top = 6
	field.content_margin_bottom = 6
	for type in ["LineEdit", "TextEdit"]:
		theme.set_stylebox("normal", type, field)
		theme.set_stylebox("focus", type, _flat(Color(PALE, 0.85), GOLD, 2))
		theme.set_stylebox("read_only", type, _flat(Color(BRONZE, 0.06), Color(BRONZE, 0.35), 1))
		theme.set_color("font_color", type, INK)
		theme.set_color("font_placeholder_color", type, MUTED)
		theme.set_color("font_selected_color", type, PALE)
		theme.set_color("selection_color", type, Color(BRONZE, 0.55))
		theme.set_color("caret_color", type, INK)
		theme.set_font("font", type, text_font())

	# Toggles previously shipped with the engine's blue-grey default.
	for type in ["CheckButton", "CheckBox"]:
		theme.set_stylebox("normal", type, _flat(Color(0, 0, 0, 0)))
		theme.set_stylebox("hover", type, _flat(Color(0, 0, 0, 0)))
		theme.set_stylebox("pressed", type, _flat(Color(0, 0, 0, 0)))
		theme.set_stylebox("focus", type, _flat(Color(0, 0, 0, 0)))
		theme.set_color("font_color", type, INK)
		theme.set_color("font_hover_color", type, INK)
		theme.set_color("font_pressed_color", type, INK)
		theme.set_color("font_focus_color", type, INK)
		theme.set_color("font_disabled_color", type, DISABLED_INK)
		theme.set_font("font", type, text_font())
		theme.set_color("font_selected_color", type, INK)
	theme.set_icon("checked", "CheckButton", load(UI_DIR + "check-on.svg"))
	theme.set_icon("unchecked", "CheckButton", load(UI_DIR + "check-off.svg"))
	theme.set_icon("checked", "CheckBox", load(UI_DIR + "check-on.svg"))
	theme.set_icon("unchecked", "CheckBox", load(UI_DIR + "check-off.svg"))

	for type in ["HSlider", "VSlider"]:
		theme.set_stylebox("slider", type, _flat(Color(BRONZE, 0.22)))
		theme.set_stylebox("grabber_area", type, _flat(Color(BRONZE, 0.65)))
		theme.set_stylebox("grabber_area_highlight", type, _flat(GOLD))
		theme.set_constant("center_grabber", type, 1)

	# SpinBox is a LineEdit plus up/down buttons.
	theme.set_stylebox("up_normal", "SpinBox", _flat(Color(BRONZE, 0.16), Color(BRONZE, 0.45), 1))
	theme.set_stylebox("up_hover", "SpinBox", _flat(Color(BRONZE, 0.30), GOLD, 1))
	theme.set_stylebox("up_pressed", "SpinBox", _flat(Color(BRONZE, 0.42), GOLD, 1))
	theme.set_stylebox("down_normal", "SpinBox", _flat(Color(BRONZE, 0.16), Color(BRONZE, 0.45), 1))
	theme.set_stylebox("down_hover", "SpinBox", _flat(Color(BRONZE, 0.30), GOLD, 1))
	theme.set_stylebox("down_pressed", "SpinBox", _flat(Color(BRONZE, 0.42), GOLD, 1))
	theme.set_icon("updown", "SpinBox", load(UI_DIR + "spin-sep.svg"))


static func _style_panels(theme: Theme) -> void:
	var panel := _flat(Color(PAPER, 0.92), Color(BRONZE, 0.50), 1)
	panel.content_margin_left = 10
	panel.content_margin_right = 10
	panel.content_margin_top = 8
	panel.content_margin_bottom = 8
	for type in ["Panel", "PanelContainer"]:
		theme.set_stylebox("panel", type, panel)


static func _style_popups(theme: Theme) -> void:
	var surface := _flat(Color(PAPER, 0.98), Color(BRONZE, 0.65), 1)
	surface.content_margin_left = 6
	surface.content_margin_right = 6
	surface.content_margin_top = 6
	surface.content_margin_bottom = 6
	surface.shadow_color = Color(0, 0, 0, 0.35)
	surface.shadow_size = 4
	for type in ["PopupMenu", "PopupPanel"]:
		theme.set_stylebox("panel", type, surface)
	theme.set_color("font_color", "PopupMenu", INK)
	theme.set_color("font_hover_color", "PopupMenu", INK)
	theme.set_color("font_disabled_color", "PopupMenu", DISABLED_INK)
	theme.set_color("font_accelerator_color", "PopupMenu", MUTED)
	theme.set_font("font", "PopupMenu", text_font())
	theme.set_stylebox("hover", "PopupMenu", _flat(Color(BRONZE, 0.30)))
	theme.set_stylebox("separator", "PopupMenu", _flat(Color(BRONZE, 0.35)))
	theme.set_constant("h_separation", "PopupMenu", 8)
	theme.set_constant("v_separation", "PopupMenu", 4)

	var tooltip := _flat(Color(PAPER, 0.99), GOLD, 1)
	tooltip.content_margin_left = 10
	tooltip.content_margin_right = 10
	tooltip.content_margin_top = 7
	tooltip.content_margin_bottom = 7
	tooltip.shadow_color = Color(0, 0, 0, 0.4)
	tooltip.shadow_size = 5
	theme.set_stylebox("panel", "TooltipPanel", tooltip)
	theme.set_stylebox("panel", "TooltipLabel", tooltip)
	theme.set_color("font_color", "TooltipLabel", INK)
	theme.set_font("font", "TooltipLabel", text_font())
	theme.set_font_size("font_size", "TooltipLabel", SIZE_SMALL)

	# AcceptDialog and the settings Window both embedded their own panels.
	var dialog := _flat(Color(PAPER, 0.99), Color(BRONZE, 0.70), 1)
	dialog.content_margin_left = 14
	dialog.content_margin_right = 14
	dialog.content_margin_top = 12
	dialog.content_margin_bottom = 12
	dialog.shadow_color = Color(0, 0, 0, 0.45)
	dialog.shadow_size = 8
	for type in ["AcceptDialog", "ConfirmationDialog", "Window"]:
		theme.set_stylebox("panel", type, dialog)
	theme.set_color("title_color", "Window", INK)
	theme.set_color("font_color", "Window", INK)


static func _style_scrolling(theme: Theme) -> void:
	for type in ["VScrollBar", "HScrollBar"]:
		theme.set_stylebox("scroll", type, _flat(Color(BRONZE, 0.12)))
		theme.set_stylebox("grabber", type, _flat(Color(BRONZE, 0.55)))
		theme.set_stylebox("grabber_highlight", type, _flat(GOLD))
		theme.set_stylebox("grabber_pressed", type, _flat(Color(BRONZE, 0.75)))
	theme.set_stylebox("panel", "ItemList", _flat(Color(PAPER, 0.92), Color(BRONZE, 0.5), 1))
	theme.set_stylebox("selected", "ItemList", _flat(Color(BRONZE, 0.38)))
	theme.set_stylebox("selected_focus", "ItemList", _flat(Color(BRONZE, 0.5)))
	theme.set_color("font_color", "ItemList", INK)
	theme.set_color("font_selected_color", "ItemList", PALE)
	theme.set_stylebox("panel", "Tree", _flat(Color(PAPER, 0.92), Color(BRONZE, 0.5), 1))


static func _style_misc(theme: Theme) -> void:
	var line := _flat(Color(BRONZE, 0.42))
	line.content_margin_top = 1
	theme.set_stylebox("separator", "HSeparator", line)
	var vline := _flat(Color(BRONZE, 0.42))
	vline.content_margin_left = 1
	theme.set_stylebox("separator", "VSeparator", vline)

	# ProgressBar was a bare default in the city and army panels.
	var track := _flat(Color(BRONZE, 0.20))
	theme.set_stylebox("background", "ProgressBar", track)
	theme.set_stylebox("fill", "ProgressBar", _flat(Color(BRONZE, 0.85)))
	theme.set_color("font_color", "ProgressBar", INK)
	theme.set_font_size("font_size", "ProgressBar", SIZE_CAPTION)

	theme.set_stylebox("tab_selected", "TabBar", _flat(Color(PAPER, 0.95), Color(BRONZE, 0.6), 1))
	theme.set_stylebox("tab_unselected", "TabBar", _flat(Color(BRONZE, 0.10), Color(BRONZE, 0.35), 1))
	theme.set_stylebox("tab_hovered", "TabBar", _flat(Color(BRONZE, 0.24), GOLD, 1))
	theme.set_color("font_selected_color", "TabBar", INK)
	theme.set_color("font_unselected_color", "TabBar", MUTED)
	theme.set_color("font_hovered_color", "TabBar", INK)
	theme.set_font("font", "TabBar", font())

	theme.set_stylebox("normal", "RichTextLabel", StyleBoxEmpty.new())
	theme.set_color("default_color", "RichTextLabel", INK)
	theme.set_font("normal_font", "RichTextLabel", text_font())
	theme.set_font("bold_font", "RichTextLabel", text_font())