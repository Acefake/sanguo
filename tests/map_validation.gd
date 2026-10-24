extends SceneTree


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var campaign := root.get_node("GameState")
	campaign.persist_enabled = false
	campaign.agent.enabled = false
	campaign._load_demo()
	# This suite validates the supplied legacy atlas polygons and route graph.
	# The RTK14 scene has its own coordinate registration checks.
	var map = load("res://scripts/world/map_slice.gd").new()
	root.add_child(map)
	map.map_mode = "faction"
	var ids: Dictionary = map.places
	if ids.size() != 72 or map.routes.size() < 90 or map.regions.size() != 13:
		_fail("全国地图的地点、道路或州区数量不正确")
		return
	for route in map.routes:
		if not ids.has(str(route["from"])) or not ids.has(str(route["to"])):
			_fail("道路端点不存在：" + str(route["id"]))
			return
	var scenario_places: Dictionary = map.scenario.get("places", {})
	var factions: Dictionary = map.scenario.get("factions", {})
	if scenario_places.size() != ids.size():
		_fail("演示剧本未覆盖全部地点")
		return
	for place_id in ids:
		if not scenario_places.has(place_id):
			_fail("缺少地点情报：" + str(place_id))
			return
		var state: Dictionary = scenario_places[place_id]
		if str(state.get("faction", "")) != "" and not factions.has(str(state.get("faction", ""))):
			_fail("势力未定义：" + str(place_id))
			return
		if str(ids[place_id]["type"]) == "city":
			if int(state.get("population", 0)) <= 0 or int(state.get("garrison", 0)) <= 0 or int(state.get("grain", 0)) <= 0:
				_fail("城市人口、驻军或粮草无效：" + str(place_id))
				return
		if not Geometry2D.is_point_in_polygon(map._place_position(str(place_id)), map._points_from_data(map.regions[str(ids[place_id]["region_id"])]["polygon"])):
			_fail("据点落在所属州区之外：" + str(place_id))
			return
		if str(ids[place_id]["type"]) == "city":
			var controller := str(ids[place_id].get("territory_city_id", place_id))
			if not map.territories.has(controller) or map.territories[controller].is_empty() or not map._point_in_pieces(map._place_position(str(place_id)), map.territories[controller]):
				_fail("城市缺少有效领地：" + str(place_id))
				return
			if int(state.get("economy", -1)) < 0 or int(state.get("economy", 101)) > 100:
				_fail("城市经济指数超出范围：" + str(place_id))
				return
	map.selected_id = "xiapi"
	map._update_route()
	map._refresh_ui()
	if map.detail_faction.text.find("吕布") < 0 or map.detail_stats.get_child_count() != 1:
		_fail("未侦察敌城应只显示公开归属与未知情报")
		return
	map.selected_id = "east_pass"
	map._update_route()
	map._refresh_ui()
	if map.detail_stats.get_child_count() != 1:
		_fail("未侦察关隘不应泄漏驻军")
		return
	var reachable: Dictionary = map._find_route("hongnong", "beihai")
	if not bool(reachable["found"]) or float(reachable["cost"]) <= 0:
		_fail("弘农到北海的通路或权重不正确")
		return
	map.blocked_pass_id = "east_pass"
	var blocked: Dictionary = map._find_route("hongnong", "east_pass")
	if bool(blocked["found"]):
		_fail("东侧关隘封锁后仍可进入该关隘")
		return
	var local: Dictionary = map._find_route("chenliu", "xiapi")
	if not bool(local["found"]):
		_fail("陈留到下邳不可达")
		return
	map.blocked_pass_id = ""
	for place_id in ids:
		if not bool(map._find_route("luoyang", str(place_id))["found"]):
			_fail("全国交通图存在孤立据点：" + str(place_id))
			return
	for block in map.map_data.get("territory_blocks", []):
		var controller := str(block["city_id"])
		var expected: PackedVector2Array = map._points_from_data(block["polygon"])
		if not map.territories.has(controller) or map.territories[controller].size() != 1 or map.territories[controller][0] != expected:
			_fail("领地未使用完整原图分块：" + controller)
			return
	var neutral: Color = map._territory_color("tianshui")
	map._toggle_neutral_style()
	if map._territory_color("tianshui") == neutral:
		_fail("无主区域灰白模式未改变显示")
		return
	var original_owner := str(map.scenario["places"]["tianshui"]["faction"])
	map.scenario["places"]["tianshui"]["faction"] = "cao_cao"
	map._on_city_changed("tianshui")
	if map._faction_id("tianshui") != "cao_cao" or map._territory_color("tianshui").r != Color(str(factions["cao_cao"]["color"])).r:
		_fail("城市归属变化后领地未同步更新颜色")
		return
	map.scenario["places"]["tianshui"]["faction"] = original_owner
	map._on_city_changed("tianshui")
	map._toggle_map_mode()
	for label in map.faction_labels:
		if label.visible:
			_fail("地形模式仍显示势力标签")
			return
	var unchanged_label_id: int = map.faction_labels[0].get_instance_id()
	await campaign.advance_month()
	if map.faction_labels[0].get_instance_id() != unchanged_label_id:
		_fail("月度资源结算不应反复重建势力名称")
		return
	map.queue_free()
	await process_frame
	print("全国地图检查通过：13州、70城、2关、全部道路连通，领地与城市位置、无主模式和关隘封锁正确。")
	quit(0)


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
