extends CanvasLayer
## 选择战场：左侧分类筛选 + 卡片网格（地形缩略图、名称、类别），右侧详情只放决定出阵的信息
## （胜利条件、对阵与兵力、我方），随机种子收进「更多」。
##
## 缩略图由 battle_scenarios.json 的 thumb 字段指向 assets/ui/battle_thumbs/，离线用
## tools/capture/capture_battle_thumbs.gd 生成；缺图时卡片显示占位。
## 界面只建一次，切换场景只改详情里的文字，不重建节点。

const Scenarios = preload("res://scripts/war/battle/battle_scenarios.gd")
const Terrain = preload("res://scripts/war/battle/battle_terrain.gd")
const StateKeys = preload("res://scripts/war/campaign/war_state_keys.gd")
const Tokens = preload("res://scripts/ui/theme/ui_tokens.gd")
const Widgets = preload("res://scripts/ui/theme/ui_widgets.gd")
const SIDES_CONFIG := "res://data/war/xiaopei_battle.json"
const KIND_NAMES := {"field": "野战", "siege": "攻城", "combined": "城野协同"}
const DETAIL_WIDTH := 360
const GRID_COLUMNS := 4
const DEFAULT_SEED := 1910901

var store: Node
var surface: Control
var selected := "guandu_clash"
## 场景 id -> 卡片按钮。按下即选中该场景。
var buttons: Dictionary = {}
var seed: SpinBox
var launch: Button
var notice: Label
var title: Label
var subtitle: Label
var close_button: Button
var return_button: Button
var startup_mode := false

var _shade: ColorRect
var _specs: Array = []
var _filters := ButtonGroup.new()
var _cards := ButtonGroup.new()
var _detail_name: Label
var _detail_meta: Label
var _objective: Label
var _sides: VBoxContainer
var _side_rows: Array[Dictionary] = []
var _extra: Label
var _more: VBoxContainer
var _more_button: Button
var _player_faction := "liu_bei"


func _ready() -> void:
	layer = 40
	store = get_node("/root/GameState")
	_specs = Scenarios.definitions()
	var sides: Variant = JSON.parse_string(FileAccess.get_file_as_string(SIDES_CONFIG))
	if sides is Dictionary: _player_faction = str(sides.get("player_faction", _player_faction))
	surface = Control.new()
	surface.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	Widgets.adopt_theme(surface)
	add_child(surface)
	_shade = Widgets.shade()
	surface.add_child(_shade)
	var frame := MarginContainer.new()
	frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right"]: frame.add_theme_constant_override("margin_" + side, Tokens.space(6))
	frame.add_theme_constant_override("margin_top", Tokens.space(8))
	frame.add_theme_constant_override("margin_bottom", Tokens.space(5))
	surface.add_child(frame)
	var row := Widgets.hbox(4)
	frame.add_child(row)
	row.add_child(_build_browser())
	row.add_child(_build_detail())
	close_button = Widgets.text_button("关闭", _close)
	close_button.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	close_button.offset_left = -Tokens.space(10)
	close_button.offset_right = -Tokens.space(2)
	close_button.offset_top = Tokens.space(3)
	close_button.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	surface.add_child(close_button)
	choose(selected)
	surface.hide()


func _build_browser() -> Control:
	var column := Widgets.vbox(2)
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title = Widgets.display("选择战场")
	column.add_child(title)
	subtitle = Widgets.muted("")
	column.add_child(subtitle)
	column.add_child(Widgets.gap(1))
	var filters := Widgets.hbox(1)
	column.add_child(filters)
	var kinds: Array = []
	for spec in _specs:
		if not kinds.has(spec["kind"]): kinds.append(spec["kind"])
	var everything := Widgets.pill("全部", _filters, func() -> void: _filter(""))
	everything.button_pressed = true
	filters.add_child(everything)
	for kind in kinds:
		filters.add_child(Widgets.pill(KIND_NAMES.get(kind, str(kind)), _filters, func() -> void: _filter(str(kind))))
	var grid := GridContainer.new()
	grid.columns = GRID_COLUMNS
	grid.add_theme_constant_override("h_separation", Tokens.space(2))
	grid.add_theme_constant_override("v_separation", Tokens.space(2))
	for spec in _specs:
		var card := _card(spec)
		grid.add_child(card)
		buttons[spec["id"]] = card
	var area := Widgets.scroll(grid)
	area.name = "ScenarioListScroll"
	column.add_child(area)
	return column


