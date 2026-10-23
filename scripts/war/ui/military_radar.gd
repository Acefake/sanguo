extends Control
## 主帅五项军事能力雷达（满刻度 120）。按主题令牌绘制：网格用分隔线色，能力区用强调色半透明，标签用次要文字色。

const NAMES := ["带兵", "布阵", "治军", "奇袭", "智计"]
const Tokens = preload("res://scripts/ui/theme/ui_tokens.gd")
const RINGS := 4
var values: Array = []


func _draw() -> void:
	if values.size() != 5: return
	var center := size * 0.5
	var radius := minf(size.x * 0.28, size.y * 0.34)
	var grid := Tokens.color("muted", 0.28)
	for ring in range(1, RINGS + 1):
		var outline := _ring(center, radius * ring / RINGS)
		outline.append(outline[0])
		draw_polyline(outline, grid, 1.0, true)
	for corner in _ring(center, radius): draw_line(center, corner, grid, 1.0, true)
	var points := PackedVector2Array()
	for i in range(5): points.append(center + _axis(i) * radius * clampf(float(values[i]) / 120, 0, 1))
	draw_colored_polygon(points, Tokens.color("accent", 0.45))
	points.append(points[0])
	draw_polyline(points, Tokens.color("accent_hover"), 2.0, true)
	var font := Tokens.body_font()
	var font_size := Tokens.font_size("note")
	for i in range(5):
		var text := "%s %d" % [NAMES[i], int(values[i])]
		var extent := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
		var point := center + _axis(i) * (radius + 14) + Vector2(-extent.x / 2, extent.y / 4)
		point.x = clampf(point.x, 0, size.x - extent.x)
		draw_string(font, point, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Tokens.color("muted"))


func _axis(i: int) -> Vector2:
	return Vector2.from_angle(-PI / 2 + TAU * i / 5)


func _ring(center: Vector2, radius: float) -> PackedVector2Array:
	var points := PackedVector2Array()
	for i in range(5): points.append(center + _axis(i) * radius)
	return points
