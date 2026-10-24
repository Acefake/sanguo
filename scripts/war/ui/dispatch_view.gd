extends Control

signal dispatched(id: String)
const CitySkin = preload("res://scripts/ui/city_ui_skin.gd")
const Corps = preload("res://scripts/war/campaign/army_corps.gd")
const Structure = preload("res://scripts/war/campaign/corps_structure.gd")
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
# 自由编制：id -> {"role": String, "parent": String, "strength": int}
# 人数不设上限；岗位、上级指挥、每节点兵力全部由玩家决定。
var composition: Dictionary = {}
var editors: VBoxContainer
var assignment: Label

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
	column.add_child(label("出阵  自由编组：人数不设上限，岗位/上级/兵力自定", 28))
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
		if not city.has("garrison") or city.get("faction", "") != store.war.state["player_faction"]: continue
		sources.add_item(store.war.graph.name_of(str(id)))
		sources.set_item_metadata(sources.item_count - 1, id)
		var path: Dictionary = store.war.graph.path(str(id), target)
		if str(id) != target and path["found"] and float(path["cost"]) < best:
			best = float(path["cost"])
			sources.select(sources.item_count - 1)
	for i in range(sources.item_count):
		if str(sources.get_item_metadata(i)) == home_hint: sources.select(i)
	cards = VBoxContainer.new()
	var card_scroll := ScrollContainer.new()
	card_scroll.custom_minimum_size.y = 150
	card_scroll.size_flags_vertical = SIZE_EXPAND_FILL
	card_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	left.add_child(card_scroll)
	cards.size_flags_horizontal = SIZE_EXPAND_FILL
	card_scroll.add_child(cards)
	section(left, "兵士  按城池库存综合编组")
	troops = HSlider.new()
	troops.min_value = int(store.war.rules["minimum_army"])
	troops.step = 1
	left.add_child(troops)
	resources = label("", 16)
	left.add_child(resources)
	section(right, "能力  主帅军事能力（满刻度120）")
	radar = preload("res://scripts/war/ui/military_radar.gd").new()
	radar.custom_minimum_size = Vector2(300, 200)
	right.add_child(radar)
	details = label("", 16)
	right.add_child(details)
	section(right, "随军名单  勾选任意人数")
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size.y = 96
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	right.add_child(scroll)
	var roster := VBoxContainer.new()
	roster.size_flags_horizontal = SIZE_EXPAND_FILL
	scroll.add_child(roster)
	for officer in officers:
		var check := CheckBox.new()
		check.text = str(officer["name"]) + "  " + str(officer.get("positions", "")).split("\n")[0]
		check.add_theme_font_override("font", CitySkin.font())
		check.add_theme_color_override("font_color", CitySkin.INK)
		check.add_theme_color_override("font_hover_color", CitySkin.INK)
		check.add_theme_color_override("font_pressed_color", CitySkin.INK)
		check.add_theme_color_override("font_disabled_color", Color("978b78"))
		check.button_pressed = Corps.select_members(store.war, selection(chiefs), officers.map(func(o): return o["id"]), selection(sources)).has(officer["id"])
		check.toggled.connect(func(_value): refresh(true))
		checks[officer["id"]] = check
		roster.add_child(check)
	section(right, "编组  岗位可自定义，上级需在随军名单内")
	var editor_scroll := ScrollContainer.new()
	editor_scroll.custom_minimum_size.y = 132
	editor_scroll.size_flags_vertical = SIZE_EXPAND_FILL
	editor_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	right.add_child(editor_scroll)
	editors = VBoxContainer.new()
	editors.add_theme_constant_override("separation", 4)
	editors.size_flags_horizontal = SIZE_EXPAND_FILL
	editor_scroll.add_child(editors)
	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	column.add_child(buttons)
	var auto_button := Button.new()
	auto_button.text = "自动编制预设"
	auto_button.custom_minimum_size = Vector2(130, 44)
	CitySkin.style_button(auto_button)
	buttons.add_child(auto_button)
	auto_button.pressed.connect(auto_compose)
	var all_button := Button.new()
	all_button.text = "全选"
	all_button.custom_minimum_size = Vector2(80, 44)
	CitySkin.style_button(all_button)
	buttons.add_child(all_button)
	all_button.pressed.connect(select_all)
	confirm = Button.new()
	confirm.text = "决定  出阵"
	confirm.custom_minimum_size = Vector2(130, 44)
	CitySkin.style_button(confirm)
	confirm.modulate = Color(1, 0.70, 0.65)
	buttons.add_child(confirm)
	var back := Button.new()
	back.text = "返回"
	back.custom_minimum_size = Vector2(90, 44)
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

