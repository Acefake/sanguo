extends CanvasLayer

const UISkin = preload("res://scripts/war/war_ui_skin.gd")
const Scenarios = preload("res://scripts/war/battle_scenarios.gd")
var store: Node
var surface: Control
var selected := "guandu_clash"
var buttons: Dictionary = {}
var description: Label
var seed: SpinBox
var launch: Button
var notice: Label
var title: Label
var subtitle: Label
var close_button: Button
var return_button: Button
var startup_mode := false

func _ready() -> void:
	layer = 40
	store = get_node("/root/GameState")
	surface = Control.new()
	surface.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(surface)
	var shade := ColorRect.new()
	shade.color = Color(0.06, 0.05, 0.03, 0.65)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	surface.add_child(shade)
	var panel := UISkin.framed_panel(24)
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	panel.offset_left = -440
	panel.offset_right = 440
	panel.offset_top = -300
	panel.offset_bottom = 300
	surface.add_child(panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 16)
	panel.add_child(column)
	var header := HBoxContainer.new()
	column.add_child(header)
	title = UISkin.label("选择战场", 25)
	title.add_theme_font_override("font", UISkin.CitySkin.font())
	header.add_child(title)
	close_button = UISkin.button("关闭", func():
		if startup_mode: get_tree().quit()
		else: surface.hide())
	header.add_child(close_button)
	subtitle = UISkin.label("八大经典战场  自由军团编制  地形克制、兵种调度与战略目标各不相同", 12, UISkin.MUTED)
	column.add_child(subtitle)
	UISkin.rule(column)
	var content := HBoxContainer.new()
	content.add_theme_constant_override("separation", 24)
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(content)
	var scroll := ScrollContainer.new()
	scroll.name = "ScenarioListScroll"
	scroll.custom_minimum_size = Vector2(240, 280)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	content.add_child(scroll)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 8)
	scroll.add_child(list)
	for spec in Scenarios.definitions():
		var id: String = spec["id"]
		var button := UISkin.button(spec["name"], func(): choose(id))
		button.name = "Scenario_" + id
		button.custom_minimum_size.y = 35
		button.tooltip_text = str(spec.get("category", "")) + "\n" + str(spec.get("objective_text", ""))
		list.add_child(button)
		buttons[id] = button
	var detail := VBoxContainer.new()
	detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail.add_theme_constant_override("separation", 16)
	content.add_child(detail)
	description = UISkin.label("", 14)
	description.name = "ScenarioDescription"
	description.size_flags_vertical = Control.SIZE_EXPAND_FILL
	detail.add_child(description)
	detail.add_child(UISkin.label("随机种子  相同种子可复现本地策略开局", 12, UISkin.MUTED))
	seed = SpinBox.new()
	seed.name = "BattleSeed"
	seed.min_value = 1
	seed.max_value = 2147483647
	seed.value = 1910901
	seed.custom_minimum_size.y = 30
	var seed_field := seed.get_line_edit()
	seed_field.add_theme_stylebox_override("normal", UISkin.paper(6))
	seed_field.add_theme_stylebox_override("focus", UISkin.paper(6))
	seed_field.add_theme_font_override("font", UISkin.font())
	seed_field.add_theme_font_size_override("font_size", 13)
	seed_field.add_theme_color_override("font_color", UISkin.INK)
	detail.add_child(seed)
	notice = UISkin.label("", 12, UISkin.RED)
	column.add_child(notice)
	var actions := HBoxContainer.new()
	column.add_child(actions)
	launch = UISkin.button("开始 / 重置此场景", func():
		if store.busy:
			notice.text = "请先完成当前推进，再切换场景。"
			return
		surface.hide()
		store.start_battle_test(selected, int(seed.value))
	, true)
	launch.name = "LaunchBattleScenario"
	launch.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	actions.add_child(launch)
	return_button = UISkin.button("返回原战役", func():
		if store.busy: notice.text = "请先完成当前推进。"; return
		if store.battle_test: surface.hide(); store.leave_battle_test()
	)
	actions.add_child(return_button)
	choose(selected)
	surface.hide()

func choose(id: String) -> void:
	var spec := Scenarios.definition(id)
	if spec.is_empty(): return
	selected = id
	for key in buttons: UISkin.style_button(buttons[key], key == id)
	var strengths: Dictionary = spec.get("strengths", {"liu_bei": 20000, "yuan_shao": 20000})
	description.text = str(spec["name"]) + "  " + str(spec.get("category", "")) + "\n\n" + str(spec["description"]) + "\n\n作战目标\n" + str(spec.get("objective_text", "击溃敌军")) + "\n\n双方野战兵力  %d / %d\n自由编制  岗位、兵力与指挥层级由玩家设定\n各将领依据性格与立场决定服从、异议或自行行动。" % [strengths["liu_bei"], strengths["yuan_shao"]]
	if spec["kind"] == "siege": description.text += "\n守军另有%d人，己方野战部队归城防守。" % int(spec.get("garrison", 3000))
	elif spec["kind"] == "combined": description.text += "\n城内另有%d守军，援军与城防共同作战。" % int(spec.get("garrison", 3000))
	if int(spec.get("engines", 0)) > 0: description.text += "\n攻城前锋携带%d辆攻城兵器。" % int(spec["engines"])

func open(from_startup: bool = false) -> void:
	startup_mode = from_startup
	title.text = "选择战场"
	subtitle.text = "先选择战场，再点击开始战斗。" if startup_mode else "独立战场  结束后可返回原战役"
	close_button.text = "退出" if startup_mode else "关闭"
	return_button.visible = not startup_mode
	launch.text = "开始战斗" if startup_mode else "开始 / 重置此场景"
	var board: Dictionary = store.war.state.get("battlefield", {})
	choose(str(board.get("scenario_id", "guandu_clash")))
	seed.value = int(board.get("seed", 1910901))
	notice.text = "请先完成当前推进，再切换场景。" if store.busy else ""
	launch.disabled = store.busy
	surface.show()

func _unhandled_key_input(event: InputEvent) -> void:
	if not startup_mode and surface.visible and event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		surface.hide()
		get_viewport().set_input_as_handled()
