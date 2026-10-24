extends SceneTree


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var campaign = root.get_node("GameState")
	campaign.persist_enabled = false
	var scene: PackedScene = load("res://scenes/map_slice.tscn")
	var map = scene.instantiate()
	root.add_child(map)
	if map.map_mode != "faction":
		_fail("大地图未默认显示势力版图")
		return
	if not map.map_data.has("territory_blocks"):
		_fail("地图缺少用户分块数据 territory_blocks")
		return
	var blocks: Array = map.map_data["territory_blocks"]
	if blocks.size() != 51 or map.territories.size() != 51:
		_fail("原图的51块领地未全部装配，或仍在按城市生成额外领地")
		return
	if map.places.size() != 72 or map.regions.size() != 13:
		_fail("分块重构未保留70城、2关与13州")
		return
	var block_ids: Dictionary = {}
	var controllers: Dictionary = {}
	var city_blocks: Dictionary = {}
	var atlas_rects: Dictionary = {}
	for block in blocks:
		if not _validate_block(map, block, block_ids, controllers, city_blocks, atlas_rects):
			return
	var city_count := 0
	var pass_count := 0
	for place_id in map.places:
		var place: Dictionary = map.places[place_id]
		if str(place["type"]) == "pass":
			pass_count += 1
			if city_blocks.has(place_id):
				_fail("关隘误占城市领地：" + str(place_id))
				return
			continue
		city_count += 1
		if not city_blocks.has(place_id):
			_fail("城市没有对应原图分块：" + str(place_id))
			return
		if str(place.get("territory_id", "")) != str(city_blocks[place_id]):
			_fail("城市与分块的双向关联不一致：" + str(place_id))
			return
	if city_count != 70 or pass_count != 2 or city_blocks.size() != 70:
		_fail("分块中的城市覆盖数量不正确")
		return
	for controller_id in map.territories:
		if not controllers.has(controller_id):
			_fail("运行时领地包含未定义的控制城市：" + str(controller_id))
			return
	for route in map.routes:
		if not map.places.has(str(route["from"])) or not map.places.has(str(route["to"])):
			_fail("道路引用无效城市：" + str(route["id"]))
			return
	map.blocked_pass_id = ""
	for place_id in map.places:
		if not bool(map._find_route("luoyang", str(place_id))["found"]):
			_fail("分块装配后道路存在孤立据点：" + str(place_id))
			return
	if not _validate_capture(map, campaign, blocks):
		return
	map.queue_free()
	await process_frame
	print("原图分块检查通过：51块纹理和轮廓、70城2关、双向关联、全图道路连通与控制城归属同步。")
	quit(0)


