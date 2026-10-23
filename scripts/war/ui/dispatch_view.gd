extends Control

signal dispatched(id: String)
const Widgets = preload("res://scripts/ui/theme/ui_widgets.gd")
const Corps = preload("res://scripts/war/campaign/army_corps.gd")
const Structure = preload("res://scripts/war/campaign/corps_structure.gd")
const StateKeys = preload("res://scripts/war/campaign/war_state_keys.gd")
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

## 字号 ≤13 用注释样式，≤15 用正文小号，其余正文；全部自动换行，适配抽屉宽度。
func label(text: String, font_size: int = 16) -> Label:
	var item := Widgets.label(text, "NoteLabel" if font_size <= 13 else "", true)
	item.size_flags_horizontal = SIZE_EXPAND_FILL
	return item

## 分节标题：强调色小标题，前面留一步空白。
func section(parent: Control, text: String) -> void:
	parent.add_child(Widgets.gap(1))
	var caption := Widgets.label(text, "AccentLabel", true)
	parent.add_child(caption)

func choice(parent: Control, title: String) -> OptionButton:
	var row := Widgets.hbox(1)
	parent.add_child(row)
	var caption := Widgets.muted(title)
	caption.custom_minimum_size.x = 96
	row.add_child(caption)
	var item := OptionButton.new()
	item.size_flags_horizontal = SIZE_EXPAND_FILL
	item.clip_text = true
	row.add_child(item)
	return item

## 右侧抽屉的「派将」页：上方可滚动的单列表单，底部固定操作行。由 campaign_ui 放进抽屉，
## 返回 / Esc / 派出后释放自身（抽屉随之关闭）。
func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var column := Widgets.vbox(1)
	column.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(column)
	var form := Widgets.vbox(1)
	column.add_child(Widgets.scroll(form))
	form.add_child(Widgets.muted("自由编组：人数不设上限，岗位、上级、兵力自定", true))
	sources = choice(form, "出发城")
	targets = choice(form, "出征目标")
	chiefs = choice(form, "部队长 / 主帅")
	officers = store.war.available_officers(str(store.war.state[StateKeys.PLAYER_FACTION]))
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
		if not city.has("garrison") or city.get("faction", "") != store.war.state[StateKeys.PLAYER_FACTION]: continue
		sources.add_item(store.war.graph.name_of(str(id)))
		sources.set_item_metadata(sources.item_count - 1, id)
		var path: Dictionary = store.war.graph.path(str(id), target)
		if str(id) != target and path["found"] and float(path["cost"]) < best:
			best = float(path["cost"])
			sources.select(sources.item_count - 1)
	for i in range(sources.item_count):
		if str(sources.get_item_metadata(i)) == home_hint: sources.select(i)
	section(form, "兵士  按城池库存综合编组")
	troops = HSlider.new()
	troops.min_value = int(store.war.rules["minimum_army"])
	troops.step = 1
	form.add_child(troops)
	resources = label("", 15)
	form.add_child(resources)
	section(form, "主帅能力  满刻度 120")
	radar = preload("res://scripts/war/ui/military_radar.gd").new()
	radar.custom_minimum_size = Vector2(0, 180)
	form.add_child(radar)
	details = label("", 13)
	form.add_child(details)
	section(form, "出阵将领")
	cards = Widgets.vbox(1)
	cards.size_flags_horizontal = SIZE_EXPAND_FILL
	form.add_child(cards)
	section(form, "随军名单  勾选任意人数")
	var roster := Widgets.vbox(0)
	roster.size_flags_horizontal = SIZE_EXPAND_FILL
	form.add_child(roster)
	for officer in officers:
		var check := CheckBox.new()
		check.text = str(officer["name"]) + "  " + str(officer.get("positions", "")).split("\n")[0]
		check.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		check.clip_text = true
		check.button_pressed = Corps.select_members(store.war, selection(chiefs), officers.map(func(o): return o["id"]), selection(sources)).has(officer["id"])
		check.toggled.connect(func(_value): refresh(true))
		checks[officer["id"]] = check
		roster.add_child(check)
	section(form, "编组  岗位可自定义，上级需在随军名单内")
	editors = Widgets.vbox(1)
	editors.size_flags_horizontal = SIZE_EXPAND_FILL
	form.add_child(editors)
	notice = label("", 13)
	column.add_child(notice)
	var buttons := Widgets.hbox(1)
	column.add_child(buttons)
	var auto_button := Widgets.secondary("自动编制", auto_compose)
	auto_button.tooltip_text = "套用自动编制预设"
	buttons.add_child(auto_button)
	buttons.add_child(Widgets.secondary("全选", select_all))
	buttons.add_child(Widgets.spring())
	buttons.add_child(Widgets.text_button("返回", queue_free))
	confirm = Widgets.primary("决定出阵", deploy)
	buttons.add_child(confirm)
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
	var header := Widgets.vbox(0)
	editors.add_child(header)
	header.add_child(label("随军 %d 人（不限）" % members().size(), 13))
	assignment = label("", 13)
	header.add_child(assignment)
	for id in members():
		var entry: Dictionary = composition.get(id, {})
		var line := Widgets.hbox(1)
		editors.add_child(line)
		var name := label(str(store.war.roster.officers[id]["name"]), 15)
		line.add_child(name)
		var role := LineEdit.new()
		role.text = str(entry.get("role", "随军"))
		role.custom_minimum_size.x = 120
		role.text_changed.connect(func(text):
			var clean: String = text.strip_edges()
			composition[id]["role"] = clean if not clean.is_empty() else "随军"
			update_editor_labels()
		)
		line.add_child(role)
		var command_line := Widgets.hbox(1)
		editors.add_child(command_line)
		command_line.add_child(Widgets.label("上级", "DimLabel"))
		var parent_choice := OptionButton.new()
		parent_choice.size_flags_horizontal = SIZE_EXPAND_FILL
		parent_choice.clip_text = true
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
		command_line.add_child(parent_choice)
		var strength := SpinBox.new()
		strength.min_value = 0
		strength.max_value = budget
		strength.step = 100
		strength.value = int(entry.get("strength", 0))
		strength.custom_minimum_size.x = 120
		strength.value_changed.connect(func(value):
			composition[id]["strength"] = int(value)
			update_editor_labels()
		)
		command_line.add_child(strength)
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
		var card := Widgets.hbox(1)
		cards.add_child(card)
		var portrait := TextureRect.new()
		portrait.custom_minimum_size = Vector2(48, 52)
		portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		var path := str(portrait_paths.get(officer["name"], {}).get("portrait", ""))
		if ResourceLoader.exists(path): portrait.texture = load(path)
		card.add_child(portrait)
		var role := str(composition.get(id, {}).get("role", "随军"))
		var count := int(composition.get(id, {}).get("strength", 0))
		var suffix := "　%d人" % count if count > 0 else ""
		card.add_child(label("%s　%s%s\n带兵 %d　布阵 %d　治军 %d" % [role, officer["name"], suffix, officer["skills"].get("带兵", 50), officer["skills"].get("布阵", 50), officer["skills"].get("治军", 50)], 15))
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
	store.war.state[StateKeys.PENDING_CORPS_PLAN] = plan
	var result: Dictionary = store.war.dispatch(selection(sources), selection(targets), chief, members(), true, int(troops.value))
	if result.get("ok", false):
		dispatched.emit(result["army_id"]); queue_free()
	else:
		store.war.state.erase(StateKeys.PENDING_CORPS_PLAN)
		notice.text = result["message"]; refresh()

func _unhandled_key_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"): get_viewport().set_input_as_handled(); queue_free()
