extends RefCounted
## 由设计令牌生成整套 Godot Theme，挂在场景树根窗口上一次，所有控件继承。
##
## 子控件不再逐个 add_theme_*_override：要换外观就设 theme_type_variation 为下列变体之一。
##   Label：TitleLabel、DisplayLabel、MutedLabel、CaptionLabel、DimLabel、AccentLabel、HaloLabel、HaloMutedLabel
##   Button：PrimaryButton（朱红填充）、默认 Button（描边胶囊，即次按钮）、TextButton、
##           PillButton（可切换的筛选/分页/速度胶囊）、NavButton（左侧分类）、CardButton（可点卡片）
##   PanelContainer：默认（浮层面板）、CardPanel、TilePanel、BarPanel、FlatPanel
## 开关、复选框、滑块的图标在这里按令牌画出，不依赖贴图。

const Tokens = preload("res://scripts/ui/theme/ui_tokens.gd")

static var _cached: Dictionary
## 正在构建的调色板名；只在 build() 同步执行期间非空，_c/_a 据此取色。
static var _p := ""


## 整套主题。palette 为空是默认深色；"glass" 是地图 HUD 的浅纸色半透明面板（见 theme.json palettes）。
## 每个调色板同一进程内只构建一次；Window（独立主题作用域）拿同一个实例。
static func build(palette := "") -> Theme:
	if _cached.has(palette):
		return _cached[palette]
	_p = palette
	var theme := Theme.new()
	theme.default_font = Tokens.body_font()
	theme.default_font_size = Tokens.font_size("body")
	_labels(theme)
	_buttons(theme)
	_panels(theme)
	_inputs(theme)
	_toggles(theme)
	_popups(theme)
	_scrolling(theme)
	_misc(theme)
	_token_colors(theme)
	_p = ""
	_cached[palette] = theme
	return theme


static func _c(name: String, alpha := -1.0) -> Color:
	return Tokens.color(name, alpha, _p)


static func _a(name: String) -> float:
	return Tokens.alpha(name, _p)


## 颜色令牌也登记成主题色（类型 "Tokens"）：自绘控件用 get_theme_color("text", "Tokens") 取色，
## 就会跟随所在子树的调色板，而不是写死默认深色。
static func _token_colors(theme: Theme) -> void:
	for name in Tokens.color_names():
		theme.set_color(name, "Tokens", _c(name))


## 圆角纯色样式盒。radius 取令牌名，border 为 0 时不画描边。
static func box(fill: Color, radius_name: String, border := Color(0, 0, 0, 0), border_width := 0) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.set_corner_radius_all(Tokens.radius(radius_name))
	style.corner_detail = 6
	if border_width > 0:
		style.border_color = border
		style.set_border_width_all(border_width)
	style.anti_aliasing = true
	return style


## 浮层面板：panel 底色按 alpha.panel 透明、14 圆角、1px rim 描边、柔和投影。palette 同 build()。
static func panel_box(padding_steps := 3, palette := "") -> StyleBoxFlat:
	var style := box(Tokens.color("panel", Tokens.alpha("panel", palette), palette), "panel", Tokens.color("rim", -1, palette), Tokens.control("border"))
	style.set_content_margin_all(Tokens.space(padding_steps))
	style.shadow_color = Color(Tokens.color("ink", -1, palette), Tokens.alpha("shadow", palette))
	style.shadow_size = Tokens.space(2)
	return style


static func _pad(style: StyleBox, horizontal: int, vertical: int) -> StyleBox:
	style.content_margin_left = horizontal
	style.content_margin_right = horizontal
	style.content_margin_top = vertical
	style.content_margin_bottom = vertical
	return style


