extends CanvasLayer

const UISkin = preload("res://scripts/ui/city_ui_skin.gd")
const Layout = preload("res://scripts/ui/ui_layout.gd")
const MountedActor = preload("res://scripts/war/presentation/mounted_duel_actor.gd")
signal finished

var elapsed := 0.0
var fighter_left: Node3D
var fighter_right: Node3D
var stage: SubViewport
var root_panel: Control
var left_name: Label
var right_name: Label
var left_score: Label
var right_score: Label
var left_bar: ProgressBar
var right_bar: ProgressBar
var round_label: Label
var outcome_label: Label
var left_face: TextureRect
var right_face: TextureRect
var hud: Control
var backdrop: TextureRect
var active_record: Dictionary = {}
var round_data: Array = []
var last_round := -1
var last_hit := -1
var demo := false
var camera: Camera3D
var impact: MeshInstance3D
var replay_button: Button
const ROUND_SECONDS := 1.35

func _ready() -> void:
	layer = 20
	_build_ui()
	hide()
	stage.render_target_update_mode = SubViewport.UPDATE_DISABLED

func _style_panel(color: Color, border: Color, width: int = 3) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.border_color = border
	style.set_border_width_all(width)
	style.set_content_margin_all(10)
	style.corner_radius_top_left = 3
	style.corner_radius_top_right = 3
	style.corner_radius_bottom_left = 3
	style.corner_radius_bottom_right = 3
	return style

func _label(text: String, size: int, color: Color = UISkin.INK) -> Label:
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_override("font", UISkin.font())
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_outline_color", Color("1b100d"))
	label.add_theme_constant_override("outline_size", 0)
	return label

func _sprite(asset: String, rect: Rect2) -> TextureRect:
	var image := TextureRect.new()
	image.texture = load("res://assets/officers/" + asset + ".png")
	image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	image.position = rect.position
	image.size = rect.size
	image.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_child(image)
	return image

func _place(control: Control, rect: Rect2) -> void:
	control.position = rect.position
	control.size = rect.size
	hud.add_child(control)

func _resize() -> void:
	Layout.fit_center(hud)

