extends SceneTree

func _initialize() -> void:
	call_deferred("validate")

func validate() -> void:
	var sandbox: Node = load("res://scripts/core/game_state.gd").new()
	sandbox.persist_enabled = false
	sandbox._load_demo()
	var interior: CanvasLayer = load("res://scenes/city_interior.tscn").instantiate()
	interior.store = sandbox
	root.add_child(interior)
	interior.open_city("luoyang", "洛阳", "司隶")
	assert(interior.root_ui.get_node("CityBackground").texture.resource_path == interior.LUOYANG_ART)
	assert(interior.building_holders[0].position == interior.LUOYANG_LOCATIONS.government - Vector2(40, 29))
	interior._select_building("market")
	assert(interior.action_list.get_child_count() == 5)
	interior.open_city("xuchang", "许昌", "豫州")
	assert(interior.root_ui.get_node("CityBackground").texture.resource_path == interior.LUOYANG_ART)
	assert(interior.building_holders[0].position == interior.LUOYANG_LOCATIONS.government - Vector2(40, 29))
	interior.queue_free()
	sandbox.free()
	await process_frame
	print("洛阳检查通过：中原背景、操作位置、市场菜单、切换同区域城市。")
	quit()