static func _labels(theme: Theme) -> void:
	theme.set_color("font_color", "Label", _c("text"))
	theme.set_font("font", "Label", Tokens.body_font())
	theme.set_constant("line_spacing", "Label", 4)
	var variants := {
		"TitleLabel": ["text", "title", Tokens.title_font()],
		"DisplayLabel": ["text", "display", Tokens.title_font()],
		"MutedLabel": ["muted", "note", Tokens.body_font()],
		"NoteLabel": ["text", "note", Tokens.body_font()],
		"CaptionLabel": ["label", "caption", Tokens.body_font()],
		"DimLabel": ["dim", "caption", Tokens.body_font()],
		"AccentLabel": ["accent", "note", Tokens.body_font()],
	}
	for name in variants:
		var spec: Array = variants[name]
		theme.set_type_variation(name, "Label")
		theme.set_color("font_color", name, _c(spec[0]))
		theme.set_font_size("font_size", name, Tokens.font_size(spec[1]))
		theme.set_font("font", name, spec[2])
	# 直接压在地图上的文字（没有底板）：一圈面板色描边当光晕，地形明暗怎么变都与字保持对比。
	for pair in [["HaloLabel", "text"], ["HaloMutedLabel", "muted"]]:
		theme.set_type_variation(pair[0], "Label")
		theme.set_color("font_color", pair[0], _c(pair[1]))
		theme.set_color("font_outline_color", pair[0], _c("panel", 0.92))
		theme.set_constant("outline_size", pair[0], 6)
		theme.set_font_size("font_size", pair[0], Tokens.font_size("note"))
		theme.set_font("font", pair[0], Tokens.body_font())


static func _button_states(theme: Theme, type: String, normal: StyleBox, hover: StyleBox, pressed: StyleBox, disabled: StyleBox, text: Color, text_pressed: Color) -> void:
	theme.set_stylebox("normal", type, normal)
	theme.set_stylebox("hover", type, hover)
	theme.set_stylebox("pressed", type, pressed)
	theme.set_stylebox("hover_pressed", type, pressed)
	theme.set_stylebox("disabled", type, disabled)
	var ring := box(Color(0, 0, 0, 0), "pill", _c("label", 0.8), Tokens.control("focus"))
	ring.set_expand_margin_all(2)
	theme.set_stylebox("focus", type, ring)
	for state in ["font_color", "font_hover_color", "font_focus_color"]:
		theme.set_color(state, type, text)
	theme.set_color("font_pressed_color", type, text_pressed)
	theme.set_color("font_hover_pressed_color", type, text_pressed)
	theme.set_color("font_disabled_color", type, Color(text, _a("disabled_text")))
	for state in ["icon_normal_color", "icon_hover_color", "icon_focus_color"]:
		theme.set_color(state, type, text)
	theme.set_color("icon_pressed_color", type, text_pressed)


