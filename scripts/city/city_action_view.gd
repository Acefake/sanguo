extends Control

signal confirmed(action_id: String)
signal cancelled

const CitySkin = preload("res://scripts/ui/city_ui_skin.gd")
const TITLES := {"govern": "安民", "develop": "开垦", "tax": "征税", "recruit": "征兵", "train": "训练", "fortify": "修筑", "buy_grain": "购粮", "sell_grain": "售粮", "forge": "锻造", "visit": "访察"}
const CAPTIONS := {"treasury": "金钱", "grain": "粮草", "population": "人口", "garrison": "士兵", "order": "民心", "economy": "经济", "training": "训练", "defense": "城防", "equipment": "军备"}
const PURPOSE := {"govern": "抚恤百姓，整顿本城政务。", "develop": "开垦田土，改善城池经济与粮食供给。", "tax": "征收本城赋税，充实府库。", "recruit": "从本城人口中征募兵员。", "train": "操练驻军，提升兵马训练。", "fortify": "修缮城墙，加强本城防御。", "buy_grain": "以府库金钱购入粮草。", "sell_grain": "出售城中余粮，补充府库。", "forge": "锻造兵装，完善驻军军备。", "visit": "访察民间，安抚城中百姓。"}

var action_id := ""
var confirm_button: Button
var return_button: Button
var page_title: Label
var purpose_label: Label
var city_label: Label
var faction_label: Label
var status_label: Label
var cost_rows: VBoxContainer
var result_rows: VBoxContainer


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var dim := ColorRect.new()
	dim.color = Color("181a1d", 0.46)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dim)
	_panel(Rect2(0, 0, 1260, 77), CitySkin.sheet(1.0, 0))
	page_title = _text("", Rect2(43, 10, 330, 60), 44)
	purpose_label = _text("", Rect2(470, 26, 730, 30), 18)
	_panel(Rect2(163, 103, 934, 505), CitySkin.sheet(0.90, 0))
	_section("执行事务", Rect2(278, 130, 132, 29))
	_panel(Rect2(428, 126, 593, 152), CitySkin.sheet(0.80, 12))
	city_label = _text("", Rect2(449, 139, 375, 36), 25)
	faction_label = _text("", Rect2(449, 182, 375, 29), 18, Color("885d43"))
	_text("城守参议", Rect2(449, 218, 240, 25), 17)
	var portrait := TextureRect.new()
	portrait.name = "ActionPortrait"
	portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	var crop := AtlasTexture.new()
	crop.atlas = load("res://assets/city/han/officer-user.png")
	crop.region = Rect2(300, 10, 470, 530)
	portrait.texture = crop
	portrait.position = Vector2(873, 133)
	portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	portrait.size = Vector2(127, 139)
	portrait.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(portrait)
	portrait.set_deferred("size", Vector2(127, 139))
	_section("消耗", Rect2(278, 297, 132, 29))
	cost_rows = _table(Rect2(428, 294, 593, 112))
	_section("结果", Rect2(278, 428, 132, 29))
	result_rows = _table(Rect2(428, 425, 593, 153))
	status_label = _text("", Rect2(220, 608, 820, 26), 16, Color("9f463a"))
	status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	confirm_button = _decision("决定", Vector2(553, 637))
	confirm_button.pressed.connect(func() -> void: confirmed.emit(action_id))
	return_button = _decision("返回", Vector2(642, 637))
	return_button.pressed.connect(func() -> void: cancelled.emit())
	hide()


func present(store: Node, city_id: String, city_name: String, chosen_action: String) -> void:
	action_id = chosen_action
	var projection: Dictionary = store.preview_action(city_id, action_id)
	var spec: Dictionary = store.ACTIONS[action_id]
	var before: Dictionary = projection["before"]
	var after: Dictionary = projection["after"]
	page_title.text = str(TITLES[action_id])
	purpose_label.text = str(PURPOSE[action_id])
	city_label.text = city_name + "  " + str(spec["title"])
	faction_label.text = str(store.faction_for(city_id).get("name", "无主")) + "军  /  本城事务"
	_clear(cost_rows)
	_clear(result_rows)
	if int(spec["money"]) > 0:
		_row(cost_rows, "金钱", int(before.get("treasury", 0)), int(before.get("treasury", 0)) - int(spec["money"]))
	if int(spec["grain"]) > 0:
		_row(cost_rows, "粮草", int(before.get("grain", 0)), int(before.get("grain", 0)) - int(spec["grain"]))
	_row(cost_rows, "行动力", int(projection["action_points_before"]), int(projection["action_points_before"]) - 1)
	for key in ["garrison", "population", "order", "economy", "training", "defense", "equipment", "grain", "treasury"]:
		var previous := int(before.get(key, 0))
		var next := int(after.get(key, 0))
		if previous == next:
			continue
		if (key == "treasury" and int(spec["money"]) > 0) or (key == "grain" and int(spec["grain"]) > 0):
			continue
		_row(result_rows, str(CAPTIONS[key]), previous, next)
	confirm_button.disabled = not bool(projection["ok"])
	status_label.text = str(projection["message"])
	show()
	if confirm_button.disabled:
		return_button.grab_focus()
	else:
		confirm_button.grab_focus()


func _row(parent: VBoxContainer, caption: String, before: int, after: int) -> void:
	var row := HBoxContainer.new()
	row.custom_minimum_size.y = 33
	row.add_theme_constant_override("separation", 14)
	parent.add_child(row)
	var name_label := CitySkin.label(caption, 19, Color("8a624b"))
	name_label.custom_minimum_size.x = 100
	row.add_child(name_label)
	var old := CitySkin.label(str(before), 21)
	old.custom_minimum_size.x = 94
	old.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(old)
	row.add_child(CitySkin.label("→", 22, Color("82786b")))
	var delta := after - before
	var color := Color("457bb2") if delta > 0 else Color("bd5a4a")
	var value := CitySkin.label("%d  (%+d)" % [after, delta], 21, color)
	row.add_child(value)
	parent.add_child(HSeparator.new())


func _table(rect: Rect2) -> VBoxContainer:
	var panel := _panel(rect, CitySkin.sheet(0.87, 9))
	var rows := VBoxContainer.new()
	rows.add_theme_constant_override("separation", 0)
	rows.alignment = BoxContainer.ALIGNMENT_BEGIN
	panel.add_child(rows)
	return rows


func _section(caption: String, rect: Rect2) -> void:
	var panel := _panel(rect, CitySkin.section_header(3))
	var title := CitySkin.label(caption, 20, Color("d5bd80"))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	panel.add_child(title)


func _decision(caption: String, location: Vector2) -> Button:
	var button := Button.new()
	button.position = location
	button.text = caption
	CitySkin.style_confirm_button(button)
	add_child(button)
	return button


func _panel(rect: Rect2, style: StyleBox) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.position = rect.position
	panel.size = rect.size
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_theme_stylebox_override("panel", style)
	add_child(panel)
	return panel


func _text(caption: String, rect: Rect2, point_size: int, color: Color = CitySkin.INK) -> Label:
	var result := CitySkin.label(caption, point_size, color)
	result.position = rect.position
	result.size = rect.size
	add_child(result)
	return result


func _clear(container: Control) -> void:
	for child in container.get_children():
		container.remove_child(child)
		child.queue_free()
