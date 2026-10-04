extends Control

signal category_requested(category_id: String)
signal closed

const CitySkin = preload("res://scripts/city_ui_skin.gd")
const Lettering = preload("res://scripts/council_label_atlas.gd")
const BACKGROUND_ART := "res://assets/city/han/council.png"
const CATEGORIES := {
	"people": "人事",
	"military": "军事",
	"strategy": "计略",
	"diplomacy": "外交",
	"civil": "方针",
	"intelligence": "谍报"
}

var buttons: Dictionary = {}
var selected_category := "civil"


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var council_theme := Theme.new()
	council_theme.default_font = CitySkin.font()
	CitySkin.apply_theme(council_theme)
	theme = council_theme
	var background := TextureRect.new()
	background.name = "CouncilBackground"
	background.texture = load(BACKGROUND_ART)
	background.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	background.stretch_mode = TextureRect.STRETCH_SCALE
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(background)
	var menu := HBoxContainer.new()
	menu.name = "CouncilCategories"
	menu.anchor_top = 1.0
	menu.anchor_bottom = 1.0
	menu.offset_left = 318.0
	menu.offset_right = 1110.0
	menu.offset_top = -54.0
	menu.offset_bottom = -14.0
	menu.add_theme_constant_override("separation", 5)
	menu.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(menu)
	for category_id in CATEGORIES:
		var button := _make_button(CATEGORIES[category_id], category_id)
		button.pressed.connect(_request_category.bind(category_id))
		button.mouse_entered.connect(_request_category.bind(category_id))
		buttons[category_id] = button
		menu.add_child(button)
	var return_button := _make_button("返回城内", "return")
	return_button.custom_minimum_size.x = 102.0
	return_button.pressed.connect(func() -> void: closed.emit())
	buttons["return"] = return_button
	menu.add_child(return_button)
	select_category(selected_category)


func select_category(category_id: String) -> void:
	if not CATEGORIES.has(category_id):
		return
	selected_category = category_id
	for button_id in buttons:
		var button: Button = buttons[button_id]
		var selected := false
		CitySkin.style_tab_button(button, selected)
		if CATEGORIES.has(button_id):
			Lettering.apply(button, button_id, selected)


func _make_button(caption: String, icon_key: String) -> Button:
	var button := Button.new()
	button.text = caption
	button.icon = CitySkin.tab_icon(icon_key) if icon_key == "return" else null
	button.expand_icon = true
	button.add_theme_constant_override("icon_max_width", 18)
	button.add_theme_constant_override("h_separation", 5)
	button.custom_minimum_size = Vector2(110.0, 40.0)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.add_theme_font_size_override("font_size", 16)
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.tooltip_text = caption
	return button


func _request_category(category_id: String) -> void:
	select_category(category_id)
	category_requested.emit(category_id)