static func _buttons(theme: Theme) -> void:
	var h := Tokens.space(2)
	var v := Tokens.space(1) - 2
	var line := _c("text", 0.22)
	var border := Tokens.control("border")
	var clear := Color(0, 0, 0, 0)
	var text := _c("text")
	var on_accent := _c("on_accent")

	# 次按钮（默认 Button）：描边胶囊。
	_button_states(theme, "Button",
		_pad(box(clear, "pill", line, border), h, v),
		_pad(box(_c("text", _a("hover")), "pill", _c("text", 0.36), border), h, v),
		_pad(box(_c("text", _a("pressed")), "pill", _c("text", 0.36), border), h, v),
		_pad(box(clear, "pill", _c("text", 0.10), border), h, v),
		text, text)
	theme.set_font_size("font_size", "Button", Tokens.font_size("body_small"))
	theme.set_constant("h_separation", "Button", Tokens.space(1))

	theme.set_type_variation("PrimaryButton", "Button")
	_button_states(theme, "PrimaryButton",
		_pad(box(_c("accent"), "pill"), h, v),
		_pad(box(_c("accent_hover"), "pill"), h, v),
		_pad(box(_c("accent_pressed"), "pill"), h, v),
		_pad(box(_c("accent", 0.35), "pill"), h, v),
		on_accent, on_accent)

	theme.set_type_variation("TextButton", "Button")
	var flat := _pad(StyleBoxEmpty.new(), Tokens.space(1), v)
	_button_states(theme, "TextButton", flat, flat, flat, flat, _c("label"), _c("text"))
	theme.set_color("font_hover_color", "TextButton", _c("text"))
	theme.set_font_size("font_size", "TextButton", Tokens.font_size("note"))

	# 可切换胶囊：未选描边，选中朱红填充。筛选、分页、速度、档位都用它。
	theme.set_type_variation("PillButton", "Button")
	_button_states(theme, "PillButton",
		_pad(box(clear, "pill", line, border), h, v),
		_pad(box(_c("text", _a("hover")), "pill", _c("text", 0.36), border), h, v),
		_pad(box(_c("accent"), "pill"), h, v),
		_pad(box(clear, "pill", _c("text", 0.10), border), h, v),
		_c("muted"), on_accent)
	theme.set_color("font_hover_color", "PillButton", text)
	theme.set_font_size("font_size", "PillButton", Tokens.font_size("note"))

	# 左侧分类导航：选中项底色抬高，左缘一条朱红。
	theme.set_type_variation("NavButton", "Button")
	var nav_on := box(_c("raised"), "control")
	nav_on.border_color = _c("accent")
	nav_on.border_width_left = 3
	_button_states(theme, "NavButton",
		_pad(StyleBoxEmpty.new(), Tokens.space(3), Tokens.space(1)),
		_pad(box(_c("text", _a("hover")), "control"), Tokens.space(3), Tokens.space(1)),
		_pad(nav_on, Tokens.space(3), Tokens.space(1)),
		_pad(StyleBoxEmpty.new(), Tokens.space(3), Tokens.space(1)),
		_c("muted"), text)
	theme.set_color("font_hover_color", "NavButton", text)

	# 可点卡片：抬高底色；选中为 2px 朱红描边。
	theme.set_type_variation("CardButton", "Button")
	var card_on := box(_c("raised"), "card", _c("accent"), 2)
	_button_states(theme, "CardButton",
		_pad(box(_c("raised"), "card", _c("line"), border), Tokens.space(2), Tokens.space(1)),
		_pad(box(_c("raised").lightened(0.04), "card", _c("text", 0.20), border), Tokens.space(2), Tokens.space(1)),
		_pad(card_on, Tokens.space(2), Tokens.space(1)),
		_pad(box(_c("raised", 0.5), "card", _c("line"), border), Tokens.space(2), Tokens.space(1)),
		text, text)

	# 下拉框沿用次按钮，但用小圆角，才放得下右侧箭头。
	for type in ["OptionButton", "MenuButton"]:
		_button_states(theme, type,
			_pad(box(_c("raised"), "control", _c("line"), border), Tokens.space(2), v),
			_pad(box(_c("raised").lightened(0.04), "control", _c("text", 0.22), border), Tokens.space(2), v),
			_pad(box(_c("raised").lightened(0.06), "control", _c("text", 0.30), border), Tokens.space(2), v),
			_pad(box(_c("raised", 0.5), "control", _c("line"), border), Tokens.space(2), v),
			text, text)
		theme.set_font_size("font_size", type, Tokens.font_size("body_small"))
	theme.set_color("arrow_color", "OptionButton", _c("muted"))
	theme.set_constant("arrow_margin", "OptionButton", Tokens.space(1))


static func _panels(theme: Theme) -> void:
	for type in ["Panel", "PanelContainer"]:
		theme.set_stylebox("panel", type, panel_box(3, _p))
	var variants := {
		"CardPanel": _pad(box(_c("raised"), "card", _c("line"), Tokens.control("border")), Tokens.space(2), Tokens.space(2)),
		"TilePanel": _pad(box(_c("raised"), "card"), Tokens.space(2), Tokens.space(1) + 4),
		"BarPanel": _bar_box(),
		"FlatPanel": StyleBoxEmpty.new(),
	}
	for name in variants:
		theme.set_type_variation(name, "PanelContainer")
		theme.set_stylebox("panel", name, variants[name])


## 地图上的条形浮层（顶栏、军报浮条）：与浮层面板同色同圆角、内边距更紧，投影更浅。
static func _bar_box() -> StyleBoxFlat:
	var style := box(_c("panel", _a("panel")), "panel", _c("rim"), Tokens.control("border"))
	_pad(style, Tokens.space(2), Tokens.space(1))
	style.shadow_color = Color(_c("ink"), _a("shadow") * 0.75)
	style.shadow_size = Tokens.space(1) + 4
	style.shadow_offset = Vector2(0, 2)
	return style


