extends SceneTree

const CitySkin = preload("res://scripts/ui/city_ui_skin.gd")
const ASSET_PATH := "res://assets/armies/rtk14/"
var failures: Array[String] = []
var views: Dictionary = {}

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	root.get_node("GameState").persist_enabled = false
	root.size = Vector2i(1280, 720)
	var background := ColorRect.new()
	background.color = Color("192322")
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(background)
	var grid := GridContainer.new()
	grid.columns = 4
	grid.position = Vector2(8, 8)
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 10)
	root.add_child(grid)
	var manifest: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(ASSET_PATH + "manifest.json"))
	if "--infantry-poses" in OS.get_cmdline_user_args():
		manifest = {"infantry-poses": {"path": ASSET_PATH + "models/infantry-poses.glb", "label": "步兵 · 项目持械站姿"}}
	for id in manifest:
		var entry: Dictionary = manifest[id]
		var column := VBoxContainer.new()
		column.custom_minimum_size = Vector2(308, 220)
		grid.add_child(column)
		var holder := SubViewportContainer.new()
		holder.custom_minimum_size = Vector2(308, 176)
		holder.stretch = true
		column.add_child(holder)
		var viewport := SubViewport.new()
		viewport.size = Vector2i(308, 176)
		viewport.own_world_3d = true
		viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		holder.add_child(viewport)
		views[id] = viewport
		var scene := Node3D.new()
		viewport.add_child(scene)
		var world := WorldEnvironment.new()
		world.environment = Environment.new()
		world.environment.background_mode = Environment.BG_COLOR
		world.environment.background_color = Color("25322e")
		world.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		world.environment.ambient_light_color = Color("c7d3bf")
		world.environment.ambient_light_energy = 0.7
		scene.add_child(world)
		var light := DirectionalLight3D.new()
		light.rotation_degrees = Vector3(-45, -35, 0)
		light.light_energy = 1.3
		scene.add_child(light)
		var document := GLTFDocument.new()
		var state := GLTFState.new()
		var error: int = document.append_from_file(str(entry["path"]), state)
		if error != OK:
			_fail("模型无法加载：" + str(id))
			continue
		var model: Node3D = document.generate_scene(state)
		if id == "infantry-poses":
			var posed_meshes := model.find_children("*", "MeshInstance3D", true, false)
			for i in range(1, posed_meshes.size()): posed_meshes[i].hide()
		scene.add_child(model)
		var bounds: AABB = _bounds(model)
		var scale_value: float = 2.1 / maxf(bounds.size.x, maxf(bounds.size.y, bounds.size.z))
		model.scale = Vector3.ONE * scale_value
		model.position = -(bounds.position + bounds.size / 2) * scale_value
		var camera := Camera3D.new()
		camera.projection = Camera3D.PROJECTION_ORTHOGONAL
		camera.size = 2.5
		camera.position = Vector3(4, 2.2, 6)
		scene.add_child(camera)
		camera.look_at(Vector3.ZERO)
		camera.make_current()
		var title := CitySkin.label(str(entry["label"]), 17, Color("e8d7ab"))
		title.add_theme_font_override("font", CitySkin.font())
		column.add_child(title)
		var note := CitySkin.label(str(id) + (" · 原骨骼 / 项目制作动作" if id == "infantry-poses" else " · 原模型 / 动画未绑定"), 14, Color("9cafa1"))
		note.add_theme_font_override("font", CitySkin.font())
		column.add_child(note)
	await process_frame
	await process_frame
	await create_timer(0.4).timeout
	await RenderingServer.frame_post_draw
	var destination := "res://docs/validation/army-assets/"
	for id in views:
		_check(views[id].get_texture().get_image().save_png(destination + str(id) + "-textured.png") == OK, "无法保存模型预览")
	var gallery_name := "infantry-poses-gallery.png" if views.has("infantry-poses") else "army-assets-gallery.png"
	_check(root.get_texture().get_image().save_png(destination + gallery_name) == OK, "无法保存模型总览")
	print("ARMY_ASSET_RENDER_OK: ", views.size(), " GLB models, original UVs and mapped native textures; static geometry only")
	quit(0 if failures.is_empty() else 1)

func _bounds(node: Node3D) -> AABB:
	var result := AABB()
	var has_mesh := false
	for child in node.get_children():
		if child is MeshInstance3D:
			var bounds: AABB = child.get_aabb()
			result = result.merge(bounds) if has_mesh else bounds
			has_mesh = true
		elif child is Node3D:
			var bounds: AABB = _bounds(child)
			if bounds.size.length() > 0:
				result = result.merge(bounds) if has_mesh else bounds
				has_mesh = true
	return result

func _check(condition: bool, message: String) -> void:
	if not condition: _fail(message)

func _fail(message: String) -> void:
	failures.append(message)
	push_error(message)