## 一张场景卡：上为缩略图（圆角遮罩），下为名称与「类别 · 地形」。
func _card(spec: Dictionary) -> Button:
	var id: String = spec["id"]
	var card := Widgets.card_button(_cards, func() -> void: choose(id))
	card.name = "Scenario_" + id
	card.custom_minimum_size = Vector2(0, 176)
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.tooltip_text = str(spec.get("description", ""))
	var inset := 2
	var mask := Panel.new()
	mask.clip_children = CanvasItem.CLIP_CHILDREN_ONLY
	mask.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var shape := StyleBoxFlat.new()
	shape.bg_color = Tokens.color("ink")
	shape.set_corner_radius_all(Tokens.radius("card") - inset)
	shape.corner_radius_bottom_left = 0
	shape.corner_radius_bottom_right = 0
	mask.add_theme_stylebox_override("panel", shape)
	mask.anchor_right = 1.0
	mask.offset_left = inset
	mask.offset_top = inset
	mask.offset_right = -inset
	mask.offset_bottom = 104
	card.add_child(mask)
	var thumb_path := str(spec.get("thumb", ""))
	if not thumb_path.is_empty() and ResourceLoader.exists(thumb_path):
		var thumb := TextureRect.new()
		thumb.texture = load(thumb_path)
		thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		thumb.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		thumb.mouse_filter = Control.MOUSE_FILTER_IGNORE
		mask.add_child(thumb)
	else:
		var placeholder := Widgets.label(str(spec["name"]).left(1), "DisplayLabel")
		placeholder.add_theme_color_override("font_color", Tokens.color("dim"))
		placeholder.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		placeholder.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		placeholder.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		mask.add_child(placeholder)
	var text := Widgets.vbox(0)
	text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	text.anchor_right = 1.0
	text.anchor_bottom = 1.0
	text.offset_left = Tokens.space(2)
	text.offset_right = -Tokens.space(2)
	text.offset_top = 104 + Tokens.space(1)
	text.offset_bottom = -Tokens.space(1)
	card.add_child(text)
	var name_label := Widgets.label(str(spec["name"]))
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	text.add_child(name_label)
	var meta := Widgets.caption(_meta(spec))
	meta.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	text.add_child(meta)
	return card


func _build_detail() -> Control:
	var panel := Widgets.panel()
	panel.custom_minimum_size.x = DETAIL_WIDTH
	var column := Widgets.vbox(2)
	panel.add_child(column)
	var head := Widgets.vbox(0)
	column.add_child(head)
	_detail_name = Widgets.title("")
	_detail_name.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	head.add_child(_detail_name)
	_detail_meta = Widgets.caption("")
	head.add_child(_detail_meta)
	column.add_child(Widgets.rule())
	column.add_child(Widgets.label("胜利条件", "DimLabel"))
	_objective = Widgets.label("", "", true)
	column.add_child(_objective)
	column.add_child(Widgets.gap(1))
	column.add_child(Widgets.label("对阵", "DimLabel"))
	_sides = Widgets.vbox(1)
	column.add_child(_sides)
	for i in 2: _side_rows.append(_side_row())
	_extra = Widgets.muted("", true)
	column.add_child(_extra)
	column.add_child(Widgets.spring())
	_more_button = Widgets.text_button("更多  ›", _toggle_more)
	_more_button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	column.add_child(_more_button)
	_more = Widgets.vbox(1)
	_more.visible = false
	column.add_child(_more)
	var seed_row := Widgets.hbox(2)
	_more.add_child(seed_row)
	var seed_caption := Widgets.label("随机种子")
	seed_caption.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	seed_row.add_child(seed_caption)
	seed = SpinBox.new()
	seed.name = "BattleSeed"
	seed.min_value = 1
	seed.max_value = 2147483647
	seed.value = DEFAULT_SEED
	seed.custom_minimum_size.x = 150
	seed_row.add_child(seed)
	_more.add_child(Widgets.muted("相同种子可复现本地策略开局。", true))
	notice = Widgets.label("", "AccentLabel", true)
	column.add_child(notice)
	launch = Widgets.primary("出阵", _launch)
	launch.name = "LaunchBattleScenario"
	launch.custom_minimum_size.y = Tokens.control("height") + Tokens.space(1)
	column.add_child(launch)
	return_button = Widgets.secondary("返回原战役", _return)
	column.add_child(return_button)
	return panel


