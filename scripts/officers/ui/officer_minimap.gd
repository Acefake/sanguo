extends Control

var map: Dictionary
var positions: Dictionary = {}
var terrain: Texture2D

func _ready() -> void:
	map = JSON.parse_string(FileAccess.get_file_as_string("res://data/world_map.json"))
	terrain = load(str(map["background"]))
	for place in map["places"]:
		positions[place["id"]] = Vector2(place["x"], place["y"])
	tooltip_text = "天下舆图：使用项目现有城池与路线布局。"

func _draw() -> void:
	if terrain == null:
		return
	draw_texture_rect(terrain, Rect2(Vector2.ZERO, size), false, Color("c9bea3"))
	var factor := size / Vector2(map["image_size"][0], map["image_size"][1])
	for route in map["display_routes"]:
		var points := PackedVector2Array()
		for point in route["points"]:
			points.append(Vector2(point[0], point[1]) * factor)
		if points.size() >= 2:
			draw_polyline(points, Color("e5ddc0"), 0.8, true)
	for id in positions:
		var point: Vector2 = positions[id] * factor
		draw_rect(Rect2(point - Vector2(2.4, 2.4), Vector2(4.8, 4.8)), Color("38342b"))
		draw_rect(Rect2(point - Vector2(1.5, 1.5), Vector2(3, 3)), Color("ead18c"))
