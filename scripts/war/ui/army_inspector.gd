extends VBoxContainer

signal close_requested
## 旧宿主的跳转信号；卡底按钮已删（抽屉分页「军令 / 战报」负责切换），信号保留不发。
signal orders_requested(id: String)
signal reports_requested(id: String)
const UISkin = preload("res://scripts/war/ui/war_ui_skin.gd")
const Widgets = preload("res://scripts/ui/theme/ui_widgets.gd")
const CommandRoles = preload("res://scripts/war/campaign/army_command_roles.gd")
var store: Node
var army_id := ""
var officer_name: Label
var mission: Label
var troop_count: Label
var unit_type: Label
var grain: Label
var wounded: Label
var target: Label
var task: Label
var personnel: Label
var command_personnel: Label
var bars: Dictionary = {}
var numbers: Dictionary = {}
var judgment: Label
var source: Label
var expanded := false
var expand_button: Button
var plaque: Control
var attribute_labels: Dictionary = {}
var card_morale: Control
var card_morale_value := 0.0
var card_morale_number: Label

## 名牌卡高度：任务签 23 + 名牌 90。主将头像在抽屉抬头（side_drawer.set_avatar），这里不再留头像区。
const CARD_HEIGHT := 113
var hero: Control
var card_layer: Control
var personnel_button: Button
var personnel_expanded := false


