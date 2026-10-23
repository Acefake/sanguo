extends Control
## 检验战场观看界面：选战场、试验、种子，逐刻播放 ProvingGroundSim，地图上看部队位置与姿态，
## 右侧看每个决策点的“看到的态势 → 选择 → 理由（带来源）→ 生效增益”，以及战报。
## 点地图上的部队，下方显示该部主将最近一次决策与增益拆解。
## 战场数据声明了 people_pack 时，选中战场即载入人物包；推演本身不读人物系统。
##
## 只依赖 scripts/war/proving、scripts/officers 与 Autoload People，不读 GameState，可单独打开：
##   godot --path . res://scenes/war/proving_ground.tscn

const Data = preload("res://scripts/war/proving/battlefield_data.gd")
const Sim = preload("res://scripts/war/proving/battlefield_sim.gd")
const Combat = preload("res://scripts/war/battle/combat_system.gd")
const Leadership = preload("res://scripts/officers/officer_leadership.gd")
const PeopleStore = preload("res://scripts/people/person_store.gd")
const Intent = preload("res://scripts/officers/officer_intent.gd")
const CitySkin = preload("res://scripts/ui/city_ui_skin.gd")

const SIDE_COLORS := [Color("c0392b"), Color("2e6da4")]
const TERRAIN_COLORS := {"plains": Color("d9c89a"), "forest": Color("6f8f5a"), "hills": Color("b49a6a"), "mountains": Color("8a7a66"), "river": Color("6f9fc0"), "ford": Color("8fb3c9"), "marsh": Color("8aa38a")}
const PLAY_SECONDS := 0.6

var field_choice: OptionButton
var trial_choice: OptionButton
var seed_box: SpinBox
var play_button: Button
var status: Label
var log_text: RichTextLabel
var detail_text: RichTextLabel
var map: Control
var sim: Sim
var field: Dictionary
var side_index: Dictionary = {}
var selected := ""
var playing := false
var timer := 0.0
var shown_decisions := 0
var shown_events := 0
var font: Font


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# 与城池界面同一套中文正文字体（SystemFont：思源黑体等），地图上的 draw_string 也用它。
	font = CitySkin.text_font()
	theme = Theme.new()
	theme.default_font = font
	var background := ColorRect.new()
	background.color = Color("1d2624")
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(background)
	var split := HBoxContainer.new()
	split.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	split.add_theme_constant_override("separation", 8)
	add_child(split)
	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.size_flags_stretch_ratio = 1.6
	split.add_child(left)
	map = Control.new()
	map.size_flags_vertical = Control.SIZE_EXPAND_FILL
	map.mouse_filter = Control.MOUSE_FILTER_STOP
	map.draw.connect(_draw_map)
	map.gui_input.connect(_map_input)
	left.add_child(map)
	detail_text = _rich(170)
	left.add_child(detail_text)
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 6)
	split.add_child(right)
	var title := Label.new()
	title.text = "人物 AI 检验战场"
	title.add_theme_font_size_override("font_size", 22)
	right.add_child(title)
	field_choice = OptionButton.new()
	for id in Data.ids():
		field_choice.add_item(str(Data.load_field(id)["name"]))
		field_choice.set_item_metadata(field_choice.item_count - 1, id)
	field_choice.item_selected.connect(func(_i): _load_field())
	right.add_child(field_choice)
	trial_choice = OptionButton.new()
	trial_choice.item_selected.connect(func(_i): reset())
	right.add_child(trial_choice)
	var row := HBoxContainer.new()
	right.add_child(row)
	var seed_label := Label.new()
	seed_label.text = "种子"
	row.add_child(seed_label)
	seed_box = SpinBox.new()
	seed_box.max_value = 9999
	seed_box.value_changed.connect(func(_v): reset())
	row.add_child(seed_box)
	row.add_child(_button("重置", reset))
	row.add_child(_button("单步", step_once))
	play_button = _button("播放", toggle_play)
	row.add_child(play_button)
	row.add_child(_button("跑完", run_to_end))
	status = Label.new()
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	right.add_child(status)
	log_text = _rich(0)
	log_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_child(log_text)
	if field_choice.item_count > 0: _load_field()


