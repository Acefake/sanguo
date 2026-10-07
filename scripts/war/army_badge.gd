extends Control

signal selected
const CitySkin = preload("res://scripts/city_ui_skin.gd")
const UNIT_ICONS := {
	"infantry": preload("res://assets/war/badges/infantry.png"),
	"archers": preload("res://assets/war/badges/archers.png"),
	"cavalry": preload("res://assets/war/badges/cavalry.png")
}
const MORALE_TRACK = preload("res://assets/war/badges/morale-track.png")
const MORALE_FILL = preload("res://assets/war/badges/morale-yellow.png")
const MORALE_LOW = preload("res://assets/war/badges/morale-red.png")
const SPEECH_ALLY = preload("res://assets/war/badges/speech-ally.png")
const SPEECH_ENEMY = preload("res://assets/war/badges/speech-enemy.png")
var portrait: Texture2D
var title := ""
var strength := 0
var morale := 100.0
var faction_color := Color("8ac56b")
var highlighted := false
var estimated := false
var commander := ""
var commander_state := ""
var squad_number := 1
var hostile := false
var troop_kind := "infantry"
var speech := ""
var speech_until := 0.0
var speech_visible := true

static func camera_scale(camera_distance: float) -> float:
	return clampf(64.0 / maxf(camera_distance, 1.0), 0.20, 0.88)

func set_speech(line: String, until: float) -> void:
	speech = line
	speech_until = until
	queue_redraw()

func _ready() -> void:
	custom_minimum_size = Vector2(118, 68)
	size = custom_minimum_size
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	tooltip_text = title + "队  点击查看详情和军令"

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		accept_event()
		selected.emit()

func _draw() -> void:
	var font := CitySkin.font()
	var ink := Color("fff6d8")
	var outline := Color("171b16")
	if portrait != null:
		# Preserve the original transparent shoulders and silhouette.
		var ratio := minf(56.0 / portrait.get_width(), 60.0 / portrait.get_height())
		var extent := portrait.get_size() * ratio
		draw_texture_rect(portrait, Rect2(Vector2(17 + (56 - extent.x) / 2, 60 - extent.y), extent), false)
	else:
		draw_style_box(_fallback_flag(), Rect2(23, 15, 34, 43))
		draw_string_outline(font, Vector2(29, 44), title.left(1), HORIZONTAL_ALIGNMENT_LEFT, -1, 22, 3, outline)
		draw_string(font, Vector2(29, 44), title.left(1), HORIZONTAL_ALIGNMENT_LEFT, -1, 22, ink)
	var pennant := PackedVector2Array([Vector2(3,30),Vector2(18,26),Vector2(23,31),Vector2(23,49),Vector2(14,55),Vector2(3,49)])
	draw_colored_polygon(pennant, outline)
	var serial := str(squad_number)
	draw_string(font, Vector2(7,46), serial, HORIZONTAL_ALIGNMENT_LEFT, -1, 17, Color("ffe69c") if highlighted else ink)
	# Native spear, crossed-arrow and horse icons replace the placeholder chevron.
	draw_texture_rect(UNIT_ICONS.get(troop_kind, UNIT_ICONS["infantry"]), Rect2(0,49,21,21), false, Color("fa9d8e") if hostile else Color("9adaee"))
	var number := ("≈" if estimated else "") + str(strength)
	draw_string_outline(font, Vector2(52,59), number, HORIZONTAL_ALIGNMENT_LEFT, -1, 20, 3, outline)
	draw_string(font, Vector2(52,59), number, HORIZONTAL_ALIGNMENT_LEFT, -1, 20, Color("ff9a89") if hostile else Color("a4e7fc"))
	if not estimated:
		draw_texture_rect(MORALE_TRACK, Rect2(16,61,99,8), false)
		for segment in range(5):
			var fill := clampf(morale / 20.0 - segment, 0, 1)
			if fill > 0:
				var texture: Texture2D = MORALE_LOW if morale < 30 else MORALE_FILL
				draw_texture_rect_region(texture, Rect2(18 + segment*19,63,17*fill,4), Rect2(0,0,texture.get_width()*fill,texture.get_height()))
	if highlighted: draw_line(Vector2(16,68),Vector2(114,68),Color("ffe69c"),2)
	if speech_visible and not speech.is_empty():
		# Keep dialogue legible while the portrait itself continues shrinking.
		draw_set_transform(Vector2.ZERO,0,Vector2.ONE * maxf(1.0,0.72/scale.x))
		draw_texture_rect(SPEECH_ENEMY if hostile else SPEECH_ALLY, Rect2(-22,-56,180,54), false)
		draw_string(font, Vector2(-10,-37), commander.left(6) if not commander.is_empty() else title.left(6), HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color("ffe2a3"))
		draw_string(font, Vector2(-10,-18), speech, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color("fff8e2"))
		draw_set_transform(Vector2.ZERO,0,Vector2.ONE)

func _fallback_flag() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = faction_color.darkened(0.3)
	return style
