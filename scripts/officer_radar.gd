extends Control

var values: Array = []
const NAMES := ["军事", "谋略", "勇武", "政治", "魅力"]
const BASE := preload("res://assets/officers/radar-base.png")
const GRID := preload("res://assets/officers/radar-grid.png")
const OVERFLOW_BLUE := Color("367caf")

func _draw() -> void:
	if values.size() != 5:
		return
	var center := Vector2(115, 82)
	var radius := 46.0
	var sprite_rect := Rect2(center - Vector2(radius * 0.951, radius), Vector2(radius * 1.902, radius * 1.809))
	draw_texture_rect(BASE, sprite_rect, false)
	var actual := PackedVector2Array()
	var capped := PackedVector2Array()
	for i in range(5):
		var direction := Vector2.from_angle(-PI / 2.0 + TAU * i / 5.0)
		actual.append(center + direction * radius * clampf(float(values[i]) / 100.0, 0, 1.2))
		capped.append(center + direction * radius * clampf(float(values[i]) / 100.0, 0, 1))
	# The blue layer is visible only where the true value exceeds the
	# gold polygon capped at 100, rather than replacing its border.
	draw_colored_polygon(actual, OVERFLOW_BLUE)
	draw_colored_polygon(capped, Color("dbab64"))
	draw_texture_rect(GRID, sprite_rect, false)
	var font := theme.default_font
	var label_font_size := 14
	# P1：五个标签按顶点角度均匀环绕，解决原来高低错落的问题。
	var positions: Array[Vector2] = []
	for i in range(5):
		var label_direction := Vector2.from_angle(-PI / 2.0 + TAU * i / 5.0)
		positions.append(center + label_direction * (radius + 26.0))
	for i in range(5):
		var point: Vector2 = positions[i]
		var text_width := font.get_string_size(NAMES[i], HORIZONTAL_ALIGNMENT_LEFT, -1, label_font_size).x
		draw_string(font, point - Vector2(text_width * 0.5, 0), NAMES[i], HORIZONTAL_ALIGNMENT_LEFT, -1, label_font_size, OVERFLOW_BLUE if float(values[i]) > 100 else Color("885b40"))
		var number := str(int(values[i]))
		var number_width := font.get_string_size(number, HORIZONTAL_ALIGNMENT_LEFT, -1, label_font_size).x
		draw_string(font, point + Vector2(-number_width * 0.5, 17), number, HORIZONTAL_ALIGNMENT_LEFT, -1, label_font_size, OVERFLOW_BLUE if float(values[i]) > 100 else Color("40372d"))
