extends Control

signal dispatched(id: String)
const CitySkin = preload("res://scripts/city_ui_skin.gd")
const Corps = preload("res://scripts/war/army_corps.gd")
var store: Node
var target := ""
var home_hint := ""
var sources: OptionButton
var targets: OptionButton
var chiefs: OptionButton
var troops: HSlider
var checks := {}
var cards: VBoxContainer
var details: Label
var resources: Label
var radar: Control
var confirm: Button
var notice: Label
var officers: Array = []
var portrait_paths: Dictionary = {}
var updating := false

func label(text: String, font_size: int = 18) -> Label:
	var item := CitySkin.label(text, font_size)
	item.add_theme_font_override("font", CitySkin.font())
	item.size_flags_horizontal = SIZE_EXPAND_FILL
	item.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return item

func section(parent: Control, text: String) -> void:
	var panel := PanelContainer.new()
	var style := StyleBoxTexture.new()
	style.texture = load("res://assets/war/dispatch/section.png")
	panel.add_theme_stylebox_override("panel", style)
	var caption := label(text)
	caption.add_theme_color_override("font_color", Color("f5e2ae"))
	caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	panel.add_child(caption)
	parent.add_child(panel)

func choice(parent: Control, title: String) -> OptionButton:
	parent.add_child(label(title, 16))
	var item := OptionButton.new()
	item.add_theme_font_override("font", CitySkin.font())
	item.custom_minimum_size.y = 34
	CitySkin.style_button(item)
	parent.add_child(item)
	return item

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var shade := ColorRect.new()
	shade.color = Color(0, 0, 0, 0.62)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(shade)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(minf(1100, get_viewport_rect().size.x - 40), minf(690, get_viewport_rect().size.y - 30))
	var paper := StyleBoxTexture.new()
	paper.texture = load("res://assets/war/dispatch/paper.png")
	paper.texture_margin_left = 12
	paper.texture_margin_right = 12
	paper.texture_margin_top = 12
	paper.texture_margin_bottom = 12
	paper.content_margin_left = 22
	paper.content_margin_right = 22
	paper.content_margin_top = 16
	paper.content_margin_bottom = 16
	panel.add_theme_stylebox_override("panel", paper)
	center.add_child(panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	panel.add_child(column)
	column.add_child(label("出阵　·　决定主帅与随军编组", 30))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 26)
	row.size_flags_vertical = SIZE_EXPAND_FILL
	column.add_child(row)
	var left := VBoxContainer.new()
	left.custom_minimum_size.x = 420
	row.add_child(left)
	var right := VBoxContainer.new()
	right.size_flags_horizontal = SIZE_EXPAND_FILL
	row.add_child(right)
	sources = choice(left, "出发城")
	targets = choice(left, "出征目标")
	chiefs = choice(left, "部队长 / 主帅")
	officers = store.war.available_officers(str(store.war.state["player_faction"]))
	officers.sort_custom(func(a, b): return Corps.suitability(a, "主帅") > Corps.suitability(b, "主帅"))
	portrait_paths = JSON.parse_string(FileAccess.get_file_as_string("res://data/officer_portraits.json"))
	for officer in officers:
		chiefs.add_item(str(officer["name"]))
		chiefs.set_item_metadata(chiefs.item_count - 1, officer["id"])
	var best := INF
	for id in store.war.graph.places:
		targets.add_item(store.war.graph.name_of(str(id)))
		targets.set_item_metadata(targets.item_count - 1, id)
		if str(id) == target: targets.select(targets.item_count - 1)
		var city: Dictionary = store.city_state(str(id))
		if not city.has("population") or city.get("faction", "") != store.war.state["player_faction"]: continue
		sources.add_item(store.war.graph.name_of(str(id)))
		sources.set_item_metadata(sources.item_count - 1, id)
		var path: Dictionary = store.war.graph.path(str(id), target)
		if str(id) != target and path["found"] and float(path["cost"]) < best:
			best = float(path["cost"])
			sources.select(sources.item_count - 1)
	for i in range(sources.item_count):
		if str(sources.get_item_metadata(i)) == home_hint: sources.select(i)
	cards = VBoxContainer.new()
	left.add_child(cards)
	section(left, "兵士 · 按城池库存综合编组")
	troops = HSlider.new()
	troops.min_value = int(store.war.rules["minimum_army"])
	troops.step = 1
	left.add_child(troops)
	resources = label("", 16)
	left.add_child(resources)
	section(right, "能力 · 主帅军事能力（满刻度120）")
	radar = preload("res://scripts/war/military_radar.gd").new()
	radar.custom_minimum_size = Vector2(300, 200)
	right.add_child(radar)
	details = label("", 16)
	right.add_child(details)
	section(right, "随军人员 · 按人物位置分配任务")
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size.y = 125
	scroll.size_flags_vertical = SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	right.add_child(scroll)
	var roster := VBoxContainer.new()
	roster.size_flags_horizontal = SIZE_EXPAND_FILL
	scroll.add_child(roster)
	for officer in officers:
		var check := CheckBox.new()
		check.text = str(officer["name"]) + " · " + str(officer.get("positions", "")).split("\n")[0]
		check.add_theme_font_override("font", CitySkin.font())
		check.add_theme_color_override("font_color", CitySkin.INK)
		check.add_theme_color_override("font_hover_color", CitySkin.INK)
		check.add_theme_color_override("font_pressed_color", CitySkin.INK)
		check.add_theme_color_override("font_disabled_color", Color("978b78"))
		check.button_pressed = true
		check.toggled.connect(func(_value): refresh())
		checks[officer["id"]] = check
		roster.add_child(check)
	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	column.add_child(buttons)
	confirm = Button.new()
	confirm.text = "决定 · 出阵"
	confirm.custom_minimum_size = Vector2(150, 44)
	CitySkin.style_button(confirm)
	confirm.modulate = Color(1, 0.70, 0.65)
	buttons.add_child(confirm)
	var back := Button.new()
	back.text = "返回"
	back.custom_minimum_size = Vector2(100, 44)
	CitySkin.style_button(back)
	back.modulate = Color(1, 0.70, 0.65)
	buttons.add_child(back)
	back.pressed.connect(queue_free)
	confirm.pressed.connect(deploy)
	notice = label("", 14)
	column.add_child(notice)
	sources.item_selected.connect(func(_index): refresh(true))
	targets.item_selected.connect(func(_index): refresh())
	chiefs.item_selected.connect(func(_index): refresh(true))
	troops.value_changed.connect(func(_value): refresh())
	refresh(true)

