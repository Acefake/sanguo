extends Control

var badge := ""
var badge_color := Color("546a44")

func _draw() -> void:
	var outline := PackedVector2Array([Vector2(1, 1), Vector2(298, 1), Vector2(333, 45), Vector2(298, 89), Vector2(1, 89)])
	var uv := PackedVector2Array()
	for point in outline: uv.append(point / Vector2(334, 90))
	draw_colored_polygon(outline, Color("f7f1e3"), uv, preload("res://assets/war/inspector/paper.png"))
	var edge := outline.duplicate()
	edge.append(outline[0])
	draw_polyline(edge, Color("8c795a"), 1.0, true)
	draw_line(Vector2(8, 85), Vector2(296, 85), Color("c8b797"), 1.0)
	var flag := PackedVector2Array([Vector2(10, 8), Vector2(26, 8), Vector2(26, 29), Vector2(18, 35), Vector2(10, 29)])
	draw_colored_polygon(flag, badge_color)
	draw_string(preload("res://scripts/ui/city_ui_skin.gd").font(), Vector2(12, 24), badge, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color("f3e8c8"))
	var diamond := PackedVector2Array([Vector2(263, 31), Vector2(279, 47), Vector2(263, 63), Vector2(247, 47), Vector2(263, 31)])
	draw_colored_polygon(PackedVector2Array([Vector2(263, 32), Vector2(278, 47), Vector2(263, 62), Vector2(248, 47)]), Color("e1d1a8"))
	draw_colored_polygon(PackedVector2Array([Vector2(263, 32), Vector2(278, 47), Vector2(263, 47)]), Color("b19760"))
	draw_polyline(diamond, Color("816a43"), 2.0, true)
	draw_line(Vector2(263, 31), Vector2(263, 63), Color("816a43"), 1.0)
	draw_line(Vector2(247, 47), Vector2(279, 47), Color("816a43"), 1.0)