func select_all() -> void:
	var chief := selection(chiefs)
	for id in checks:
		checks[id].set_pressed_no_signal(id != chief)
	refresh(true)

# 自动编制只是可选预设，玩家可任意增删岗位、成员和指挥层级。
func auto_compose() -> void:
	var chief := selection(chiefs)
	var layout: Dictionary = Corps.preview_appointments(store.war, chief, members(), int(troops.value))
	composition.clear()
	seed_composition(chief, layout, true)
	rebuild_editors(layout)
	notice.text = "已套用自动编制预设，可继续自由修改岗位、上级与兵力。"

func seed_composition(chief: String, layout: Dictionary, force: bool = false) -> void:
	var selected := members()
	var roles: Dictionary = layout["appointments"]
	var strengths := {}
	for formation in layout["formations"]:
		if str(formation["officer"]) == chief: continue
		strengths[str(formation["officer"])] = int(formation["strength"])
	var keep := {chief: true}
	for id in selected: keep[id] = true
	for id in composition.keys():
		if not keep.has(id): composition.erase(id)
	for id in selected:
		if composition.has(id) and not force: continue
		composition[id] = {"role": str(roles.get(id, "随军")), "parent": chief, "strength": int(strengths.get(id, 0))}
	composition[chief] = {"role": "主帅", "parent": "", "strength": 0}

func rebuild_editors(_layout: Dictionary = {}) -> void:
	if editors == null or not is_instance_valid(editors): return
	for child in editors.get_children(): editors.remove_child(child); child.queue_free()
	var chief := selection(chiefs)
	var budget := maxi(0, int(troops.value) - Structure.MIN_TROOP)
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 6)
	editors.add_child(header)
	header.add_child(label("随军 %d 人（不限）" % members().size(), 13))
	assignment = label("", 13)
	assignment.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	header.add_child(assignment)
	for id in members():
		var entry: Dictionary = composition.get(id, {})
		var line := HBoxContainer.new()
		line.add_theme_constant_override("separation", 4)
		editors.add_child(line)
		var name := label(str(store.war.roster.officers[id]["name"]), 14)
		name.custom_minimum_size.x = 62
		line.add_child(name)
		var role := LineEdit.new()
		role.text = str(entry.get("role", "随军"))
		role.custom_minimum_size.x = 80
		role.add_theme_font_override("font", CitySkin.font())
		role.text_changed.connect(func(text):
			var clean: String = text.strip_edges()
			composition[id]["role"] = clean if not clean.is_empty() else "随军"
			update_editor_labels()
		)
		line.add_child(role)
		var parent_choice := OptionButton.new()
		parent_choice.add_theme_font_override("font", CitySkin.font())
		var options: Array = [chief]
		for other in members():
			if other != id and not options.has(other): options.append(other)
		for pick in options:
			parent_choice.add_item(str(store.war.roster.officers[pick]["name"]))
			parent_choice.set_item_metadata(parent_choice.item_count - 1, pick)
			if str(entry.get("parent", chief)) == str(pick): parent_choice.select(parent_choice.item_count - 1)
		parent_choice.item_selected.connect(func(index):
			composition[id]["parent"] = str(parent_choice.get_item_metadata(index))
			update_editor_labels()
		)
		line.add_child(parent_choice)
		var strength := SpinBox.new()
		strength.min_value = 0
		strength.max_value = budget
		strength.step = 100
		strength.value = int(entry.get("strength", 0))
		strength.custom_minimum_size.x = 92
		strength.add_theme_font_override("font", CitySkin.font())
		strength.value_changed.connect(func(value):
			composition[id]["strength"] = int(value)
			update_editor_labels()
		)
		line.add_child(strength)
	update_editor_labels()