static func _inputs(theme: Theme) -> void:
	var border := Tokens.control("border")
	var field := _pad(box(_c("ink", 0.6), "control", _c("line"), border), Tokens.space(1) + 4, Tokens.space(1) - 2)
	var focus := _pad(box(_c("ink", 0.8), "control", _c("accent"), border), Tokens.space(1) + 4, Tokens.space(1) - 2)
	for type in ["LineEdit", "TextEdit"]:
		theme.set_stylebox("normal", type, field)
		theme.set_stylebox("focus", type, focus)
		theme.set_stylebox("read_only", type, _pad(box(Color(0, 0, 0, 0), "control", _c("line"), border), Tokens.space(1) + 4, Tokens.space(1) - 2))
		theme.set_color("font_color", type, _c("text"))
		theme.set_color("font_placeholder_color", type, _c("dim"))
		theme.set_color("font_selected_color", type, _c("text"))
		theme.set_color("selection_color", type, _c("accent", 0.45))
		theme.set_color("caret_color", type, _c("text"))
		theme.set_font_size("font_size", type, Tokens.font_size("body_small"))
	for state in ["up", "down"]:
		theme.set_stylebox(state + "_normal", "SpinBox", StyleBoxEmpty.new())
		theme.set_stylebox(state + "_hover", "SpinBox", box(_c("text", _a("hover")), "control"))
		theme.set_stylebox(state + "_pressed", "SpinBox", box(_c("text", _a("pressed")), "control"))
	theme.set_color("up_icon_modulate", "SpinBox", _c("muted"))
	theme.set_color("down_icon_modulate", "SpinBox", _c("muted"))
	for type in ["HSlider", "VSlider"]:
		var track := box(_c("text", 0.14), "pill")
		track.content_margin_top = 2
		track.content_margin_bottom = 2
		theme.set_stylebox("slider", type, track)
		theme.set_stylebox("grabber_area", type, box(_c("accent"), "pill"))
		theme.set_stylebox("grabber_area_highlight", type, box(_c("accent_hover"), "pill"))
		theme.set_icon("grabber", type, _knob_icon(16, _c("text")))
		theme.set_icon("grabber_highlight", type, _knob_icon(16, _c("on_accent")))
		theme.set_constant("center_grabber", type, 1)


static func _toggles(theme: Theme) -> void:
	var width := Tokens.control("toggle_width")
	var height := Tokens.control("toggle_height")
	var on := _switch_icon(width, height, _c("accent"), _c("on_accent"), true)
	var off := _switch_icon(width, height, _c("text", 0.18), _c("muted"), false)
	var box_on := _check_icon(18, true)
	var box_off := _check_icon(18, false)
	for type in ["CheckButton", "CheckBox"]:
		for state in ["normal", "hover", "pressed", "hover_pressed", "focus", "disabled"]:
			theme.set_stylebox(state, type, _pad(StyleBoxEmpty.new(), 0, Tokens.space(1) - 2))
		for state in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color"]:
			theme.set_color(state, type, _c("text"))
		theme.set_color("font_disabled_color", type, _c("dim"))
		theme.set_constant("h_separation", type, Tokens.space(1) + 4)
		theme.set_font_size("font_size", type, Tokens.font_size("body_small"))
	for pair in [["checked", on], ["unchecked", off], ["checked_disabled", on], ["unchecked_disabled", off]]:
		theme.set_icon(pair[0], "CheckButton", pair[1])
	for pair in [["checked", box_on], ["unchecked", box_off], ["checked_disabled", box_on], ["unchecked_disabled", box_off]]:
		theme.set_icon(pair[0], "CheckBox", pair[1])


