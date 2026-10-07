extends CanvasLayer

# Active presentation. The mounted implementation remains in duel_presentation.gd.
signal finished
const Layout = preload("res://scripts/ui_layout.gd")
const EFFECT_SECONDS := 12.0
const RESULT_SECONDS := 6.0
var elapsed := 0.0
var demo := false
var active_record: Dictionary = {}
var effects: Node3D
var source := Vector3.ZERO
var target := Vector3.ZERO
var effect_key := ""
var names: Array[String] = []
var portraits: Array = []
var status: Label
var card: Control
var mask: Control
var continue_button: Button
var started_ms := 0

func _ready() -> void:
	layer = 20
	# Other battle presentation waits until this result finishes.
	mask = Control.new()
	mask.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mask.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(mask)
	status = Label.new()
	status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	status.add_theme_font_override("font", preload("res://scripts/city_ui_skin.gd").font())
	status.add_theme_font_size_override("font_size", 32)
	status.add_theme_color_override("font_color", Color("ffe3a0"))
	status.add_theme_color_override("font_outline_color", Color("20180e"))
	status.add_theme_constant_override("outline_size", 6)
	status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(status)
	card = preload("res://scripts/war/duel_map_card.gd").new()
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mask.add_child(card)
	card.size = Vector2(620, 450)
	card.set_anchors_preset(Control.PRESET_CENTER)
	card.offset_left = -310
	card.offset_top = -225
	card.offset_right = 310
	card.offset_bottom = 225
	card.pivot_offset = Vector2(310, 225)
	continue_button = Button.new()
	continue_button.text = "继续战斗"
	continue_button.position = Vector2(220, 450)
	continue_button.size = Vector2(180, 40)
	continue_button.pressed.connect(close)
	card.add_child(continue_button)
	status.hide()
	get_viewport().size_changed.connect(_resize)
	_resize()
	hide()

func _resize() -> void:
	# Anchored rather than recomputed, so it tracks any viewport width.
	status.anchor_left = 0.0
	status.anchor_right = 1.0
	status.anchor_top = 1.0
	status.anchor_bottom = 1.0
	status.offset_left = 0
	status.offset_right = 0
	status.offset_top = Layout.bottom_offset(90, 35)
	status.offset_bottom = Layout.bottom_offset(0, 35)
	if is_instance_valid(card):
		var viewport_size := get_viewport().get_visible_rect().size
		var factor := minf(1.0, minf(viewport_size.x / 700.0, viewport_size.y / 550.0))
		card.scale = Vector2.ONE * factor
		card.set_anchors_preset(Control.PRESET_CENTER)
		card.offset_left = -310
		card.offset_top = -225
		card.offset_right = 310
		card.offset_bottom = 225

func present_record(record: Dictionary, left: Dictionary, right: Dictionary, left_face: Texture2D, right_face: Texture2D) -> void:
	if visible: return
	active_record = record.duplicate(true)
	names.assign([str(left.get("name", "我方武将")), str(right.get("name", "敌方武将"))])
	portraits = [left_face, right_face]
	for index in range(portraits.size()):
		var face: Texture2D = portraits[index]
		if face != null and face.resource_path.ends_with("0010-head.png"):
			var crop := AtlasTexture.new()
			crop.atlas = preload("res://assets/officers/portraits/0010.png")
			crop.region = Rect2(70, 245, 285, 270)
			portraits[index] = crop
	effect_key = "gold:%s:%s:%s:%s" % [record.get("tick", -1), record.get("a", names[0]), record.get("b", names[1]), get_instance_id()]
	card.show()
	status.hide()
	card.result_at = EFFECT_SECONDS
	card.record = active_record
	card.names = names
	card.faces = portraits.duplicate()
	var mapping: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/officer_portraits.json"))
	for index in range(2):
		var entry: Dictionary = mapping.get(names[index], {})
		var path := str(entry.get("portrait", ""))
		if ResourceLoader.exists(path):
			var texture: Texture2D = load(path)
			var bounds: Array = entry.get("alpha_bounds", [0, 0, texture.get_width(), texture.get_height()])
			var cropped := AtlasTexture.new()
			cropped.atlas = texture
			cropped.region = Rect2(bounds[0], bounds[1], bounds[2] - bounds[0], bounds[3] - bounds[1])
			card.faces[index] = cropped
	card.muted_faces = []
	for texture in card.faces:
		if texture == null:
			card.muted_faces.append(null)
			continue
		var image: Image = texture.get_image()
		image.adjust_bcs(1.0, 1.0, 0.0)
		card.muted_faces.append(ImageTexture.create_from_image(image))
	elapsed = 0.0
	started_ms = Time.get_ticks_msec()
	continue_button.hide()
	show()
	if is_instance_valid(mask): mask.mouse_filter = Control.MOUSE_FILTER_STOP
	_update_stage()

func _process(_delta: float) -> void:
	if not visible: return
	elapsed = float(Time.get_ticks_msec() - started_ms) / 1000.0
	_update_stage()

func _update_stage() -> void:
	if active_record.is_empty(): return
	if active_record.get("result", "") == "refused":
		card.hide()
		status.show()
		status.text = "%s 拒绝应战" % names[1]
		if elapsed >= 2.5: close()
		return
	var duration := EFFECT_SECONDS + RESULT_SECONDS
	continue_button.visible = elapsed >= EFFECT_SECONDS
	continue_button.disabled = elapsed < duration
	continue_button.text = "继续战斗" if elapsed >= duration else "结算展示 %d 秒" % ceili(duration - elapsed)
	_resize()
	card.elapsed = elapsed
	card.queue_redraw()
	if elapsed < EFFECT_SECONDS:
		var rounds: Array = active_record.get("rounds", [])
		var round_index := mini(int(elapsed / EFFECT_SECONDS * rounds.size()) + 1, maxi(rounds.size(), 1))
		status.text = "单挑中  第 %d 回合" % round_index
	else:
		var winner := int(active_record.get("winner", -1))
		status.text = "平手  %s 与 %s 未分胜负" % names if winner < 0 else "胜方：%s    负方：%s" % [names[winner], names[1 - winner]]
		if winner >= 0:
			status.text = "胜方：%s    负方：%s  %s" % [names[winner], names[1 - winner], {"dead":"被斩杀", "captured":"被俘"}.get(active_record.get("fate", {}).get("status", ""), "重伤")]

func close() -> void:
	if not visible: return
	if active_record.get("result", "") != "refused" and elapsed < EFFECT_SECONDS + RESULT_SECONDS: return
	if is_instance_valid(effects): effects.remove_duel(effect_key)
	hide()
	if is_instance_valid(mask): mask.mouse_filter = Control.MOUSE_FILTER_IGNORE
	finished.emit()

func _exit_tree() -> void:
	if is_instance_valid(effects): effects.remove_duel(effect_key)