## 对阵一行：势力色块 + 名称 + 兵力，我方加小标签。行在建界面时建好，choose 只改文字与颜色。
func _side_row() -> Dictionary:
	var row := Widgets.hbox(1)
	_sides.add_child(row)
	var badge := PanelContainer.new()
	badge.custom_minimum_size = Vector2(28, 28)
	var badge_style := StyleBoxFlat.new()
	badge_style.set_corner_radius_all(Tokens.radius("control") - 2)
	badge.add_theme_stylebox_override("panel", badge_style)
	row.add_child(badge)
	var short := Widgets.label("")
	short.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	short.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	short.add_theme_color_override("font_color", Tokens.color("ink"))
	badge.add_child(short)
	var faction_name := Widgets.label("")
	row.add_child(faction_name)
	var mine := Widgets.caption("我方")
	row.add_child(mine)
	row.add_child(Widgets.spring())
	var strength := Widgets.muted("")
	strength.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(strength)
	return {"style": badge_style, "short": short, "name": faction_name, "mine": mine, "strength": strength}


func choose(id: String) -> void:
	var spec := Scenarios.definition(id)
	if spec.is_empty(): return
	selected = id
	var card: Button = buttons.get(spec["id"])
	if card != null: card.set_pressed_no_signal(true)
	_detail_name.text = str(spec["name"])
	_detail_meta.text = _meta(spec)
	_objective.text = str(spec.get("objective_text", "击溃敌军"))
	var strengths: Dictionary = spec.get("strengths", {"liu_bei": 20000, "yuan_shao": 20000})
	var player := "yuan_shao" if spec["kind"] == "siege" else _player_faction
	var factions: Dictionary = store.scenario.get("factions", {})
	var ids := strengths.keys()
	for i in _side_rows.size():
		var row: Dictionary = _side_rows[i]
		var faction_id: String = str(ids[i]) if i < ids.size() else ""
		var faction: Dictionary = factions.get(faction_id, {})
		(row["style"] as StyleBoxFlat).bg_color = Color.html(str(faction["color"])) if faction.has("color") else Tokens.color("dim")
		row["short"].text = str(faction.get("short", faction_id.left(1)))
		row["name"].text = str(faction.get("name", faction_id))
		row["mine"].visible = faction_id == player
		row["strength"].text = _troops(int(strengths.get(faction_id, 0)))
	var extra: PackedStringArray = []
	if spec["kind"] == "siege": extra.append("城内另有守军 %s，我方攻城。" % _troops(int(spec.get("garrison", 3000))))
	elif spec["kind"] == "combined": extra.append("城内另有守军 %s，援军与城防共同作战。" % _troops(int(spec.get("garrison", 3000))))
	if int(spec.get("engines", 0)) > 0: extra.append("攻城前锋携带 %d 辆攻城兵器。" % int(spec["engines"]))
	_extra.text = "\n".join(extra)
	_extra.visible = not extra.is_empty()


func open(from_startup: bool = false) -> void:
	startup_mode = from_startup
	_shade.color = Tokens.color("ink") if startup_mode else Tokens.color("shade")
	subtitle.text = "八个经典战场，地形、兵种与胜利条件各不相同。" if startup_mode else "独立战场，结束后可返回原战役。"
	close_button.text = "退出" if startup_mode else "关闭"
	return_button.visible = not startup_mode
	launch.text = "开始战斗" if startup_mode else "开始 / 重置此场景"
	var board: Dictionary = store.war.state.get(StateKeys.BATTLEFIELD, {})
	choose(str(board.get("scenario_id", "guandu_clash")))
	seed.value = int(board.get("seed", DEFAULT_SEED))
	notice.text = "请先完成当前推进，再切换场景。" if store.busy else ""
	launch.disabled = store.busy
	surface.show()


func _meta(spec: Dictionary) -> String:
	var ground := Terrain.name_of(str(spec["terrain"])) if spec.has("terrain") else "城池"
	return "%s  ·  %s" % [spec.get("category", ""), ground]


func _troops(count: int) -> String:
	if count < 10000: return "%d 人" % count
	return ("%.1f" % (count / 10000.0)).trim_suffix(".0") + " 万"


func _filter(kind: String) -> void:
	for spec in _specs:
		buttons[spec["id"]].visible = kind.is_empty() or spec["kind"] == kind


func _toggle_more() -> void:
	_more.visible = not _more.visible
	_more_button.text = "更多  ⌄" if _more.visible else "更多  ›"


func _launch() -> void:
	if store.busy:
		notice.text = "请先完成当前推进，再切换场景。"
		return
	surface.hide()
	store.start_battle_test(selected, int(seed.value))


func _return() -> void:
	if store.busy:
		notice.text = "请先完成当前推进。"
		return
	if store.battle_test:
		surface.hide()
		store.leave_battle_test()


func _close() -> void:
	if startup_mode: get_tree().quit()
	else: surface.hide()


func _unhandled_key_input(event: InputEvent) -> void:
	if not startup_mode and surface.visible and event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		surface.hide()
		get_viewport().set_input_as_handled()