static func _popups(theme: Theme) -> void:
	var surface := panel_box(1, _p)
	surface.bg_color = _c("panel")
	for type in ["PopupMenu", "PopupPanel"]:
		theme.set_stylebox("panel", type, surface)
	theme.set_stylebox("hover", "PopupMenu", box(_c("text", _a("pressed")), "control"))
	theme.set_stylebox("separator", "PopupMenu", _pad(box(_c("line"), "control"), 0, 1))
	theme.set_color("font_color", "PopupMenu", _c("text"))
	theme.set_color("font_hover_color", "PopupMenu", _c("text"))
	theme.set_color("font_disabled_color", "PopupMenu", _c("dim"))
	theme.set_color("font_accelerator_color", "PopupMenu", _c("muted"))
	theme.set_constant("v_separation", "PopupMenu", Tokens.space(1))
	theme.set_constant("h_separation", "PopupMenu", Tokens.space(1))
	theme.set_font_size("font_size", "PopupMenu", Tokens.font_size("body_small"))
	var tip := _pad(box(_c("raised"), "control", _c("line"), 1), Tokens.space(1) + 4, Tokens.space(1))
	theme.set_stylebox("panel", "TooltipPanel", tip)
	theme.set_color("font_color", "TooltipLabel", _c("text"))
	theme.set_font_size("font_size", "TooltipLabel", Tokens.font_size("note"))
	var dialog := panel_box(3, _p)
	dialog.bg_color = _c("panel")
	for type in ["AcceptDialog", "ConfirmationDialog", "Window"]:
		theme.set_stylebox("panel", type, dialog)
		theme.set_stylebox("embedded_border", type, dialog)
		theme.set_stylebox("embedded_unfocused_border", type, dialog)
	theme.set_color("title_color", "Window", _c("text"))
	theme.set_font("title_font", "Window", Tokens.title_font())
	theme.set_font_size("title_font_size", "Window", Tokens.font_size("body"))


static func _scrolling(theme: Theme) -> void:
	for type in ["VScrollBar", "HScrollBar"]:
		var track := StyleBoxEmpty.new()
		track.content_margin_left = 2
		track.content_margin_right = 2
		theme.set_stylebox("scroll", type, track)
		theme.set_stylebox("scroll_focus", type, track)
		theme.set_stylebox("grabber", type, box(_c("text", 0.16), "pill"))
		theme.set_stylebox("grabber_highlight", type, box(_c("text", 0.28), "pill"))
		theme.set_stylebox("grabber_pressed", type, box(_c("text", 0.36), "pill"))
	for type in ["ItemList", "Tree"]:
		theme.set_stylebox("panel", type, box(_c("ink", 0.5), "control", _c("line"), 1))
		theme.set_color("font_color", type, _c("text"))
	theme.set_stylebox("selected", "ItemList", box(_c("accent", 0.35), "control"))
	theme.set_stylebox("selected_focus", "ItemList", box(_c("accent", 0.45), "control"))
	theme.set_color("font_selected_color", "ItemList", _c("text"))


static func _misc(theme: Theme) -> void:
	var rule := StyleBoxLine.new()
	rule.color = _c("line")
	rule.thickness = 1
	theme.set_stylebox("separator", "HSeparator", rule)
	theme.set_constant("separation", "HSeparator", Tokens.space(2))
	var vrule := StyleBoxLine.new()
	vrule.color = _c("line")
	vrule.vertical = true
	theme.set_stylebox("separator", "VSeparator", vrule)
	theme.set_stylebox("background", "ProgressBar", box(_c("text", 0.12), "pill"))
	theme.set_stylebox("fill", "ProgressBar", box(_c("green"), "pill"))
	theme.set_color("font_color", "ProgressBar", _c("text"))
	theme.set_font_size("font_size", "ProgressBar", Tokens.font_size("caption"))
	var tab_on := _pad(box(_c("accent"), "pill"), Tokens.space(2), Tokens.space(1) - 2)
	var tab_off := _pad(box(Color(0, 0, 0, 0), "pill", _c("text", 0.22), 1), Tokens.space(2), Tokens.space(1) - 2)
	theme.set_stylebox("tab_selected", "TabBar", tab_on)
	theme.set_stylebox("tab_unselected", "TabBar", tab_off)
	theme.set_stylebox("tab_hovered", "TabBar", tab_off)
	theme.set_color("font_selected_color", "TabBar", _c("on_accent"))
	theme.set_color("font_unselected_color", "TabBar", _c("muted"))
	theme.set_color("font_hovered_color", "TabBar", _c("text"))
	theme.set_constant("h_separation", "TabBar", Tokens.space(1))
	theme.set_stylebox("panel", "TabContainer", StyleBoxEmpty.new())
	theme.set_stylebox("normal", "RichTextLabel", StyleBoxEmpty.new())
	theme.set_color("default_color", "RichTextLabel", _c("text"))
	theme.set_font_size("normal_font_size", "RichTextLabel", Tokens.font_size("body_small"))


