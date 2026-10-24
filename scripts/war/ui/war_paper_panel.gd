extends PanelContainer

# Keep the original paper texture; the fine double rule belongs to the frame.
func _draw() -> void:
	var outer := Rect2(Vector2.ONE, size - Vector2(2, 2))
	draw_rect(outer, Color("89744e"), false, 1.0)
	draw_rect(outer.grow(-3), Color(0.55, 0.45, 0.28, 0.3), false, 1.0)
	for corner in [Vector2(7, 7), Vector2(size.x - 7, 7), Vector2(7, size.y - 7), size - Vector2(7, 7)]:
		var dx := 1.0 if corner.x < size.x / 2 else -1.0
		var dy := 1.0 if corner.y < size.y / 2 else -1.0
		draw_line(corner, corner + Vector2(9 * dx, 0), Color("ab9060"))
		draw_line(corner, corner + Vector2(0, 9 * dy), Color("ab9060"))

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED: queue_redraw()