func _ready() -> void:
	name = "ArmyInspector"
	add_theme_constant_override("separation", 8)
	hero = Control.new()
	hero.custom_minimum_size.y = CARD_HEIGHT
	hero.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(hero)
	# 名牌卡里的坐标都相对卡顶（任务签顶边）。
	card_layer = Control.new()
	card_layer.size = Vector2(334, CARD_HEIGHT)
	card_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hero.add_child(card_layer)
	# 关闭由所在抽屉的抬头负责（「关闭」文字钮）；名牌上不再叠第二个关闭钮。close_requested 保留给其他宿主。
	plaque = preload("res://scripts/war/ui/army_card_plaque.gd").new()
	plaque.position = Vector2(0, 23)
	plaque.size = Vector2(334, 90)
	plaque.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card_layer.add_child(plaque)
	officer_name = UISkin.label("", 17)
	officer_name.add_theme_font_override("font", UISkin.CitySkin.font())
	officer_name.position = Vector2(33, 29)
	officer_name.size = Vector2(158, 24)
	card_layer.add_child(officer_name)
	mission = UISkin.label("", 12, UISkin.MUTED)
	var status_panel := PanelContainer.new()
	status_panel.add_theme_stylebox_override("panel", UISkin.CitySkin.dark_panel(0.9, 4))
	status_panel.position = Vector2(8, 0)
	status_panel.size = Vector2(102, 23)
	card_layer.add_child(status_panel)
	mission.add_theme_color_override("font_color", Color("ede0bb"))
	status_panel.add_child(mission)
	troop_count = UISkin.label("", 19)
	troop_count.position = Vector2(33, 53)
	troop_count.size = Vector2(62, 24)
	card_layer.add_child(troop_count)
	unit_type = UISkin.label("", 12, UISkin.MUTED)
	unit_type.position = Vector2(99, 58)
	unit_type.size = Vector2(95, 20)
	card_layer.add_child(unit_type)
	# 四项属性围着名牌右侧的菱形；布阵上提，离开名牌底边与底部细线。
	for spec in [["武艺", Vector2(237, 28), Vector2(58, 18)], ["智计", Vector2(202, 61), Vector2(43, 18)], ["带兵", Vector2(281, 61), Vector2(43, 18)], ["布阵", Vector2(237, 88), Vector2(58, 18)]]:
		var item := UISkin.label("", 11, UISkin.MUTED)
		item.autowrap_mode = TextServer.AUTOWRAP_OFF
		item.position = spec[1]
		item.size = spec[2]
		item.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		card_layer.add_child(item)
		attribute_labels[spec[0]] = item
	var morale_caption := UISkin.label("士气", 11, UISkin.MUTED)
	morale_caption.position = Vector2(13, 87)
	morale_caption.size = Vector2(28, 18)
	card_layer.add_child(morale_caption)
	card_morale = Control.new()
	card_morale.position = Vector2(45, 95)
	card_morale.size = Vector2(128, 4)
	card_morale.mouse_filter = MOUSE_FILTER_IGNORE
	card_morale.draw.connect(func():
		card_morale.draw_rect(Rect2(Vector2.ZERO, card_morale.size), Color("d4c9ae"))
		card_morale.draw_rect(Rect2(Vector2.ZERO, Vector2(128 * clampf(card_morale_value / 100.0, 0, 1), 4)), UISkin.GREEN)
	)
	card_layer.add_child(card_morale)
	card_morale_number = UISkin.label("", 11)
	card_morale_number.position = Vector2(178, 87)
	card_morale_number.size = Vector2(24, 18)
	card_layer.add_child(card_morale_number)
	_ink_plaque_labels(card_layer, mission)
	# 数据卡：随所在抽屉的主题（地图上是浅色 glass 卡片），不再垫深色底板。
	var sheet := Widgets.card()
	add_child(sheet)
	var body := Widgets.vbox(1)
	sheet.add_child(body)
	var info := VBoxContainer.new()
	body.add_child(info)
	info.add_theme_constant_override("separation", 4)
	wounded = Widgets.label("", "NoteLabel")
	info.add_child(wounded)
	# 士气已在名牌上（细条 + 数值），数据卡只列组织与疲劳，不重复。
	for spec in [["组织", "organization", Color("648793")], ["疲劳", "fatigue", UISkin.GOLD]]:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		info.add_child(row)
		var caption := UISkin.label(spec[0], 12, UISkin.MUTED)
		caption.custom_minimum_size.x = 28
		caption.size_flags_horizontal = SIZE_SHRINK_BEGIN
		row.add_child(caption)
		var bar := ProgressBar.new()
		bar.custom_minimum_size = Vector2(0, 5)
		bar.size_flags_horizontal = SIZE_EXPAND_FILL
		bar.size_flags_vertical = SIZE_SHRINK_CENTER
		bar.show_percentage = false
		var track := StyleBoxFlat.new()
		track.bg_color = Color("d9d0bb")
		var fill := StyleBoxFlat.new()
		fill.bg_color = spec[2]
		bar.add_theme_stylebox_override("background", track)
		bar.add_theme_stylebox_override("fill", fill)
		row.add_child(bar)
		var number := UISkin.label("", 12)
		number.custom_minimum_size.x = 27
		number.size_flags_horizontal = SIZE_SHRINK_END
		number.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		row.add_child(number)
		bars[spec[1]] = bar
		numbers[spec[1]] = number
	# 目标与余粮同一行：目标靠左，余粮靠右。
	var target_row := Widgets.hbox(1)
	info.add_child(target_row)
	# 同行的标签不自动换行：HBox 里自动换行的 Label 会按极窄宽度算出很高的最小高度。
	target = Widgets.label("", "NoteLabel")
	target.size_flags_horizontal = SIZE_EXPAND_FILL
	target.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	target_row.add_child(target)
	grain = Widgets.label("", "MutedLabel")
	grain.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	target_row.add_child(grain)
	task = UISkin.label("", 12, UISkin.MUTED)
	info.add_child(task)
	# 军团编制默认只露一行（标题），右侧「展开编制」；展开后整段换行显示（军令页也有完整编制）。
	var personnel_row := Widgets.hbox(1)
	info.add_child(personnel_row)
	personnel = Widgets.label("", "NoteLabel")
	personnel.name = "CorpsPersonnel"
	personnel.size_flags_horizontal = SIZE_EXPAND_FILL
	personnel.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	personnel.max_lines_visible = 1
	personnel_row.add_child(personnel)
	personnel_button = Widgets.text_button("展开编制", func():
		personnel_expanded = not personnel_expanded
		personnel.max_lines_visible = -1 if personnel_expanded else 1
		personnel.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART if personnel_expanded else TextServer.AUTOWRAP_OFF
		personnel_button.text = "收起编制" if personnel_expanded else "展开编制"
	)
	personnel_button.size_flags_vertical = SIZE_SHRINK_BEGIN
	personnel_row.add_child(personnel_button)
	command_personnel = Widgets.label("", "NoteLabel")
	command_personnel.name = "CommandRoles"
	command_personnel.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	command_personnel.mouse_filter = MOUSE_FILTER_PASS
	info.add_child(command_personnel)
	var thought := UISkin.section(body, "临机判断")
	# 来源一行右侧放「展开判断」文字钮，不再单独占一行；军令、战报由抽屉分页切换，卡底不再重复两个按钮。
	var source_row := Widgets.hbox(1)
	thought.add_child(source_row)
	source = Widgets.label("", "MutedLabel")
	source.size_flags_horizontal = SIZE_EXPAND_FILL
	source.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	source.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	source_row.add_child(source)
	judgment = UISkin.label("", 13)
	judgment.name = "DecisionSummary"
	judgment.max_lines_visible = 3
	thought.add_child(judgment)
	expand_button = Widgets.text_button("展开判断", func():
		expanded = not expanded
		judgment.max_lines_visible = -1 if expanded else 3
		expand_button.text = "收起判断" if expanded else "展开判断"
	)
	expand_button.size_flags_vertical = SIZE_SHRINK_CENTER
	source_row.add_child(expand_button)
	update_info()