func _build_ui() -> void:
	hud = Control.new()
	hud.size = Layout.DESIGN
	hud.theme = Theme.new()
	hud.theme.default_font = UISkin.font()
	UISkin.apply_theme(hud.theme)
	add_child(hud)
	backdrop = _sprite("scene-background", Rect2(Vector2.ZERO, Layout.DESIGN))
	var blur := ShaderMaterial.new()
	blur.shader = preload("res://shaders/officer_background_blur.gdshader")
	backdrop.material = blur
	_sprite("title-ribbon", Rect2(0, 4, 392, 70))
	var heading := _label("武将单挑", 31)
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_place(heading, Rect2(42, 4, 340, 70))
	heading.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	root_panel = _sprite("panel-paper", Rect2(58, 82, 1178, 527))
	var paper := ShaderMaterial.new()
	paper.shader = preload("res://shaders/officer_window.gdshader")
	paper.set_shader_parameter("fade_wing", load("res://assets/officers/window-wing.png"))
	root_panel.material = paper
	_sprite("rule", Rect2(164, 82, 966, 1))
	_sprite("rule", Rect2(164, 608, 966, 1))
	left_face = _portrait_box()
	_place(left_face, Rect2(180, 103, 80, 101))
	right_face = _portrait_box()
	_place(right_face, Rect2(1010, 103, 80, 101))
	left_name = _label("我方武将", 29)
	_place(left_name, Rect2(275, 103, 260, 37))
	right_name = _label("敌方武将", 29)
	_place(right_name, Rect2(735, 103, 260, 37))
	left_score = _label("勇武  0    武艺  0", 18, Color("715d43"))
	_place(left_score, Rect2(275, 143, 260, 26))
	right_score = _label("勇武  0    武艺  0", 18, Color("715d43"))
	_place(right_score, Rect2(735, 143, 260, 26))
	left_bar = _health_bar(Color("80794b"))
	_place(left_bar, Rect2(275, 180, 260, 16))
	right_bar = _health_bar(Color("a3503d"))
	_place(right_bar, Rect2(735, 180, 260, 16))
	var vs := _label("交锋", 29, Color("903d30"))
	_place(vs, Rect2(570, 114, 130, 48))
	_sprite("rule", Rect2(180, 220, 910, 1))
	stage = SubViewport.new()
	stage.size = Vector2i(910, 340)
	stage.own_world_3d = true
	stage.msaa_3d = Viewport.MSAA_4X
	stage.transparent_bg = false
	stage.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var stage_view := SubViewportContainer.new()
	stage_view.stretch = true
	_place(stage_view, Rect2(180, 232, 910, 340))
	stage_view.add_child(stage)
	var world := Node3D.new()
	stage.add_child(world)
	var env := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sky_material := ProceduralSkyMaterial.new()
	sky_material.sky_top_color = Color("667786")
	sky_material.sky_horizon_color = Color("c7c1ae")
	sky_material.ground_horizon_color = Color("c7c1ae")
	sky.sky_material = sky_material
	environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color("e7d6b2")
	environment.ambient_light_energy = 0.4
	env.environment = environment
	world.add_child(env)
	var ground := MeshInstance3D.new()
	var ground_mesh := PlaneMesh.new()
	ground_mesh.size = Vector2(60, 16)
	var ground_mat := StandardMaterial3D.new()
	ground_mat.albedo_color = Color.WHITE
	ground_mat.albedo_texture = preload("res://assets/rtk14/ground_detail.png")
	ground_mat.uv1_scale = Vector3(20, 20, 1)
	ground_mat.roughness = 1.0
	ground_mesh.material = ground_mat
	ground.mesh = ground_mesh
	ground.position = Vector3(0, -0.04, 1)
	world.add_child(ground)
	var sunlight := DirectionalLight3D.new()
	sunlight.rotation_degrees = Vector3(-43, -32, 0)
	sunlight.light_color = Color("ffeed5")
	sunlight.light_energy = 0.85
	sunlight.shadow_enabled = true
	world.add_child(sunlight)
	camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 4.7
	camera.position = Vector3(0, 3.5, 12)
	camera.look_at_from_position(camera.position, Vector3(0, 1.5, 0))
	world.add_child(camera)
	fighter_left = _fighter(world, "407a9723", Vector3(-3.8, 0, 0.48), PI / 2)
	fighter_right = _fighter(world, "8edce9d9", Vector3(3.8, 0, -0.48), -PI / 2)
	_build_backdrop(world)
	impact = MeshInstance3D.new()
	var flash := QuadMesh.new()
	flash.size = Vector2.ONE * 0.65
	var flash_material := StandardMaterial3D.new()
	flash_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	flash_material.albedo_color = Color("ffeabe")
	flash_material.albedo_texture = preload("res://assets/armies/rtk14/effects/spark.png")
	flash_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	flash_material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	flash_material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	flash_material.emission_enabled = true
	flash_material.emission = Color("ffc94e")
	flash_material.emission_energy_multiplier = 3.0
	flash.material = flash_material
	impact.mesh = flash
	impact.position = Vector3(0, 2.1, 0)
	world.add_child(impact)
	impact.hide()
	round_label = _label("交锋回合 1", 17, Color("715d43"))
	_place(round_label, Rect2(180, 574, 265, 28))
	outcome_label = _label("马前交锋", 19, Color("903d30"))
	_place(outcome_label, Rect2(450, 574, 640, 28))
	replay_button = Button.new()
	replay_button.text = "再看一次"
	UISkin.style_button(replay_button)
	_place(replay_button, Rect2(453, 638, 112, 28))
	replay_button.pressed.connect(func():
		elapsed = 0.0
		last_hit = -1
		last_round = -1
		left_bar.value = 100
		right_bar.value = 100
		replay_button.hide()
	)
	var close_button := Button.new()
	close_button.text = "返回"
	UISkin.style_button(close_button)
	_place(close_button, Rect2(620, 620, 62, 62))
	for state in ["normal", "hover", "pressed"]:
		var atlas := AtlasTexture.new()
		atlas.atlas = load("res://assets/officers/controls.png")
		atlas.region = Rect2(14, 13, 132, 132) if state == "normal" else Rect2(176, 14, 132, 132)
		var style := StyleBoxTexture.new()
		style.texture = atlas
		close_button.add_theme_stylebox_override(state, style)
	close_button.add_theme_font_size_override("font_size", 19)
	close_button.add_theme_color_override("font_color", UISkin.PALE)
	close_button.pressed.connect(close)
	var hint := _label("Esc 返回战场", 15, Color("ddd3ba"))
	_place(hint, Rect2(935, 637, 180, 26))
	get_viewport().size_changed.connect(_resize)
	_resize()

