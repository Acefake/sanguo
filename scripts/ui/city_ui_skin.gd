extends RefCounted

## 城内美术皮肤：SAN8R 贴图切片（羊皮纸、铜按钮、八角确认钮、图标）与羊皮纸色板。
##
## 主题相关的入口已转调 scripts/ui/theme/：build_theme()、theme_window() 返回由 data/ui/theme.json
## 生成的统一主题；font()/text_font() 取 UiTokens 的字体。仍画在羊皮纸上的城内界面继续用
## 这里的贴图样式和 apply_theme()（羊皮纸局部主题），迁移后逐项删除。

# `Theme` is a built-in Godot class, so a member with that name is a parse error.
const Palette = preload("res://scripts/ui/ui_theme.gd")
const Builder = preload("res://scripts/ui/theme/ui_theme_builder.gd")
const INK := Palette.INK
const BRONZE := Palette.BRONZE
const PAPER := Palette.PAPER
const PALE := Palette.PALE
const UI_PATH := "res://assets/city/han/ui/"
const SpriteAtlas = preload("res://scripts/ui/ui_sprite_atlas.gd")
const ToolbarAtlas = preload("res://scripts/ui/toolbar_sprite_atlas.gd")
const BuildingAtlas = preload("res://scripts/ui/building_sprite_atlas.gd")
const ICON_NAMES := ["government", "market", "farm", "barracks", "workshop", "tavern", "map", "officer", "records", "settings", "help", "return"]


static func font() -> SystemFont:
	# KaiTi; shared instance so the glyph cache survives interface refreshes.
	return Palette.font()


static func text_font() -> SystemFont:
	# Noto Sans SC, for small and data-dense text where KaiTi is illegible.
	return Palette.text_font()


static func label(value: String, size: int, color: Color = INK) -> Label:
	var result := Label.new()
	result.text = preload("res://scripts/ui/ui_text.gd").clean(value)
	result.add_theme_font_size_override("font_size", size)
	result.add_theme_color_override("font_color", color)
	result.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return result


## Window 是独立的主题作用域，不继承根窗口主题，需显式给它统一主题。
static func theme_window(window: Window) -> void:
	window.theme = Builder.build()


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


# Confirm / cancel buttons use the SAN8R octagon plate. This used to return the
# plain rectangle gradient, leaving every octagon_* region in the atlas unused and
# contradicting docs/城内UI元素说明.md ("决定与返回 | Buttons 区的红色八角按钮").
static func octagonal_button(primary: bool = true, hover: bool = false) -> StyleBoxTexture:
	return _octagon_style("octagon_hover" if hover else ("octagon_red" if primary else "octagon_pressed"))


static func _octagon_style(key: String) -> StyleBoxTexture:
	var style := StyleBoxTexture.new()
	style.texture = SpriteAtlas.texture(key)
	# The plate is 76x77 and ui_sprite_atlas already clips its corners to
	# transparent, so the corners are held fixed and only the edges stretch.
	style.texture_margin_left = 26
	style.texture_margin_right = 26
	style.texture_margin_top = 26
	style.texture_margin_bottom = 26
	style.axis_stretch_horizontal = StyleBoxTexture.AXIS_STRETCH_MODE_STRETCH
	style.axis_stretch_vertical = StyleBoxTexture.AXIS_STRETCH_MODE_STRETCH
	style.content_margin_left = 8
	style.content_margin_right = 8
	style.content_margin_top = 4
	style.content_margin_bottom = 4
	return style


static func style_confirm_button(button: Button, primary: bool = true) -> void:
	for pair in [["normal", "octagon_red"], ["hover", "octagon_hover"], ["pressed", "octagon_pressed"], ["disabled", "octagon_disabled"]]:
		button.add_theme_stylebox_override(str(pair[0]), _octagon_style(str(pair[1])))
	button.add_theme_stylebox_override("hover_pressed", _octagon_style("octagon_pressed"))
	# The atlas carries a hollow octagon ring for exactly this; a rectangular ring
	# around an octagon plate reads as a mismatch.
	button.add_theme_stylebox_override("focus", _octagon_style("octagon_outline"))
	button.custom_minimum_size = Vector2(72, 56)
	button.add_theme_font_size_override("font_size", 22)
	for state in ["font_color", "font_focus_color", "font_hover_color", "font_pressed_color"]:
		button.add_theme_color_override(state, PALE)
	button.add_theme_color_override("font_disabled_color", Palette.DISABLED_INK)
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND


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


