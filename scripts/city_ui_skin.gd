extends RefCounted

const INK := Color("352e25")
const BRONZE := Color("9b8155")
const PAPER := Color("eee7d7")
const PALE := Color("f8efd9")
const UI_PATH := "res://assets/city/han/ui/"
const SpriteAtlas = preload("res://scripts/ui_sprite_atlas.gd")
const ToolbarAtlas = preload("res://scripts/toolbar_sprite_atlas.gd")
const BuildingAtlas = preload("res://scripts/building_sprite_atlas.gd")
const ICON_NAMES := ["government", "market", "farm", "barracks", "workshop", "tavern", "map", "officer", "records", "settings", "help", "return"]
static var shared_font: SystemFont


static func font() -> SystemFont:
	# Reuse the font and its glyph cache across labels and interface refreshes.
	if shared_font == null:
		shared_font = SystemFont.new()
		shared_font.font_names = PackedStringArray(["KaiTi"])
	return shared_font


static func label(value: String, size: int, color: Color = INK) -> Label:
	var result := Label.new()
	result.text = value
	result.add_theme_font_size_override("font_size", size)
	result.add_theme_color_override("font_color", color)
	result.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return result


static func paper(alpha: float = 0.92, margin: int = 10) -> StyleBoxTexture:
	var result := sprite_style("paper", margin, 4)
	result.modulate_color = Color(1.42, 1.39, 1.30, alpha)
	return result


static func window(margin: int = 14) -> StyleBoxTexture:
	return sheet(0.96, margin)


static func bronze_button(primary: bool = false, hover: bool = false) -> StyleBoxTexture:
	return sprite_style(("button_red_hover" if hover else "button_red") if primary else ("button_hover" if hover else "button_normal"))


static func menu_button(hover: bool = false, disabled: bool = false) -> StyleBoxTexture:
	var result := _button_style("button_disabled" if disabled else ("button_hover" if hover else "button_normal"))
	result.content_margin_left = 10
	result.content_margin_right = 10
	result.content_margin_top = 6
	result.content_margin_bottom = 6
	return result


static func menu_pressed() -> StyleBoxTexture:
	return _button_style("button_pressed")


static func sheet(alpha: float = 0.94, margin: int = 10) -> StyleBoxTexture:
	return paper(alpha, margin)


static func section_header(margin: int = 7) -> StyleBoxTexture:
	return sprite_style("header", margin, 3)


static func sprite_style(key: String, margin: int = 5, inset: int = 8) -> StyleBoxTexture:
	var result := StyleBoxTexture.new()
	result.texture = SpriteAtlas.texture(key)
	result.set_content_margin_all(margin)
	result.texture_margin_left = inset
	result.texture_margin_right = inset
	result.texture_margin_top = mini(inset, 6)
	result.texture_margin_bottom = mini(inset, 6)
	return result


static func dark_panel(alpha: float = 0.94, margin: int = 11) -> StyleBoxTexture:
	var result := sprite_style("dark_panel", margin, 6)
	result.modulate_color.a = alpha
	return result


static func _button_style(key: String) -> StyleBoxTexture:
	var result := sprite_style(key)
	var inset := 14 if key in ["button_normal", "button_hover", "button_pressed", "button_disabled"] else 8
	result.texture_margin_left = inset
	result.texture_margin_right = inset
	result.texture_margin_top = 12 if inset == 14 else 7
	result.texture_margin_bottom = result.texture_margin_top
	result.content_margin_left = 12
	result.content_margin_right = 12
	return result


static func style_tab_button(button: Button, selected: bool = false) -> void:
	style_button(button, true)
	button.add_theme_stylebox_override("normal", primary_button_style(selected))


static func tab_icon(key: String) -> Texture2D:
	return load(UI_PATH + "tab-" + key + ".svg")


static func octagonal_button(primary: bool = true, hover: bool = false) -> StyleBoxTexture:
	return primary_button_style(hover)


