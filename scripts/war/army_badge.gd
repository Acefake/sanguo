extends Control

signal selected
const CitySkin = preload("res://scripts/city_ui_skin.gd")
var portrait: Texture2D
var title := ""
var strength := 0
var morale := 100.0
var faction_color := Color("8ac56b")
var highlighted := false
var estimated := false

func _ready() -> void:
	custom_minimum_size = Vector2(84, 80)
	size = custom_minimum_size
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	tooltip_text = title + "队 · 点击查看详情和军令"

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		accept_event()
		selected.emit()

func _draw() -> void:
	var center := Vector2(42, 20)
	draw_circle(center, 18, Color("172019"))
	draw_arc(center, 18, 0, TAU, 64, Color("ffe79c") if highlighted else faction_color, 2.5, true)
	if portrait != null:
		# Draw textured triangles within a circular silhouette.
		var points := PackedVector2Array([center])
		var uv := PackedVector2Array([Vector2(0.5, 0.5)])
		for i in range(65):
			var direction := Vector2.from_angle(float(i) / 64 * TAU)
			points.append(center + direction * 16)
			uv.append(Vector2(0.5, 0.5) + direction * 0.5)
		for i in range(1, 65):
			draw_polygon(PackedVector2Array([points[0], points[i], points[i + 1]]), PackedColorArray([Color.WHITE]), PackedVector2Array([uv[0], uv[i], uv[i + 1]]), portrait)
	else:
		draw_string(CitySkin.font(), Vector2(32, 28), title.left(1), HORIZONTAL_ALIGNMENT_LEFT, -1, 21, Color("f3e7bb"))
	# Compact unit emblem, beside the commander rather than above the soldiers.
	var emblem := PackedVector2Array()
	for i in range(6): emblem.append(Vector2(68, 31) + Vector2.from_angle(float(i) / 6 * TAU) * 7)
	draw_colored_polygon(emblem, Color("283728"))
	emblem.append(emblem[0])
	draw_polyline(emblem, Color("e1cb86"), 2, true)
	var number := ("≈" if estimated else "") + str(strength)
	var width := CitySkin.font().get_string_size(number, HORIZONTAL_ALIGNMENT_LEFT, -1, 20).x
	draw_string_outline(CitySkin.font(), Vector2((84 - width) / 2, 62), number, HORIZONTAL_ALIGNMENT_LEFT, -1, 20, 3, Color("171b16"))
	draw_string(CitySkin.font(), Vector2((84 - width) / 2, 62), number, HORIZONTAL_ALIGNMENT_LEFT, -1, 20, Color("fff6d8"))
	if not estimated:
		draw_rect(Rect2(10, 69, 64, 4), Color("252b20"))
		draw_rect(Rect2(10, 69, 64 * clampf(morale / 100, 0, 1), 4), Color("d8cc99"))