func update_editor_labels() -> void:
	if assignment == null or not is_instance_valid(assignment): return
	var budget := maxi(0, int(troops.value) - Structure.MIN_TROOP)
	var total := 0
	for id in members(): total += int(composition.get(id, {}).get("strength", 0))
	assignment.text = "已分配 %d / %d（主帅保留≥%d）" % [total, budget, Structure.MIN_TROOP]
	var validation: Dictionary = Corps.validate_plan(store.war, selection(chiefs), members(), current_plan(), int(troops.value))
	confirm.disabled = store.busy or not validation.get("ok", false)
	if not validation.get("ok", false): assignment.text += "\n" + str(validation.get("message", "编制无效"))
	for id in checks:
		checks[id].text = str(store.war.roster.officers[id]["name"]) + "  " + str(composition.get(id, {}).get("role", "未随军"))

func assigned_summary() -> String:
	var lines: Array = []
	var total := 0
	for id in members():
		var entry: Dictionary = composition.get(id, {})
		var count := int(entry.get("strength", 0))
		total += count
		if count > 0: lines.append("%s %s %d" % [store.war.roster.officers[id]["name"], str(entry.get("role", "随军")), count])
	return "分队：%s" % ("  ".join(lines) if not lines.is_empty() else "无，全员随中军")

func refresh(reset_count: bool = false) -> void:
	if updating: return
	updating = true
	for child in cards.get_children(): cards.remove_child(child); child.queue_free()
	var chief := selection(chiefs)
	if checks.has(chief): checks[chief].set_pressed_no_signal(false)
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
	seed_composition(chief, layout)
	rebuild_editors(layout)
	var order: Array = [chief]
	for id in members():
		if id != chief: order.append(id)
	for id in order:
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
		var role := str(composition.get(id, {}).get("role", "随军"))
		var count := int(composition.get(id, {}).get("strength", 0))
		var suffix := "　%d人" % count if count > 0 else ""
		card.add_child(label("%s　%s%s\n带兵 %d　布阵 %d　治军 %d" % [role, officer["name"], suffix, officer["skills"].get("带兵", 50), officer["skills"].get("布阵", 50), officer["skills"].get("治军", 50)], 17))
	var chief_data: Dictionary = store.war.roster.officers[chief]
	radar.values.clear()
	for name in radar.NAMES: radar.values.append(chief_data["skills"].get(name, 50))
	radar.queue_redraw()
	details.text = "主帅发令；各部将按性格与立场独立决定服从/异议/自行行动，主帅不覆盖拒命者。\n" + assigned_summary()
	for id in checks:
		checks[id].text = str(store.war.roster.officers[id]["name"]) + "  " + str(composition.get(id, {}).get("role", "未随军"))
		checks[id].tooltip_text = str(store.war.roster.officers[id].get("positions", ""))
	resources.text = "兵士 %d　留守 %d\n预计通路 %d 日  主帅可调整路线" % [preview["strength"], preview["reserve"], preview["travel_days"]]
	var gathering: int = store.war.Operations.assembly_days(store.war, selection(sources), [chief] + members())
	if gathering > 0: resources.text += "\n异地将领集结：另需%d日" % gathering
	updating = false

func current_plan() -> Dictionary:
	var chief := selection(chiefs)
	var plan := {"commander": chief, "members": []}
	for id in members():
		var entry: Dictionary = composition.get(id, {})
		plan["members"].append({"id": id, "role": str(entry.get("role", "随军")), "parent": str(entry.get("parent", chief)), "strength": int(entry.get("strength", 0))})
	return plan

func deploy() -> void:
	if store.busy: notice.text = "请先暂停时间流动。"; return
	var chief := selection(chiefs)
	var plan: Dictionary = current_plan()
	var validation: Dictionary = Corps.validate_plan(store.war, chief, members(), plan, int(troops.value))
	if not validation.get("ok", false): notice.text = str(validation.get("message", "编制无效")); return
	store.war.state["pending_corps_plan"] = plan
	var result: Dictionary = store.war.dispatch(selection(sources), selection(targets), chief, members(), true, int(troops.value))
	if result.get("ok", false):
		dispatched.emit(result["army_id"]); queue_free()
	else:
		store.war.state.erase("pending_corps_plan")
		notice.text = result["message"]; refresh()

func _unhandled_key_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"): get_viewport().set_input_as_handled(); queue_free()
