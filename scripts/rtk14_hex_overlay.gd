extends Node2D

var map: Node2D
var grid: RefCounted
var show_lines := true
var show_ownership := false
var visible_count := 0


func _draw() -> void:
	visible_count = 0
	if map.camera == null or grid.words.is_empty():
		return
	# The extracted texture already shows the fine grid in the distant overview.
	if map.camera.zoom.x < 0.9 or (not show_lines and not show_ownership):
		return
	var half_view: Vector2 = map.get_viewport_rect().size / map.camera.zoom.x * 0.5
	var bounds := Rect2(map.camera.position - half_view, half_view * 2).grow(12)
	var parameters: Array = grid.transform
	var c0 := maxi(0, int(floor((bounds.position.x - parameters[2]) / parameters[0])) - 1)
	var c1 := mini(219, int(ceil((bounds.end.x - parameters[2]) / parameters[0])) + 1)
	var r0 := maxi(0, int(floor((bounds.position.y - parameters[3]) / parameters[1])) - 1)
	var r1 := mini(219, int(ceil((bounds.end.y - parameters[3]) / parameters[1])) + 1)
	var lines := PackedVector2Array()
	for row in range(r0, r1 + 1):
		for column in range(c0, c1 + 1):
			var cell: int = grid.index_at(column, row)
			if grid.region(cell) == 0:
				continue
			visible_count += 1
			var polygon: PackedVector2Array = grid.polygon(cell)
			if show_ownership:
				var owner: String = grid.controller(cell)
				if not owner.is_empty() and not map._faction_id(owner).is_empty():
					var color: Color = map._faction_color(owner)
					color.a = 0.22
					draw_colored_polygon(polygon, color)
			if show_lines:
				for edge in range(6):
					lines.append(polygon[edge])
					lines.append(polygon[(edge + 1) % 6])
	if not lines.is_empty():
		draw_multiline(lines, Color(0.08, 0.06, 0.03, 0.42), 0.8 / map.camera.zoom.x, true)
