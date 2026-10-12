extends Control

var values: Array = []
const NAMES := ["军事", "谋略", "勇武", "政治", "魅力"]
const BASE := preload("res://assets/officers/radar-base.png")
const GRID := preload("res://assets/officers/radar-grid.png")
const OVERFLOW_BLUE := Color("367caf")
# 两张素材都带透明边距，整图直接铺进按 radius 计算的矩形会让可见五边形缩小约 3%，
# 于是 100 的顶点越过边框、93 这类高值看起来接近占满。以下记录各素材五边形外接圆的
# 原始尺寸、中心与半径，绘制时按它对齐到 radius，使满值 100 正好落在可见边框上。
const BASE_SIZE := Vector2(232, 223)
const BASE_CENTER := Vector2(115.5, 121.6)
const BASE_RADIUS := 117.8
const GRID_SIZE := Vector2(232, 224)
const GRID_CENTER := Vector2(115.5, 122.6)
const GRID_RADIUS := 119.9

func _draw() -> void:
	if values.size() != 5:
		return
	var center := Vector2(115, 82)
	var radius := 46.0
	draw_texture_rect(BASE, _aligned_rect(center, radius, BASE_SIZE, BASE_CENTER, BASE_RADIUS), false)
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
	draw_texture_rect(GRID, _aligned_rect(center, radius, GRID_SIZE, GRID_CENTER, GRID_RADIUS), false)
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


# Places an asset so its pentagon's circumcenter lands on target_center and its
# circumradius equals target_radius, independent of the asset's transparent margin.
static func _aligned_rect(target_center: Vector2, target_radius: float, image_size: Vector2, source_center: Vector2, source_radius: float) -> Rect2:
	var scale := target_radius / source_radius
	return Rect2(target_center - source_center * scale, image_size * scale)