func _validate_block(map, block: Dictionary, block_ids: Dictionary, controllers: Dictionary, city_blocks: Dictionary, atlas_rects: Dictionary) -> bool:
	var block_id := str(block.get("id", ""))
	var controller_id := str(block.get("city_id", ""))
	if block_id.is_empty() or block_ids.has(block_id):
		_fail("分块编号为空或重复：" + block_id)
		return false
	block_ids[block_id] = true
	if not map.places.has(controller_id) or str(map.places[controller_id]["type"]) != "city" or controllers.has(controller_id):
		_fail("分块控制城缺失、重复或不是城池：" + block_id)
		return false
	controllers[controller_id] = true
	var polygon: PackedVector2Array = map._points_from_data(block.get("polygon", []))
	if polygon.size() < 3 or Geometry2D.triangulate_polygon(polygon).is_empty():
		_fail("原图分块轮廓无法构成有效领地：" + block_id)
		return false
	if not map.territories.has(controller_id) or map.territories[controller_id].size() != 1 or map.territories[controller_id][0] != polygon:
		_fail("运行时领地没有直接使用原图分块轮廓：" + block_id)
		return false
	var rect_data: Array = block.get("rect", [])
	if rect_data.size() != 4 or float(rect_data[2]) <= 0.0 or float(rect_data[3]) <= 0.0:
		_fail("分块绘制矩形无效：" + block_id)
		return false
	var rect := Rect2(float(rect_data[0]), float(rect_data[1]), float(rect_data[2]), float(rect_data[3]))
	var minimum := polygon[0]
	var maximum := polygon[0]
	for point in polygon:
		if not is_finite(point.x) or not is_finite(point.y) or not rect.grow(0.1).has_point(point):
			_fail("分块轮廓超出对应纹理绘制矩形：" + block_id)
			return false
		minimum = minimum.min(point)
		maximum = maximum.max(point)
	if minimum.distance_to(rect.position) > 2.0 or (maximum - minimum - rect.size).length() > 2.0:
		_fail("分块轮廓与纹理位置或缩放错位：" + block_id)
		return false
	var texture_path := str(block.get("texture", ""))
	var texture: Texture2D = load(texture_path) if ResourceLoader.exists(texture_path) else null
	if texture == null or texture.get_width() <= 0 or texture.get_height() <= 0:
		_fail("分块纹理无法载入：" + block_id)
		return false
	var atlas_path := str(block.get("atlas_sheet", ""))
	var atlas: Texture2D = load(atlas_path) if ResourceLoader.exists(atlas_path) else null
	var atlas_data: Array = block.get("atlas_rect", [])
	if atlas == null or atlas_data.size() != 4:
		_fail("分块缺少原始图集与切片矩形：" + block_id)
		return false
	var atlas_rect := Rect2(float(atlas_data[0]), float(atlas_data[1]), float(atlas_data[2]), float(atlas_data[3]))
	if atlas_rect.size.x <= 0.0 or atlas_rect.size.y <= 0.0 or not Rect2(Vector2.ZERO, atlas.get_size()).encloses(atlas_rect):
		_fail("分块原始切片超出图集：" + block_id)
		return false
	var atlas_key := atlas_path + ":" + str(atlas_data)
	if atlas_rects.has(atlas_key):
		_fail("多个领地重复使用同一原始图集切片：" + block_id)
		return false
	atlas_rects[atlas_key] = true
	if block.has("texture_rect"):
		var source_rect: Array = block["texture_rect"]
		if source_rect.size() != 4 or texture.get_size() != rect.size:
			_fail("分块纹理没有按共享边界原尺寸装配：" + block_id)
			return false
	var place_ids: Array = block.get("place_ids", [])
	if not place_ids.has(controller_id):
		_fail("分块城市列表不包含控制城：" + block_id)
		return false
	for place_id_value in place_ids:
		var place_id := str(place_id_value)
		if not map.places.has(place_id) or str(map.places[place_id]["type"]) != "city" or city_blocks.has(place_id):
			_fail("分块城市缺失、重复或不是城池：" + place_id)
			return false
		if not Geometry2D.is_point_in_polygon(map._place_position(place_id), polygon):
			_fail("城池标记没有位于对应原图分块内：" + place_id)
			return false
		city_blocks[place_id] = block_id
	return true


func _validate_capture(map, campaign, blocks: Array) -> bool:
	var controller_id := str(blocks[0]["city_id"])
	var factions: Dictionary = map.scenario.get("factions", {})
	var state: Dictionary = map.scenario.get("places", {}).get(controller_id, {})
	var previous_owner := str(state.get("faction", ""))
	var next_owner := ""
	for faction_id in factions:
		if str(faction_id) != previous_owner:
			next_owner = str(faction_id)
			break
	if state.is_empty() or next_owner.is_empty():
		_fail("控制城归属测试缺少城市情报或可切换势力")
		return false
	var original_geometry: Dictionary = map.territories.duplicate(true)
	var other_controller_id := str(blocks[1]["city_id"])
	var other_color: Color = map._territory_color(other_controller_id)
	map.selected_id = controller_id
	map._update_route()
	state["faction"] = next_owner
	campaign.city_changed.emit(controller_id)
	var expected := Color(str(factions[next_owner]["color"]))
	var actual: Color = map._territory_color(controller_id)
	var ownership_ok: bool = map._faction_id(controller_id) == next_owner
	var color_ok := is_equal_approx(actual.r, expected.r) and is_equal_approx(actual.g, expected.g) and is_equal_approx(actual.b, expected.b) and actual.a > 0.0
	var detail_ok: bool = map.detail_faction.text.contains(str(factions[next_owner]["name"]))
	var stable_geometry: bool = map.territories == original_geometry
	var stable_neighbor: bool = map._territory_color(other_controller_id) == other_color
	state["faction"] = previous_owner
	campaign.city_changed.emit(controller_id)
	if not ownership_ok or not color_ok or not detail_ok or not stable_geometry or not stable_neighbor:
		_fail("控制城归属变化后分块颜色或情报未同步，或错误改变了原图轮廓和邻近领地")
		return false
	return true


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