func selection(item: OptionButton) -> String:
	return str(item.get_item_metadata(item.selected)) if item.item_count > 0 else ""

func members() -> Array:
	var result := []
	for id in checks:
		if id != selection(chiefs) and checks[id].button_pressed: result.append(id)
	return result

func refresh(reset_count: bool = false) -> void:
	if updating: return
	updating = true
	for child in cards.get_children(): cards.remove_child(child); child.queue_free()
	var chief := selection(chiefs)
	for id in checks: checks[id].disabled = id == chief
	var preview: Dictionary = store.war.preview_dispatch(selection(sources), selection(targets), chief)
	confirm.disabled = store.busy or not preview.get("ok", false)
	if not preview.get("ok", false):
		resources.text = preview["message"]
		details.text = "请调整出发城或主帅。"
		radar.values.clear()
		radar.queue_redraw()
		updating = false
		return
	troops.max_value = int(preview["maximum"])
	if reset_count: troops.value = troops.max_value
	preview = store.war.preview_dispatch(selection(sources), selection(targets), chief, false, int(troops.value))
	var layout: Dictionary = Corps.preview_appointments(store.war, chief, members(), int(preview["strength"]))
	var positions: Dictionary = layout["appointments"]
	for id in positions:
		if positions[id] not in ["主帅", "副帅", "军师"]: continue
		var officer: Dictionary = store.war.roster.officers[id]
		var card := HBoxContainer.new()
		cards.add_child(card)
		var portrait := TextureRect.new()
		portrait.custom_minimum_size = Vector2(60, 65)
		portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		var path := str(portrait_paths.get(officer["name"], {}).get("portrait", ""))
		if ResourceLoader.exists(path): portrait.texture = load(path)
		card.add_child(portrait)
		card.add_child(label("%s　%s\n带兵 %d　布阵 %d　治军 %d" % [positions[id], officer["name"], officer["skills"].get("带兵", 50), officer["skills"].get("布阵", 50), officer["skills"].get("治军", 50)], 17))
	var chief_data: Dictionary = store.war.roster.officers[chief]
	radar.values.clear()
	for name in radar.NAMES: radar.values.append(chief_data["skills"].get(name, 50))
	radar.queue_redraw()
	var formation_lines := PackedStringArray()
	for item in layout["formations"]: formation_lines.append("%s %s %d" % [store.war.roster.officers[item["officer"]]["name"], Corps.TASKS[item["task"]], item["strength"]])
	details.text = "主帅统一决策，下属执行军令。\n主阵：由主帅部署时选择（鱼鳞/鹤翼/方圆/雁行/锋矢/长蛇）。\n" + " · ".join(formation_lines) + "\n随军 %d 人 · 职务按人物位置适性任命" % (members().size() + 1)
	for id in checks:
		checks[id].text = str(store.war.roster.officers[id]["name"]) + " · " + str(positions.get(id, "未随军"))
		checks[id].tooltip_text = str(store.war.roster.officers[id].get("positions", ""))
	resources.text = "兵士 %d　留守 %d\n携粮 %d　约 %d 日份\n预计通路 %d 日 · 主帅可调整路线" % [preview["strength"], preview["reserve"], preview["grain"], preview["grain_days"], preview["travel_days"]]
	updating = false

func deploy() -> void:
	if store.busy: notice.text = "请先暂停时间流动。"; return
	var result: Dictionary = store.war.dispatch(selection(sources), selection(targets), selection(chiefs), members(), true, int(troops.value))
	if result.get("ok", false): dispatched.emit(result["army_id"]); queue_free()
	else: notice.text = result["message"]; refresh()

func _unhandled_key_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"): get_viewport().set_input_as_handled(); queue_free()


