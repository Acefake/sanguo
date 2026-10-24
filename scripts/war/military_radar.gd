extends Control

const NAMES := ["带兵", "布阵", "治军", "奇袭", "智计"]
const CitySkin = preload("res://scripts/city_ui_skin.gd")
const BASE = preload("res://assets/war/dispatch/radar-base.png")
const GRID = preload("res://assets/war/dispatch/radar-grid.png")
var values: Array = []

func _draw() -> void:
	if values.size() != 5: return
	var center := size * 0.5
	var radius := minf(size.x * 0.31, size.y * 0.30)
	var rect := Rect2(center - Vector2(radius * 0.951, radius), Vector2(radius * 1.902, radius * 1.809))
	draw_texture_rect(BASE, rect, false)
	var points := PackedVector2Array()
	for i in range(5): points.append(center + Vector2.from_angle(-PI / 2 + TAU * i / 5) * radius * clampf(float(values[i]) / 120, 0, 1))
	draw_colored_polygon(points, Color(0.8, 0.52, 0.12, 0.65))
	points.append(points[0])
	draw_polyline(points, Color("885b40"), 2, true)
	draw_texture_rect(GRID, rect, false)
	for i in range(5):
		var point := center + Vector2.from_angle(-PI / 2 + TAU * i / 5) * (radius + 28)
		var text := "%s %d" % [NAMES[i], int(values[i])]
		var font := CitySkin.font()
		draw_string(font, point - Vector2(font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x / 2, 0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color("604832"))