static func style_confirm_button(button: Button, primary: bool = true) -> void:
	style_button(button, primary)
	button.custom_minimum_size = Vector2(86, 36)
	button.add_theme_font_size_override("font_size", 22)


static func focus_frame() -> StyleBoxTexture:
	var result := sprite_style("focus_gold", 0, 17)
	result.texture_margin_top = 17
	result.texture_margin_bottom = 17
	result.expand_margin_left = 5
	result.expand_margin_right = 5
	result.expand_margin_top = 5
	result.expand_margin_bottom = 5
	return result


static func nameplate() -> StyleBoxTexture:
	return dark_panel(0.92, 5)


static func primary_button_style(highlight: bool = false) -> StyleBoxTexture:
	var style := StyleBoxTexture.new()
	style.texture = load("res://assets/ui/buttons/primary-%s.png" % ("highlight" if highlight else "normal"))
	style.texture_margin_left = 4
	style.texture_margin_right = 4
	style.texture_margin_top = 4
	style.texture_margin_bottom = 4
	style.content_margin_left = 12
	style.content_margin_right = 12
	style.content_margin_top = 5
	style.content_margin_bottom = 5
	return style


static func style_button(button: Button, primary: bool = false) -> void:
	button.add_theme_stylebox_override("normal", primary_button_style())
	button.add_theme_stylebox_override("hover", primary_button_style(true))
	button.add_theme_stylebox_override("pressed", primary_button_style(true))
	var disabled := primary_button_style()
	disabled.modulate_color = Color(0.75, 0.75, 0.75, 0.70)
	button.add_theme_stylebox_override("disabled", disabled)
	button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	for state in ["font_color", "font_focus_color"]:
		button.add_theme_color_override(state, INK)
	for state in ["font_hover_color", "font_pressed_color"]:
		button.add_theme_color_override(state, INK)
	button.add_theme_color_override("font_disabled_color", Color("a7a397"))
	button.add_theme_color_override("icon_hover_color", INK)
	button.add_theme_color_override("icon_pressed_color", INK)
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND


static func apply_theme(theme: Theme) -> void:
	theme.set_stylebox("panel", "TooltipPanel", paper(0.98, 9))
	theme.set_color("font_color", "TooltipLabel", INK)
	theme.set_font_size("font_size", "TooltipLabel", 13)
	var line := StyleBoxFlat.new()
	line.bg_color = Color(BRONZE, 0.42)
	line.content_margin_top = 1
	theme.set_stylebox("separator", "HSeparator", line)
	theme.set_constant("separation", "HSeparator", 4)
	var vertical := line.duplicate()
	vertical.content_margin_left = 1
	vertical.content_margin_top = 0
	theme.set_stylebox("separator", "VSeparator", vertical)
	var track := dark_panel(0.30, 3)
	theme.set_stylebox("scroll", "VScrollBar", track)
	for state in ["grabber", "grabber_highlight", "grabber_pressed"]:
		var thumb := sprite_style("button_hover" if state == "grabber_highlight" else "button_normal", 3, 4)
		theme.set_stylebox(state, "VScrollBar", thumb)


static func icon(index: int) -> Texture2D:
	return load(UI_PATH + "user-atlas/symbol-%s.svg" % ICON_NAMES[index]) as Texture2D


static func style_icon_button(button: TextureButton, index: int = -1) -> void:
	if BuildingAtlas.CELLS.has(index):
		BuildingAtlas.style_button(button, index)
		return
	if ToolbarAtlas.REGIONS.has(index):
		ToolbarAtlas.style_button(button, index)
		return
	button.texture_normal = SpriteAtlas.texture("token_normal")
	button.texture_hover = SpriteAtlas.texture("token_hover")
	button.texture_pressed = SpriteAtlas.texture("token_pressed")
	button.texture_disabled = SpriteAtlas.texture("token_disabled")
	button.texture_focused = SpriteAtlas.texture("token_outline")
