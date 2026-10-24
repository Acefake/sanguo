extends RefCounted

const Grid = preload("res://scripts/rtk14_hex_grid.gd")

static func cell_at(point: Vector3) -> int:
	return Grid.shared().pick(Vector2(point.x, point.z))

static func inset_radius(cell: int) -> float:
	var grid = Grid.shared()
	var center: Vector2 = grid.center(cell)
	var polygon: PackedVector2Array = grid.polygon(cell)
	var radius := INF
	for i in range(polygon.size()):
		radius = minf(radius, center.distance_to(Geometry2D.get_closest_point_to_segment(center, polygon[i], polygon[(i+1)%polygon.size()])))
	return radius

static func landing(target: Vector3, index: int, count: int, cell: int = -1) -> Vector3:
	# Equal-area disk, centered on the attacked hex, never an ever-growing row.
	if cell < 0: cell = cell_at(target)
	var center := Vector2(target.x,target.z)
	var radius := 2.2
	if cell >= 0:
		center = Grid.shared().center(cell)
		radius = inset_radius(cell)*0.66
	var angle := float(index)*2.39996323
	var offset := Vector2(cos(angle),sin(angle))*sqrt((float(index)+0.5)/maxi(count,1))*radius
	return Vector3(center.x+offset.x,target.y,center.y+offset.y)

static func fit_scale(cell: int, anchor: Vector2, offsets: PackedVector2Array, margin: float = 0.18) -> float:
	var grid = Grid.shared()
	var center: Vector2 = grid.center(cell)
	var polygon: PackedVector2Array = grid.polygon(cell)
	var result := 1.0
	for i in range(polygon.size()):
		var edge := polygon[(i+1)%polygon.size()]-polygon[i]
		var outward := Vector2(edge.y,-edge.x).normalized()
		if outward.dot(polygon[i]-center) < 0: outward = -outward
		var available := outward.dot(polygon[i]-anchor)-margin
		for offset in offsets:
			var projection := outward.dot(offset)
			if projection > 0.001: result = minf(result,available/projection)
	return clampf(result,0.0,1.0)