func _build_backdrop(world: Node3D) -> void:
	var noise := FastNoiseLite.new()
	noise.seed = 714
	noise.frequency = 0.16
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for x in range(32):
		for z in range(4):
			for corner in [Vector2i(0,0), Vector2i(0,1), Vector2i(1,0), Vector2i(1,0), Vector2i(0,1), Vector2i(1,1)]:
				var px := float(x + corner.x - 16) * 1.5
				var pz := -6.5 - float(z + corner.y) * 1.5
				var height := (0.55 + noise.get_noise_2d(px, pz)) * smoothstep(0.0, 2.0, float(z + corner.y))
				surface.set_uv(Vector2(px, pz) * 0.12)
				surface.add_vertex(Vector3(px, height, pz))
	surface.generate_normals()
	var ridge := MeshInstance3D.new()
	ridge.mesh = surface.commit()
	var rock := StandardMaterial3D.new()
	rock.albedo_color = Color("8d9582")
	rock.albedo_texture = preload("res://assets/rtk14/terrain/layer_01_albedo.png")
	rock.roughness = 1.0
	ridge.material_override = rock
	world.add_child(ridge)

func _portrait_box() -> TextureRect:
	var face := TextureRect.new()
	face.custom_minimum_size = Vector2(72, 72)
	face.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	face.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	face.add_theme_stylebox_override("panel", _style_panel(Color("251a16"), Color("c79b51"), 2))
	return face

func _health_bar(color: Color) -> ProgressBar:
	var bar := ProgressBar.new()
	bar.custom_minimum_size = Vector2(180, 18)
	bar.max_value = 100
	bar.value = 100
	bar.show_percentage = false
	bar.add_theme_font_override("font", UISkin.font())
	bar.add_theme_font_size_override("font_size", 13)
	var fill := StyleBoxFlat.new()
	fill.bg_color = color
	bar.add_theme_stylebox_override("fill", fill)
	bar.add_theme_stylebox_override("background", _style_panel(Color("d6cdb8"), Color("b7a98c"), 1))
	return bar

func _fighter(parent: Node3D, variant: String, at: Vector3, yaw: float) -> Node3D:
	var fighter := MountedActor.new()
	fighter.variant = variant
	fighter.position = at
	fighter.rotation.y = yaw
	parent.add_child(fighter)
	return fighter

func present_record(record: Dictionary, left: Dictionary, right: Dictionary, left_portrait: Texture2D, right_portrait: Texture2D) -> void:
	# Freeze the visible battlefield before showing the modal; use the same blur
	# shader as officer details. Standalone previews use the officer scene image.
	if not demo and not visible and DisplayServer.get_name() != "headless":
		var image := get_viewport().get_texture().get_image()
		if image != null and not image.is_empty(): backdrop.texture = ImageTexture.create_from_image(image)
	active_record = record.duplicate(true)
	round_data = record.get("rounds", []).duplicate(true)
	elapsed = 0.0
	last_round = -1
	last_hit = -1
	fighter_left.reset()
	fighter_right.reset()
	left_name.text = str(left.get("name", "我方武将"))
	right_name.text = str(right.get("name", "敌方武将"))
	left_face.texture = left_portrait
	right_face.texture = right_portrait
	# This portrait's existing thumbnail crop contains the raised shoulder.
	for face in [left_face, right_face]:
		if face.texture != null and face.texture.resource_path.ends_with("0010-head.png"):
			var head := AtlasTexture.new()
			head.atlas = preload("res://assets/officers/portraits/0010.png")
			head.region = Rect2(70, 245, 285, 270)
			face.texture = head
	var left_courage := _courage_of(left, record, 0)
	var right_courage := _courage_of(right, record, 1)
	var left_martial := int(left.get("skills", {}).get("武艺", 0))
	var right_martial := int(right.get("skills", {}).get("武艺", 0))
	left_score.text = _format_stats(left_courage, left_martial)
	right_score.text = _format_stats(right_courage, right_martial)
	left_bar.value = 100
	right_bar.value = 100
	replay_button.hide()
	stage.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	show()
	_update_stage()

func _process(delta: float) -> void:
	if not visible: return
	elapsed += delta
	_update_stage()

