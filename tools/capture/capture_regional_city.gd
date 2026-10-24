extends SceneTree

const Catalog = preload("res://scripts/city/city_scene_catalog.gd")

func _initialize() -> void:
	call_deferred("capture")

func capture() -> void:
	var args := OS.get_cmdline_user_args()
	var city_id := _option(args, "--city")
	var profile := "north"
	if not city_id.is_empty():
		profile = Catalog.profile_for(city_id)
	elif not args.is_empty() and Catalog.data().profiles.has(args[0]):
		profile = args[0]
	var folder := str(Catalog.data().profiles[profile].art).get_base_dir()
	assert(FileAccess.file_exists(folder + "/scene.json"), "Import the city scene before capture")
	var path := folder + "/preview-perspective.png"
	if "--ui-only" not in args:
		root.size = Vector2i(2560, 1440)
		var scene: Node3D = load("res://scripts/city/luoyang_scene.gd").new()
		scene.scene_manifest = folder + "/scene.json"
		root.add_child(scene)
		await create_timer(3.0).timeout
		await RenderingServer.frame_post_draw
		assert(root.get_texture().get_image().save_png(path) == OK)
		scene.queue_free()
		await process_frame
	if "--ui" in args or "--ui-only" in args:
		root.size = Vector2i(1280, 720)
		var sandbox: Node = load("res://scripts/core/game_state.gd").new()
		sandbox.persist_enabled = false
		sandbox._load_demo()
		var interior: CanvasLayer = load("res://scenes/city_interior.tscn").instantiate()
		interior.store = sandbox
		root.add_child(interior)
		var catalog: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/city_scenes.json"))
		var world: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/world_map.json"))
		for id in catalog.cities:
			if (not city_id.is_empty() and id == city_id) or (city_id.is_empty() and catalog.cities[id].profile == profile):
				var region_name := ""
				for place in world.places:
					if place.id == id:
						for region in world.regions:
							if region.id == place.region_id:
								region_name = str(region.name)
				interior.open_city(id, catalog.cities[id].name, region_name)
				break
		var fresh := Image.new()
		assert(fresh.load_png_from_buffer(FileAccess.get_file_as_bytes(path)) == OK)
		interior.root_ui.get_node("CityBackground").texture = ImageTexture.create_from_image(fresh)
		await process_frame
		await process_frame
		await RenderingServer.frame_post_draw
		var output := _option(args, "--output")
		if output.is_empty():
			output = folder + "/city-preview.png" if city_id.is_empty() else "res://assets/city/comparisons/" + city_id + ".png"
		DirAccess.make_dir_recursive_absolute(output.get_base_dir())
		assert(root.get_texture().get_image().save_png(output) == OK)
		interior.queue_free()
		sandbox.free()
		await process_frame
	print("Captured regional city: ", profile, " / ", city_id)
	quit()


func _option(args: PackedStringArray, key: String) -> String:
	var index := args.find(key)
	return args[index + 1] if index >= 0 and index + 1 < args.size() else ""