static var _portraits: Dictionary


## 主将头像：优先头部裁切缩略图（thumbnail），没有再用半身像；都没有返回 null。
static func avatar_texture(store_node: Node, army: Dictionary) -> Texture2D:
	if _portraits.is_empty():
		_portraits = JSON.parse_string(FileAccess.get_file_as_string("res://data/officer_portraits.json"))
	var card: Dictionary = store_node.war.roster.officers.get(army.get("officer_id", ""), {})
	var entry: Dictionary = _portraits.get(card.get("name", ""), {})
	for key in ["thumbnail", "portrait"]:
		var path := str(entry.get(key, ""))
		if not path.is_empty() and ResourceLoader.exists(path): return load(path)
	return null


static func personnel_text(war, corps: Dictionary) -> String:
	var structure := preload("res://scripts/war/campaign/corps_structure.gd")
	structure.ensure(corps)
	var rows: Array = structure.tree_rows(corps)
	var lines: Array[String] = []
	for row in rows:
		var id := str(row["id"])
		var officer: Dictionary = war.roster.officers.get(id, {})
		if officer.is_empty(): continue
		var role := str(corps.get("appointments", {}).get(id, "随军"))
		var strength := int(corps.get("node_strength", {}).get(id, 0))
		var depth := int(row["depth"])
		var prefix := ""
		for index in range(depth): prefix += "└ "
		var suffix := "  %d人" % strength if strength > 0 else ""
		lines.append("%s%s %s%s" % [prefix, role, officer.get("name", id), suffix])
	var autonomy := preload("res://scripts/agents/officer_autonomy.gd")
	var stances: Array[String] = []
	for row in autonomy.summary_rows(war, corps):
		if str(row["stance"]) == "obey": continue
		stances.append("%s：%s（%s）" % [row["name"], autonomy.label(str(row["stance"])), row["reason"]])
	if not stances.is_empty(): lines.append("独立立场：" + "；".join(stances))
	return "\n".join(lines)

static func decision(war, army: Dictionary) -> Dictionary:
	if army.has("battle_ai") and not army["battle_ai"].get("plan",{}).is_empty():
		var ai: Dictionary = army["battle_ai"]
		var plan: Dictionary = ai["plan"]
		var phase := str({"approach":"接近","execute":"执行","wait_support":"等待正面配合","disengage":"准备脱离","reposition":"前往接应位置","recover":"整顿恢复","rejoin":"准备重新投入"}.get(plan.get("stage",""),"执行"))
		var text := "%s · %s\n%s\n下一步：%s\n改判：%s" % [plan["label"],phase,army.get("last_reason",""),plan.get("next",""),plan.get("stop_condition","")]
		return {"text":text,"source":ai.get("last_source","baseline"),"tick":int(ai.get("submitted_round",-1)),"pending":false,"applied":true,"thinking":war.planner.has_pending("unit:"+str(army["id"]))}
	var corps: Dictionary = war.state["corps"].get(army.get("corps_id", ""), {})
	var key := "army:" + str(army["id"]) if corps.is_empty() else "corps:" + str(corps["id"])
	if war.planner.ready.has(key):
		var proposal: Dictionary = war.planner.ready[key]
		var result: Dictionary = proposal["result"]
		return {"text": str(result.get("reason_summary", "等待有效建议")), "source": result.get("source", "baseline"), "tick": proposal["tick"], "pending": true}
	var orders: Array = corps.get("orders", [])
	var history: Array = army.get("decision_history", [])
	var latest: Dictionary = {}
	if not orders.is_empty():
		var order: Dictionary = orders[-1]
		latest = {"text": order.get("reason", ""), "source": order.get("source", "baseline"), "tick": order["tick"], "pending": false, "applied": order.get("applied", {}).get("ok", false)}
	if not history.is_empty() and (latest.is_empty() or int(history[-1]["tick"]) > int(latest["tick"])):
		var item: Dictionary = history[-1]
		latest = {"text": item.get("reason_summary", ""), "source": item.get("source", "baseline"), "tick": item["tick"], "pending": false, "applied": true}
	if latest.is_empty(): latest = {"text": army.get("last_reason", "尚未返回新的判断"), "source": "orders", "tick": -1, "pending": false}
	latest["thinking"] = war.planner.requested.has(key)
	return latest

