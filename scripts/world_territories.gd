extends RefCounted


static func build(data: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for block in data.get("territory_blocks", []):
		var polygon := PackedVector2Array()
		for point in block["polygon"]:
			polygon.append(Vector2(float(point[0]), float(point[1])))
		result[str(block["city_id"])] = [polygon]
	return result
