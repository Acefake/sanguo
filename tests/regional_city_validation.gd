extends SceneTree

const Catalog = preload("res://scripts/city_scene_catalog.gd")

func _initialize() -> void:
	call_deferred("validate")

func validate() -> void:
	var sandbox: Node = load("res://scripts/game_state.gd").new()
	sandbox.persist_enabled = false
	sandbox._load_demo()
	var interior: CanvasLayer = load("res://scenes/city_interior.tscn").instantiate()
	interior.store = sandbox
	root.add_child(interior)
	var world: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/world_map.json"))
	var reference: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/city_scene_reference.json"))
	var originals := {}
	var appearance: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/city_scene_extensions.json"))
	for original in reference.cities:
		originals[int(original.city_id)] = original
	var visited := {}
	var count := 0
	var original_state := JSON.stringify(sandbox.scenario)
	for city in world.places:
		if city.type != "city":
			continue
		assert(Catalog.data().cities.has(city.id), "Missing scene mapping: " + city.id)
		var profile := Catalog.profile_for(city.id)
		var assignment: Dictionary = Catalog.data().cities[city.id]
		var original: Dictionary = originals[int(assignment.source_city_id)]
		assert(int(assignment.source_scene_id) == int(original.scene_id), "City source differs from reference: " + city.id)
		assert(assignment.source_state == original.state and assignment.source_city == original.name)
		if appearance.overrides.has(city.id):
			assert(assignment.mapping == "visual_override" and profile == appearance.overrides[city.id].profile)
		else:
			assert(int(assignment.scene_id) == int(original.scene_id), "Unexpected city appearance override: " + city.id)
		assert(int(Catalog.data().profiles[profile].scene_id) == int(assignment.scene_id))
		if assignment.mapping == "original_city_table":
			assert(city.name == original.name)
		visited[profile] = true
		interior.open_city(city.id, city.name, city.region_id)
		var background: Texture2D = interior.root_ui.get_node("CityBackground").texture
		assert(background != null and background.resource_path == Catalog.art_for(city.id), "Missing city art: " + city.id)
		assert(background.get_width() >= 2000 and background.get_height() >= 1400)
		var index := 0
		for building_id in interior.BUILDINGS:
			var point := Catalog.location_for(city.id, building_id)
			assert(Rect2(45, 145, 1130, 485).has_point(point), "Hotspot outside usable area: " + city.id + "/" + building_id)
			assert(interior.building_holders[index].position == point - Vector2(40, 29))
			index += 1
		interior._select_building("market")
		assert(interior.selected_building == "market" and interior.action_list.get_child_count() == 5)
		interior._select_building("government")
		assert(interior.in_council and interior.council_view.visible)
		count += 1
	assert(count == 70 and visited.size() == 5)
	assert(Catalog.profile_for("luoyang") == "central")
	assert(Catalog.profile_for("xiangping") == "north")
	assert(Catalog.profile_for("jianye") == "south")
	assert(Catalog.profile_for("chengdu") == "shu")
	assert(Catalog.profile_for("jianning") == "nanman")
	# Boundary cases are deliberately different from the broad world-map regions.
	for id in ["jiuquan", "zhangye", "jincheng", "wuwei", "tianshui"]:
		assert(Catalog.profile_for(id) == "north", "Northwestern city incorrectly assigned: " + id)
	for id in ["hepu", "cangwu", "nanhai", "jiaozhi", "guangling", "jianye"]:
		assert(Catalog.profile_for(id) == "south", "Southern city incorrectly assigned: " + id)
	for id in ["changan", "luoyang", "hongnong", "hedong", "henei", "xiapi", "langye"]:
		assert(Catalog.profile_for(id) == "central", "Central city incorrectly assigned: " + id)
	assert(Catalog.profile_for("chengdu") != Catalog.profile_for("jianning"))
	assert(Catalog.art_for("changan") != Catalog.art_for("wuwei"), "Chang'an must not display the Xiliang border-town panorama")
	assert(Catalog.data().cities.changan.mapping == "visual_override")
	assert(JSON.stringify(sandbox.scenario) == original_state and sandbox.action_points == 3)
	interior.queue_free()
	sandbox.free()
	await process_frame
	print("全国城内检查通过：长安都城外观覆盖、70 城来源及外观配置、5 套高清场景、420 个建筑入口、市场/官府切换，浏览不修改存档状态。")
	quit()