func update_info() -> void:
	if not is_instance_valid(card_layer): return
	var army: Dictionary = store.war.state["armies"].get(army_id, {})
	if army.is_empty(): return
	var card: Dictionary = store.war.roster.officers.get(army["officer_id"], {})
	officer_name.text = str(army["name"])
	mission.text = "已结束" if army["status"] == "ended" else "撤往友城" if army["returning"] else str(store.war.Corps.TASKS.get(army.get("corps_task", {}).get("type", ""), "待命"))
	troop_count.text = str(store.war.Combat.strength(army))
	var types := {"infantry": "步兵", "archers": "弓兵", "cavalry": "骑兵"}
	var entries := PackedStringArray()
	for kind in types:
		if int(army["units"].get(kind, 0)) > 0: entries.append(types[kind])
	unit_type.text = entries[0] if entries.size() == 1 else "混编部队"
	if int(army.get("siege_engines",0)) > 0: unit_type.text += "  攻城兵器%d" % int(army["siege_engines"])
	unit_type.tooltip_text = "带兵%d  布阵%d  治军%d\n训练%d  军备%d" % [army["skills"].get("带兵", 50), army["skills"].get("布阵", 50), army["skills"].get("治军", 50), army["training"], army["equipment"]]
	var roles = preload("res://scripts/war/battle/troop_roles.gd")
	var traits: Dictionary = roles.traits(store.war.rules).get(roles.kind(army),{})
	unit_type.tooltip_text += "\n"+str(traits.get("role",""))
	if roles.kind(army) == "cavalry": unit_type.tooltip_text += "\n平原移动1.5格/日  森林0.75格/日  山地0.6格/日\n平原接近后冲击进攻提高20%"
	elif roles.kind(army) == "archers": unit_type.tooltip_text += "\n射程2格  贴身进攻为45%  近战承伤增加20%"
	if roles.engine_count(army) > 0: unit_type.tooltip_text += "\n兵器随队推进最多0.7格/日"
	unit_type.mouse_filter = MOUSE_FILTER_PASS
	for key in attribute_labels: attribute_labels[key].text = "%s%d" % [key, int(army["skills"].get(key, 50))]
	card_morale_value = float(army["morale"])
	card_morale.queue_redraw()
	card_morale_number.text = str(int(army["morale"]))
	var faction: Dictionary = store.scenario["factions"].get(army["faction"], {})
	plaque.badge = str(faction.get("name", "军")).left(1)
	plaque.queue_redraw()
	wounded.text = "伤兵 %d  ·  主将杀敌 %d  ·  部队杀敌 %d" % [int(army["wounded"]), int(store.war.state["officer_personal_kills"].get(army["officer_id"], 0)), int(army.get("enemy_killed", 0)) - int(army.get("personal_soldier_kills", 0))]
	grain.visible = store.war.supply_enabled()
	grain.text = "余粮  约%d日" % int(float(army["grain"]) / maxf(store.war.daily_food(army), 0.001))
	for key in bars:
		bars[key].value = float(army[key])
		numbers[key].text = str(int(army[key]))
		var danger: bool = float(army[key]) > 80 if key == "fatigue" else float(army[key]) < 30
		# 危险值标红（取所在主题的强调色），其余跟随主题正文色。
		if danger: numbers[key].add_theme_color_override("font_color", get_theme_color("accent", "Tokens"))
		else: numbers[key].remove_theme_color_override("font_color")
	target.text = "目标  " + store.war.graph.name_of(str(army["target"]))
	var corps: Dictionary = store.war.state["corps"].get(army.get("corps_id", ""), {})
	wounded.tooltip_text = "战斗主将：%s\n军团主帅：%s\n主将杀敌：亲自击杀士兵或单挑斩将。\n部队杀敌：士兵造成的实际阵亡，不含主将击杀、伤兵和俘虏。" % [card.get("name", "无"), store.war.roster.officers.get(corps.get("commander_id", ""), {}).get("name", "无")]
	wounded.mouse_filter = MOUSE_FILTER_PASS
	var terrain: String = store.war.Terrain.name_of(store.war.Tactical.terrain_class(army["tactical"]["cell"])) if army.has("tactical") else "行军途中"
	# 目标一行带上地形与阶段；任务行只留主将 / 主帅（与独立立场、主将下落）。
	target.text += "  ·  %s  %s" % [terrain, army.get("tactical", {}).get("phase", "待命")]
	target.tooltip_text = target.text
	task.text = "主将 %s  主帅 %s" % [card.get("name", "无"), store.war.roster.officers.get(corps.get("commander_id", ""), {}).get("name", "无")]
	if army.has("autonomy") and str(army["autonomy"].get("stance", "obey")) != "obey":
		task.text += "\n独立立场 %s：%s" % [preload("res://scripts/agents/officer_autonomy.gd").label(str(army["autonomy"]["stance"])), str(army["autonomy"].get("reason", ""))]
	var command_roles := CommandRoles.resolve(store.war, army)
	command_personnel.visible = command_roles["enabled"]
	# 主将 / 副将并成一行（超长省略，悬停看全文），概况页不为它多占一行。
	command_personnel.text = CommandRoles.role_text(command_roles["commander"], "主将") + "  ·  " + CommandRoles.role_text(command_roles["deputy"], "副将")
	command_personnel.tooltip_text = command_personnel.text + "\n主将沿用现有指挥权限；副将随军展示，不新增岗位或指挥增益。"
	personnel.visible = not corps.is_empty()
	personnel.text = "军团编制（自由编组）\n" + personnel_text(store.war, corps) if not corps.is_empty() else ""
	if not corps.is_empty():
		for advice in preload("res://scripts/agents/officer_brain.gd").advice(store.war,corps):
			var stance := str(advice.get("stance", ""))
			var suffix := "（独立立场：%s）" % preload("res://scripts/agents/officer_autonomy.gd").label(stance) if stance not in ["", "obey"] else ""
			personnel.text += "\n%s%s：%s" % [advice["name"], suffix, advice["reason"]]
	personnel_button.visible = personnel.visible and personnel.text.count("\n") >= 1
	if army.has("commander_fate"):
		task.text += "\n%s%s" % [army["commander_fate"]["name"], "战死" if army["commander_fate"]["status"] == "dead" else "被俘"]
	var result := decision(store.war, army)
	judgment.text = preload("res://scripts/ui/ui_text.gd").clean(str(result["text"])) if not str(result["text"]).is_empty() else "尚未返回新的判断。"
	judgment.tooltip_text = judgment.text
	var origin := "智能体返回" if result["source"] == "model" else "当前军令" if result["source"] == "orders" else "本地策略"
	if army.has("battle_ai") and not army["battle_ai"].get("plan",{}).is_empty(): origin = {"model":"部将模型建议","safety":"部将安全反应","coordination":"军团配合调整"}.get(result["source"],"部将本地判断")
	elif not corps.is_empty(): origin = "主帅" + origin
	var state := "待执行" if result["pending"] else "已下达" if result.get("applied", true) else "未执行"
	source.text = "%s%s  %s" % [origin, "  第%d日" % int(result["tick"]) if int(result["tick"]) >= 0 else "", state]
	if result.get("thinking", false): source.text += "  正在推演"
	expand_button.visible = judgment.text.length() > 52


## 名牌仍画在羊皮纸贴图上，而界面主题的文字是浅色：名牌上的字改用墨色（小字用淡墨），保证对比度。
## 任务标签坐在深色底条上，保持浅色。
static func _ink_plaque_labels(hero: Control, keep: Label) -> void:
	for child in hero.get_children():
		if not child is Label or child == keep: continue
		var small: bool = child.theme_type_variation in ["MutedLabel", "NoteLabel", "CaptionLabel"]
		child.add_theme_color_override("font_color", Color(UISkin.CitySkin.INK, 0.72) if small else UISkin.CitySkin.INK)
