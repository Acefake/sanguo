extends RefCounted

const PATH := "res://data/city_scenes.json"
static var catalog: Dictionary = {}

static func data() -> Dictionary:
	if catalog.is_empty():
		catalog = JSON.parse_string(FileAccess.get_file_as_string(PATH))
	return catalog

static func profile_for(city_id: String) -> String:
	assert(data().cities.has(city_id), "Missing explicit city scene: " + city_id)
	return str(data().cities[city_id].profile)

static func art_for(city_id: String) -> String:
	return str(data().profiles[profile_for(city_id)].art)

static func location_for(city_id: String, building_id: String) -> Vector2:
	var point: Array = data().profiles[profile_for(city_id)].locations[building_id]
	return Vector2(point[0], point[1])