# --- 程序绘制的图标 ----------------------------------------------------------
# 每像素按到形状边缘的距离算覆盖率，得到抗锯齿边缘；只在构建主题时跑一次。

static func _coverage(distance: float) -> float:
	return clampf(0.5 - distance, 0.0, 1.0)


static func _blend(image: Image, x: int, y: int, color: Color, amount: float) -> void:
	if amount <= 0.0:
		return
	var base := image.get_pixel(x, y)
	var top := Color(color, color.a * amount)
	var a := top.a + base.a * (1.0 - top.a)
	if a <= 0.0:
		return
	var rgb := (Color(top.r, top.g, top.b) * top.a + Color(base.r, base.g, base.b) * base.a * (1.0 - top.a)) / a
	image.set_pixel(x, y, Color(rgb.r, rgb.g, rgb.b, a))


static func _switch_icon(width: int, height: int, track: Color, knob: Color, knob_right: bool) -> ImageTexture:
	var image := Image.create_empty(width, height, false, Image.FORMAT_RGBA8)
	var r := height * 0.5
	var knob_r := r - 3.0
	var knob_x := width - r if knob_right else r
	for y in range(height):
		for x in range(width):
			var p := Vector2(x + 0.5, y + 0.5)
			var cx := clampf(p.x, r, width - r)
			_blend(image, x, y, track, _coverage(p.distance_to(Vector2(cx, r)) - r))
			_blend(image, x, y, knob, _coverage(p.distance_to(Vector2(knob_x, r)) - knob_r))
	return ImageTexture.create_from_image(image)


static func _knob_icon(diameter: int, fill: Color) -> ImageTexture:
	var image := Image.create_empty(diameter, diameter, false, Image.FORMAT_RGBA8)
	var r := diameter * 0.5
	for y in range(diameter):
		for x in range(diameter):
			_blend(image, x, y, fill, _coverage(Vector2(x + 0.5, y + 0.5).distance_to(Vector2(r, r)) - (r - 1.0)))
	return ImageTexture.create_from_image(image)


static func _check_icon(size: int, checked: bool) -> ImageTexture:
	var image := Image.create_empty(size, size, false, Image.FORMAT_RGBA8)
	var fill := _c("accent") if checked else Color(0, 0, 0, 0)
	var edge := _c("accent") if checked else _c("text", 0.35)
	var half := size * 0.5 - 1.0
	var corner := 4.0
	var mark := _c("on_accent")
	for y in range(size):
		for x in range(size):
			var p := Vector2(x + 0.5, y + 0.5) - Vector2(size, size) * 0.5
			var q := Vector2(absf(p.x), absf(p.y)) - Vector2(half - corner, half - corner)
			var outside := Vector2(maxf(q.x, 0.0), maxf(q.y, 0.0)).length() + minf(maxf(q.x, q.y), 0.0) - corner
			_blend(image, x, y, fill, _coverage(outside))
			_blend(image, x, y, edge, _coverage(absf(outside + 0.75) - 0.75))
			if checked:
				var a := Vector2(-4.0, 0.5)
				var b := Vector2(-1.0, 3.5)
				var c := Vector2(4.5, -3.0)
				var d := minf(_segment_distance(p, a, b), _segment_distance(p, b, c))
				_blend(image, x, y, mark, _coverage(d - 1.1))
	return ImageTexture.create_from_image(image)


static func _segment_distance(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var t := clampf((p - a).dot(ab) / ab.length_squared(), 0.0, 1.0)
	return p.distance_to(a + ab * t)