func _update_stage() -> void:
	if active_record.is_empty(): return
	if active_record.get("result", "") == "refused":
		outcome_label.text = "对手拒绝应战，军心受挫"
		round_label.text = "挑战未成"
		if elapsed > 2.5 and not demo: close()
		return
	var count := mini(maxi(round_data.size(), 1), 30)
	var total := float(count) * ROUND_SECONDS
	if elapsed >= total:
		impact.hide()
		var winner := int(active_record.get("winner", -1))
		var fall_progress := (elapsed - total + 0.58 * ROUND_SECONDS) / 1.1
		if winner != 1: fighter_left.pose(elapsed, 0.0, 0.0)
		if winner != 0: fighter_right.pose(elapsed + 0.4, 0.0, 0.0)
		if winner == 0: fighter_right.knock_down(fall_progress)
		elif winner == 1: fighter_left.knock_down(fall_progress)
		if winner == 0: right_bar.value = 0
		elif winner == 1: left_bar.value = 0
		round_label.text = "第 %d 回合结束" % count
		outcome_label.text = "三十回合未能击落对手，平手" if winner < 0 else "%s 获胜  对手落马" % [left_name.text if winner == 0 else right_name.text]
		if winner >= 0: outcome_label.text += "  " + str({"dead":"斩杀", "captured":"被擒"}.get(active_record.get("fate", {}).get("status", ""), "重伤"))
		replay_button.visible = demo
		if elapsed >= total + 2.0 and not demo: close()
		return
	var index := mini(int(elapsed / ROUND_SECONDS), count - 1)
	var phase := fposmod(elapsed, ROUND_SECONDS) / ROUND_SECONDS
	fighter_left.position = Vector3(-2.2, 0.0, 0.35)
	fighter_right.position = Vector3(2.2, 0.0, -0.35)
	fighter_left.rotation.y = PI / 2.0
	fighter_right.rotation.y = -PI / 2.0
	var strike := smoothstep(0.08, 0.22, phase) * (1.0 - smoothstep(0.28, 0.70, phase))
	var row: Dictionary = round_data[index] if index < round_data.size() else {}
	var attacker := int(row.get("winner", index % 2))
	fighter_left.pose(elapsed, 0.03, strike, index % 3, phase, attacker == 1)
	fighter_right.pose(elapsed + 0.35, 0.03, strike, (index + 1) % 3, phase, attacker == 0)
	if phase >= 0.42:
		var fall_progress := (phase - 0.42) * ROUND_SECONDS / 1.1
		if float(row.get("hp_a", 100)) <= 0.0: fighter_left.knock_down(fall_progress)
		if float(row.get("hp_b", 100)) <= 0.0: fighter_right.knock_down(fall_progress)
	impact.visible = phase > 0.36 and phase < 0.43
	impact.position = Vector3(0.0, 1.95, 0.0)
	impact.scale = Vector3.ONE * (0.78 + sin(phase * 120.0) * 0.22)
	if index != last_round:
		last_round = index
		round_label.text = "第 %d 回合  最多 30 回合" % (index + 1)
		outcome_label.text = "马前交锋"
	if phase >= 0.38 and last_hit != index:
		last_hit = index
		var victor := int(row.get("winner", -1))
		if row.has("hp_a") and row.has("hp_b"):
			left_bar.value = float(row["hp_a"])
			right_bar.value = float(row["hp_b"])
			if float(row["hp_a"]) <= 0.0: outcome_label.text = "%s 落马，单挑告负" % left_name.text
			elif float(row["hp_b"]) <= 0.0: outcome_label.text = "%s 落马，单挑告负" % right_name.text
		if float(row.get("hp_a", 100)) > 0.0 and float(row.get("hp_b", 100)) > 0.0:
			outcome_label.text = ("%s " % (left_name.text if victor == 0 else right_name.text) + "\u5360\u5f97\u4e0a\u98ce") if victor >= 0 else "\u5175\u5203\u76f8\u649e\uff0c\u672a\u5206\u9ad8\u4e0b"

func close() -> void:
	hide()
	stage.render_target_update_mode = SubViewport.UPDATE_DISABLED
	finished.emit()

func _input(event: InputEvent) -> void:
	if visible and event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		close()
		get_viewport().set_input_as_handled()

func _courage_of(officer: Dictionary, rec: Dictionary, index: int) -> int:
	var stats: Array = officer.get("stats", [])
	if stats.size() >= 3:
		return roundi(float(stats[2]))
	var profiles: Array = rec.get("profiles", [])
	if profiles.size() > index and profiles[index].has("courage"):
		return roundi(float(profiles[index].get("courage", 0)))
	return 0

func _format_stats(courage_val: int, martial_val: int) -> String:
	if courage_val > 0 and martial_val > 0:
		return "勇武  %d    武艺  %d" % [courage_val, martial_val]
	if courage_val > 0:
		return "勇武  %d" % courage_val
	return "武艺  %d" % martial_val
