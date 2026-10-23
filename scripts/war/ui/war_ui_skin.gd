extends RefCounted

# War/agent panels. Deliberately flatter than the city interface, but the
# palette, fonts and control coverage now come from scripts/ui/ui_theme.gd so this
# stops being a second, competing skin.

const CitySkin = preload("res://scripts/ui/city_ui_skin.gd")
const UITheme = preload("res://scripts/ui/ui_theme.gd")
const PATH := "res://assets/war/inspector/"
const INK := UITheme.INK
const MUTED := UITheme.MUTED
const GOLD := UITheme.GOLD
const RED := UITheme.RED
const GREEN := UITheme.GREEN


# Body face. This used to be a private Microsoft YaHei / Noto Sans SC SystemFont,
# which made war panels the only place in the game not using KaiTi.
static func font() -> SystemFont:
	return CitySkin.text_font()


static func label(text: String, size: int = 13, color: Color = INK) -> Label:
	var item := Label.new()
	item.text = preload("res://scripts/ui/ui_text.gd").clean(text)
	item.add_theme_font_override("font", font())
	item.add_theme_font_size_override("font_size", size)
	item.add_theme_color_override("font_color", color)
	item.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	item.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	item.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return item

static func paper(margin: int = 12) -> StyleBoxTexture:
	var style := StyleBoxTexture.new()
	style.texture = load(PATH + "paper.png")
	style.set_content_margin_all(margin)
	style.texture_margin_left = 8
	style.texture_margin_right = 8
	style.texture_margin_top = 8
	style.texture_margin_bottom = 8
	style.axis_stretch_horizontal = StyleBoxTexture.AXIS_STRETCH_MODE_TILE
	style.axis_stretch_vertical = StyleBoxTexture.AXIS_STRETCH_MODE_TILE
	return style

static func ribbon(margin: int = 10) -> StyleBoxTexture:
	var style := paper(margin)
	style.texture = load(PATH + "ribbon.png")
	style.axis_stretch_horizontal = StyleBoxTexture.AXIS_STRETCH_MODE_STRETCH
	style.axis_stretch_vertical = StyleBoxTexture.AXIS_STRETCH_MODE_STRETCH
	return style

static func button(text: String, action: Callable, primary: bool = false) -> Button:
	var item := Button.new()
	item.text = preload("res://scripts/ui/ui_text.gd").clean(text)
	item.custom_minimum_size.y = 29
	item.add_theme_font_override("font", font())
	item.add_theme_font_size_override("font_size", 13)
	style_button(item, primary)
	item.pressed.connect(action)
	return item

static func field(item: OptionButton) -> void:
	item.add_theme_font_override("font", font())
	item.add_theme_font_size_override("font_size", 13)
	item.custom_minimum_size.y = 30
	style_button(item)
	var popup := item.get_popup()
	popup.add_theme_font_override("font", font())
	popup.add_theme_font_size_override("font_size", 13)
	popup.add_theme_stylebox_override("panel", paper(8))
	popup.add_theme_color_override("font_color", INK)

static func framed_panel(margin: int = 16) -> PanelContainer:
	var panel := preload("res://scripts/war/ui/war_paper_panel.gd").new()
	panel.add_theme_stylebox_override("panel", paper(margin))
	return panel

static func rule(parent: Control) -> void:
	var line := ColorRect.new()
	line.color = Color(0.53, 0.43, 0.28, 0.25)
	line.custom_minimum_size.y = 1
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(line)

static func style_button(item: Button, selected: bool = false) -> void:
	for state in ["normal", "hover", "pressed", "disabled"]:
		var style := StyleBoxFlat.new()
		style.bg_color = Color("80633e") if selected else Color(0.62, 0.52, 0.36, 0.08)
		if state in ["hover", "pressed"]: style.bg_color = Color("9a7b48") if selected else Color(0.62, 0.52, 0.36, 0.22)
		style.set_border_width_all(1)
		style.border_color = Color(0.55, 0.44, 0.28, 0.55)
		style.content_margin_left = 12
		style.content_margin_right = 12
		style.content_margin_top = 5
		style.content_margin_bottom = 5
		item.add_theme_stylebox_override(state, style)
	# Was StyleBoxEmpty; keyboard focus was invisible on every war control.
	item.add_theme_stylebox_override("focus", UITheme.focus_ring())
	item.add_theme_stylebox_override("hover_pressed", item.get_theme_stylebox("pressed"))
	for state in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		item.add_theme_color_override(state, Color("f1e5c9") if selected else INK)
	item.add_theme_color_override("font_disabled_color", UITheme.DISABLED_INK)
	item.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND

static func section(parent: Control, title: String) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	parent.add_child(box)
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 9)
	box.add_child(header)
	var caption := label(title, 15, Color("705638"))
	caption.autowrap_mode = TextServer.AUTOWRAP_OFF
	caption.add_theme_font_override("font", CitySkin.font())
	caption.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	header.add_child(caption)
	var line := ColorRect.new()
	line.color = Color(0.53, 0.43, 0.28, 0.22)
	line.custom_minimum_size.y = 1
	line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	header.add_child(line)
	return box

static func scroll(item: ScrollContainer) -> void:
	item.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var bar := item.get_v_scroll_bar()
	bar.custom_minimum_size.x = 5
	var track := StyleBoxFlat.new()
	track.bg_color = Color(0.4, 0.3, 0.15, 0.08)
	bar.add_theme_stylebox_override("scroll", track)
	for key in ["grabber", "grabber_highlight", "grabber_pressed"]:
		var thumb := StyleBoxFlat.new()
		thumb.bg_color = Color(GOLD, 0.6)
		thumb.set_corner_radius_all(2)
		bar.add_theme_stylebox_override(key, thumb)

static func clear(parent: Node) -> void:
	for item in parent.get_children():
		parent.remove_child(item)
		item.queue_free()