# Disabled had no art of its own: it reused the normal texture and only dimmed
# it, so the four states were not actually distinct.
static func disabled_button_style() -> StyleBoxTexture:
	var style := StyleBoxTexture.new()
	style.texture = load("res://assets/ui/buttons/primary-disabled.png")
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
	var disabled := disabled_button_style()
	button.add_theme_stylebox_override("disabled", disabled)
	# Focus was StyleBoxEmpty here and in most other call sites, so keyboard
	# navigation showed no indication at all.
	button.add_theme_stylebox_override("focus", Palette.focus_ring())
	button.add_theme_stylebox_override("hover_pressed", primary_button_style(true))
	for state in ["font_color", "font_focus_color", "font_hover_color", "font_pressed_color"]:
		button.add_theme_color_override(state, INK)
	button.add_theme_color_override("font_disabled_color", Palette.DISABLED_INK)
	button.add_theme_color_override("icon_hover_color", INK)
	button.add_theme_color_override("icon_pressed_color", INK)
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND


## 全局统一主题（GameState 启动时挂到根窗口）。转调 UiThemeBuilder。
static func build_theme() -> Theme:
	return Builder.build()


## 羊皮纸局部主题，含 SAN8R 按钮切片；只给 apply_theme 用。
static func _parchment_theme() -> Theme:
	return Palette.build_parchment_theme({
		"normal": primary_button_style(),
		"hover": primary_button_style(true),
		"pressed": primary_button_style(true),
		"disabled": _disabled_button_style(),
	})


# Fills `theme` from the shared definition so every control type is covered,
# including the native ones (CheckButton, HSlider, AcceptDialog, ...) that
# previously rendered with Godot defaults. The paper tooltip and the textured
# scrollbar thumbs are restored on top because they are part of the current look.
static func apply_theme(theme: Theme) -> void:
	_merge_theme(theme, _parchment_theme())
	theme.default_font = Palette.font()
	theme.default_font_size = Palette.SIZE_BODY
	theme.set_stylebox("panel", "TooltipPanel", paper(0.98, 9))
	theme.set_color("font_color", "TooltipLabel", INK)
	theme.set_font_size("font_size", "TooltipLabel", Palette.SIZE_SMALL)
	theme.set_stylebox("scroll", "VScrollBar", dark_panel(0.30, 3))
	for state in ["grabber", "grabber_highlight", "grabber_pressed"]:
		theme.set_stylebox(state, "VScrollBar", sprite_style("button_hover" if state == "grabber_highlight" else "button_normal", 3, 4))


static func _disabled_button_style() -> StyleBoxTexture:
	return disabled_button_style()


static func _merge_theme(target: Theme, source: Theme) -> void:
	for control_type in source.get_stylebox_type_list():
		for item in source.get_stylebox_list(control_type):
			target.set_stylebox(item, control_type, source.get_stylebox(item, control_type))
	for control_type in source.get_color_type_list():
		for item in source.get_color_list(control_type):
			target.set_color(item, control_type, source.get_color(item, control_type))
	for control_type in source.get_font_type_list():
		for item in source.get_font_list(control_type):
			target.set_font(item, control_type, source.get_font(item, control_type))
	for control_type in source.get_font_size_type_list():
		for item in source.get_font_size_list(control_type):
			target.set_font_size(item, control_type, source.get_font_size(item, control_type))
	for control_type in source.get_constant_type_list():
		for item in source.get_constant_list(control_type):
			target.set_constant(item, control_type, source.get_constant(item, control_type))


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
