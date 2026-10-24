extends Control

signal chosen

var city_name := ""
var faction_letter := ""
var faction_color := Color("c5c0aa")
var troops := 0
var selected := false
var lettering: Font = preload("res://scripts/ui/city_ui_skin.gd").font()

func _ready() -> void:
	size = Vector2(196, 82)
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			chosen.emit()
			accept_event())

func _draw() -> void:
	# Blue balance emblem sits beside the faction shield, as in the map reference.
	for stroke in [{"a": Vector2(-21, 7), "b": Vector2(-21, 35)}, {"a": Vector2(-34, 15), "b": Vector2(-8, 15)}, {"a": Vector2(-34, 15), "b": Vector2(-39, 31)}, {"a": Vector2(-34, 15), "b": Vector2(-29, 31)}, {"a": Vector2(-8, 15), "b": Vector2(-13, 31)}, {"a": Vector2(-8, 15), "b": Vector2(-3, 31)}]:
		draw_line(stroke.a, stroke.b, Color("1d374b"), 5, true)
		draw_line(stroke.a, stroke.b, Color("95d6e9"), 2, true)
	draw_circle(Vector2(-21, 7), 4, Color("1d374b"))
	draw_circle(Vector2(-21, 7), 2, Color("95d6e9"))
	for x in [-34.0, -8.0]:
		draw_colored_polygon(PackedVector2Array([Vector2(x-6,30),Vector2(x+6,30),Vector2(x+4,35),Vector2(x-4,35)]), Color("72c4df"))
	var shield := PackedVector2Array([Vector2(0, 0), Vector2(40, 0), Vector2(40, 42), Vector2(20, 54), Vector2(0, 42)])
	var name_plate := PackedVector2Array([Vector2(41, 4), Vector2(181, 4), Vector2(192, 20), Vector2(181, 36), Vector2(41, 36)])
	draw_colored_polygon(name_plate, Color("e8c453") if selected else Color(0.16, 0.19, 0.12, 0.78))
	draw_colored_polygon(shield, Color("ffe478") if selected else faction_color.lightened(0.20))
	var edge := shield.duplicate()
	edge.append(edge[0])
	draw_polyline(edge, Color("9d742c") if selected else Color("34566b"), 2.0, true)
	var letter_width := lettering.get_string_size(faction_letter, HORIZONTAL_ALIGNMENT_LEFT, -1, 30).x
	draw_string(lettering, Vector2(20 - letter_width * 0.5, 33), faction_letter, HORIZONTAL_ALIGNMENT_LEFT, -1, 30, Color("302d20"))
	draw_string(lettering, Vector2(53, 29), city_name, HORIZONTAL_ALIGNMENT_LEFT, -1, 25, Color("493825") if selected else Color("fff9e7"))
	draw_rect(Rect2(39, 40, 147, 34), Color(0.09, 0.12, 0.08, 0.67))
	# Small gold troop emblem, followed by the live city garrison.
	for x in [24.0, 35.0]:
		draw_circle(Vector2(x, 53), 3.3, Color("ffe398"))
		draw_colored_polygon(PackedVector2Array([Vector2(x-4,58),Vector2(x+4,58),Vector2(x+5,68),Vector2(x-5,68)]), Color("ffe398"))
	draw_line(Vector2(18, 58), Vector2(18, 69), Color("ffe398"), 2)
	var number := "未知" if troops < 0 else str(troops)
	draw_string_outline(lettering, Vector2(47, 67), number, HORIZONTAL_ALIGNMENT_LEFT, -1, 25, 1, Color("28281d"))
	draw_string(lettering, Vector2(47, 67), number, HORIZONTAL_ALIGNMENT_LEFT, -1, 25, Color("fffdf3"))
	draw_rect(Rect2(20, 75, 166, 4), Color("494c36"))
	draw_rect(Rect2(20, 75, 166 * clampf(float(troops) / 30000.0, 0.0, 1.0), 4), Color("e6dea0"))