func _rich(height: int) -> RichTextLabel:
	var text := RichTextLabel.new()
	text.bbcode_enabled = true
	text.scroll_following = false
	text.custom_minimum_size.y = height
	text.add_theme_color_override("default_color", Color("e8e0cc"))
	return text


func _button(text: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.pressed.connect(action)
	return button


func _load_field() -> void:
	field = Data.load_field(str(field_choice.get_item_metadata(field_choice.selected)))
	PeopleStore.autoload().load_declared(field)
	trial_choice.clear()
	for trial in field["trials"]:
		trial_choice.add_item(str(trial["label"]))
		trial_choice.set_item_metadata(trial_choice.item_count - 1, trial)
	side_index.clear()
	for side in field["sides"]: side_index[side] = side_index.size()
	reset()


## 重新开一场：当前战场、试验、种子。
func reset() -> void:
	if field.is_empty() or trial_choice.item_count == 0: return
	sim = Sim.new()
	sim.setup(Data.with_trial(field, trial_choice.get_item_metadata(trial_choice.selected)), int(seed_box.value))
	shown_decisions = 0
	shown_events = 0
	selected = str(trial_choice.get_item_metadata(trial_choice.selected).get("subject", field["subject"]))
	log_text.clear()
	log_text.append_text("[b]%s[/b]\n%s\n\n" % [field["name"], field["summary"]])
	for check in field.get("checks", []): log_text.append_text("· %s\n" % check)
	log_text.append_text("\n")
	playing = false
	play_button.text = "播放"
	_refresh()


func step_once() -> void:
	if sim == null or sim.finished(): return
	sim.step()
	_refresh()


func run_to_end() -> void:
	if sim == null: return
	while not sim.finished(): sim.step()
	_refresh()


func toggle_play() -> void:
	playing = not playing
	play_button.text = "暂停" if playing else "播放"


func _process(delta: float) -> void:
	if not playing or sim == null: return
	timer += delta
	if timer < PLAY_SECONDS: return
	timer = 0.0
	if sim.finished():
		toggle_play()
		return
	step_once()


func _refresh() -> void:
	for decision in sim.decisions.slice(shown_decisions):
		var reasons := "；".join(decision["reasons"].map(func(r): return "［%s］%s" % [r["source"], r["text"]]))
		var seen: Dictionary = decision["seen"]
		log_text.append_text("[color=#d8b56a]t%d %s[/color] [b]%s[/b]%s（%s）\n  看到：兵力比 %.2f（门槛 %.2f），组织 %d，%s\n  理由：%s\n" % [decision["tick"], decision["officer"], decision["name"], "" if decision["changed"] else "·维持", decision["trigger"], float(seen["ratio"]), float(seen["engage_ratio"]), int(seen["organization"]), "接战" if seen["in_contact"] else "未接战", reasons])
	shown_decisions = sim.decisions.size()
	for event in sim.events.slice(shown_events): log_text.append_text("[color=#9fc0a0]战报 t%d：%s[/color]\n" % [event["tick"], event["text"]])
	shown_events = sim.events.size()
	var text := "第 %d 刻（%d 小时）" % [sim.tick, sim.tick * int(sim.tick_hours)]
	if sim.finished():
		var result: Dictionary = sim.result()["outcome"]
		text += " · 结束：%s" % ("和局" if result["winner"] == "draw" else str(sim.sides[result["winner"]]["name"]) + "达成目标")
	status.text = text
	_show_detail()
	map.queue_redraw()


func _show_detail() -> void:
	detail_text.clear()
	var unit: Dictionary = sim.by_id(selected) if sim != null else {}
	if unit.is_empty(): return
	var army: Dictionary = unit["army"]
	detail_text.append_text("[b]%s[/b]（%s%s）%s · 兵 %d · 士气 %d · 组织 %d · 姿态 %s\n" % [unit["officer"]["name"], sim.sides[unit["side"]]["name"], "，参军 " + unit["adviser"]["name"] if not unit["adviser"].is_empty() else "", unit["id"], Combat.strength(army), int(army["morale"]), int(army["organization"]), Intent.posture_name(str(unit["posture"])) if not str(unit["posture"]).is_empty() else "—"])
	detail_text.append_text("增益：%s\n" % Leadership.text(Leadership.notable(army, {"terrain": str(sim.zones[unit["zone"]]["terrain"])})))
	for i in range(sim.decisions.size() - 1, -1, -1):
		var decision: Dictionary = sim.decisions[i]
		if decision["unit"] != selected: continue
		var scores: Dictionary = decision["scores"]
		var keys := scores.keys()
		keys.sort_custom(func(a, b): return float(scores[a]) > float(scores[b]))
		detail_text.append_text("最近决策 t%d：%s；各姿态得分 %s\n" % [decision["tick"], decision["name"], "、".join(keys.slice(0, 4).map(func(k): return "%s %.2f" % [Intent.posture_name(k), float(scores[k])]))])
		break


func _point(zone: Dictionary) -> Vector2:
	var margin := Vector2(60, 40)
	return margin + Vector2(float(zone["x"]), float(zone["y"])) * (map.size - margin * 2.0)


func _draw_map() -> void:
	if sim == null: return
	map.draw_rect(Rect2(Vector2.ZERO, map.size), Color("2a3532"))
	for from in sim.links:
		for to in sim.links[from]:
			if str(from) < str(to): map.draw_line(_point(sim.zones[from]), _point(sim.zones[to]), Color("8d8470"), 2.0)
	for id in sim.zones:
		var zone: Dictionary = sim.zones[id]
		var p := _point(zone)
		map.draw_circle(p, 26.0, TERRAIN_COLORS.get(str(zone["terrain"]), Color.GRAY))
		if float(zone["fort"]) > 0.0: map.draw_arc(p, 29.0, 0.0, TAU, 32, Color("4a3a2a"), 3.0 + float(zone["fort"]) * 3.0)
		map.draw_string(font, p + Vector2(-30, 44), str(zone["name"]), HORIZONTAL_ALIGNMENT_CENTER, 60, 13, Color("e8e0cc"))
	var stacked := {}
	for unit in sim.units:
		if unit["escaped"] and Combat.strength(unit["army"]) <= 0: continue
		var zone: Dictionary = sim.zones[unit["zone"]]
		var slot := int(stacked.get(unit["zone"], 0))
		stacked[unit["zone"]] = slot + 1
		var p := _point(zone) + Vector2(-34 + slot * 22, -36)
		var color: Color = SIDE_COLORS[int(side_index.get(unit["side"], 0)) % 2]
		if unit["routed"] or unit["escaped"]: color = color.darkened(0.5)
		var radius := 7.0 + sqrt(float(Combat.strength(unit["army"]))) / 14.0
		if unit["hidden"] and not unit["exposed"]: map.draw_arc(p, radius, 0.0, TAU, 24, color, 2.0)
		else: map.draw_circle(p, radius, color)
		if unit["id"] == selected: map.draw_arc(p, radius + 4.0, 0.0, TAU, 24, Color("f2d27a"), 2.0)
		var tag := "%s·%s" % [unit["officer"]["name"], Intent.posture_name(str(unit["posture"])) if not str(unit["posture"]).is_empty() else "—"]
		map.draw_string(font, p + Vector2(-40, -radius - 4 - slot * 15), tag, HORIZONTAL_ALIGNMENT_CENTER, 80, 12, Color.WHITE)
	map.draw_string(font, Vector2(12, map.size.y - 12), "实心=可见  空心=隐蔽  暗色=溃散/退走  外圈粗细=工事", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color("b8b0a0"))


func _map_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT) or sim == null: return
	var best := ""
	var best_distance := 40.0
	var stacked := {}
	for unit in sim.units:
		var slot := int(stacked.get(unit["zone"], 0))
		stacked[unit["zone"]] = slot + 1
		var p := _point(sim.zones[unit["zone"]]) + Vector2(-34 + slot * 22, -36)
		if p.distance_to(event.position) < best_distance:
			best_distance = p.distance_to(event.position)
			best = unit["id"]
	if not best.is_empty():
		selected = best
		_show_detail()
		map.queue_redraw()
