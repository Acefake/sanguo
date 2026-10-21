extends VBoxContainer

signal close_requested
signal orders_requested(id: String)
signal reports_requested(id: String)
const Explain = preload("res://scripts/officers/officer_explain.gd")
const UISkin = preload("res://scripts/war/ui/war_ui_skin.gd")
const CommandRoles = preload("res://scripts/war/campaign/army_command_roles.gd")
var store: Node
var army_id := ""
var portrait: TextureRect
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
var portrait_paths: Dictionary = {}
var report_button: Button
var plaque: Control
var attribute_labels: Dictionary = {}
var card_morale: Control
var card_morale_value := 0.0
var card_morale_number: Label

func _ready() -> void:
	name = "ArmyInspector"
	add_theme_constant_override("separation", 0)
	portrait_paths = JSON.parse_string(FileAccess.get_file_as_string("res://data/officer_portraits.json"))
	var hero := Control.new()
	hero.custom_minimum_size.y = 250
	hero.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(hero)
	portrait = TextureRect.new()
	portrait.position = Vector2(13, 0)
	portrait.size = Vector2(290, 245)
	portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	portrait.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hero.add_child(portrait)
	var close := UISkin.button("×", func(): close_requested.emit(), true)
	close.position = Vector2(297, 0)
	close.size = Vector2(26, 26)
	hero.add_child(close)
	plaque = preload("res://scripts/war/ui/army_card_plaque.gd").new()
	plaque.position = Vector2(0, 160)
	plaque.size = Vector2(334, 90)
	plaque.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hero.add_child(plaque)
	officer_name = UISkin.label("", 17)
	officer_name.add_theme_font_override("font", UISkin.CitySkin.font())
	officer_name.position = Vector2(33, 166)
	officer_name.size = Vector2(158, 24)
	hero.add_child(officer_name)
	mission = UISkin.label("", 12, UISkin.MUTED)
	var status_panel := PanelContainer.new()
	status_panel.add_theme_stylebox_override("panel", UISkin.CitySkin.dark_panel(0.9, 4))
	status_panel.position = Vector2(8, 137)
	status_panel.size = Vector2(102, 23)
	hero.add_child(status_panel)
	mission.add_theme_color_override("font_color", Color("ede0bb"))
	status_panel.add_child(mission)
	troop_count = UISkin.label("", 19)
	troop_count.position = Vector2(33, 190)
	troop_count.size = Vector2(62, 24)
	hero.add_child(troop_count)
	unit_type = UISkin.label("", 12, UISkin.MUTED)
	unit_type.position = Vector2(99, 195)
	unit_type.size = Vector2(95, 20)
	hero.add_child(unit_type)
	for spec in [["武艺", Vector2(237, 165), Vector2(58, 18)], ["智计", Vector2(202, 198), Vector2(43, 18)], ["带兵", Vector2(281, 198), Vector2(43, 18)], ["布阵", Vector2(237, 229), Vector2(58, 18)]]:
		var item := UISkin.label("", 11, UISkin.MUTED)
		item.autowrap_mode = TextServer.AUTOWRAP_OFF
		item.position = spec[1]
		item.size = spec[2]
		item.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		hero.add_child(item)
		attribute_labels[spec[0]] = item
	var morale_caption := UISkin.label("士气", 11, UISkin.MUTED)
	morale_caption.position = Vector2(13, 224)
	morale_caption.size = Vector2(28, 18)
	hero.add_child(morale_caption)
	card_morale = Control.new()
	card_morale.position = Vector2(45, 232)
	card_morale.size = Vector2(128, 4)
	card_morale.mouse_filter = MOUSE_FILTER_IGNORE
	card_morale.draw.connect(func():
		card_morale.draw_rect(Rect2(Vector2.ZERO, card_morale.size), Color("d4c9ae"))
		card_morale.draw_rect(Rect2(Vector2.ZERO, Vector2(128 * clampf(card_morale_value / 100.0, 0, 1), 4)), UISkin.GREEN)
	)
	hero.add_child(card_morale)
	card_morale_number = UISkin.label("", 11)
	card_morale_number.position = Vector2(178, 224)
	card_morale_number.size = Vector2(24, 18)
	hero.add_child(card_morale_number)
	var sheet := UISkin.framed_panel(16)
	add_child(sheet)
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 10)
	sheet.add_child(body)
	var info := VBoxContainer.new()
	body.add_child(info)
	info.add_theme_constant_override("separation", 6)
	var resources := HBoxContainer.new()
	info.add_child(resources)
	wounded = UISkin.label("")
	grain = UISkin.label("")
	grain.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	resources.add_child(wounded)
	resources.add_child(grain)
	for spec in [["士气", "morale", UISkin.GREEN], ["组织", "organization", Color("648793")], ["疲劳", "fatigue", UISkin.GOLD]]:
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
	target = UISkin.label("", 12)
	task = UISkin.label("", 12, UISkin.MUTED)
	info.add_child(target)
	info.add_child(task)
	personnel = UISkin.label("", 12)
	personnel.name = "CorpsPersonnel"
	info.add_child(personnel)
	command_personnel = UISkin.label("", 11)
	command_personnel.name = "CommandRoles"
	info.add_child(command_personnel)
	UISkin.rule(body)
	var thought := UISkin.section(body, "临机判断")
	source = UISkin.label("", 11, UISkin.MUTED)
	thought.add_child(source)
	judgment = UISkin.label("", 13)
	judgment.name = "DecisionSummary"
	judgment.max_lines_visible = 3
	thought.add_child(judgment)
	expand_button = UISkin.button("展开判断", func():
		expanded = not expanded
		judgment.max_lines_visible = -1 if expanded else 3
		expand_button.text = "收起判断" if expanded else "展开判断"
	)
	expand_button.size_flags_horizontal = SIZE_SHRINK_END
	thought.add_child(expand_button)
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 7)
	UISkin.rule(body)
	body.add_child(actions)
	var order_button := UISkin.button("军令", func(): orders_requested.emit(army_id))
	order_button.name = "OpenArmyOrders"
	order_button.size_flags_horizontal = SIZE_EXPAND_FILL
	actions.add_child(order_button)
	report_button = UISkin.button("军报  ›", func(): reports_requested.emit(army_id), true)
	report_button.name = "OpenArmyReports"
	report_button.size_flags_horizontal = SIZE_EXPAND_FILL
	actions.add_child(report_button)
	update_info()

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
	if not is_instance_valid(portrait): return
	var army: Dictionary = store.war.state["armies"].get(army_id, {})
	if army.is_empty(): return
	var card: Dictionary = store.war.roster.officers.get(army["officer_id"], {})
	var path := str(portrait_paths.get(card.get("name", ""), {}).get("portrait", ""))
	if portrait.get_meta("path", "") != path:
		portrait.texture = load(path) if FileAccess.file_exists(path) else null
		portrait.set_meta("path", path)
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
	wounded.text = "伤兵 %d\n主将杀敌 %d   部队杀敌 %d" % [int(army["wounded"]), int(store.war.state["officer_personal_kills"].get(army["officer_id"], 0)), int(army.get("enemy_killed", 0)) - int(army.get("personal_soldier_kills", 0))]
	grain.visible = store.war.supply_enabled()
	grain.text = "余粮  约%d日" % int(float(army["grain"]) / maxf(store.war.daily_food(army), 0.001))
	for key in bars:
		bars[key].value = float(army[key])
		numbers[key].text = str(int(army[key]))
		var danger: bool = float(army[key]) > 80 if key == "fatigue" else float(army[key]) < 30
		numbers[key].add_theme_color_override("font_color", UISkin.RED if danger else UISkin.INK)
	target.text = "目标  " + store.war.graph.name_of(str(army["target"]))
	var corps: Dictionary = store.war.state["corps"].get(army.get("corps_id", ""), {})
	wounded.tooltip_text = "战斗主将：%s\n军团主帅：%s\n主将杀敌：亲自击杀士兵或单挑斩将。\n部队杀敌：士兵造成的实际阵亡，不含主将击杀、伤兵和俘虏。" % [card.get("name", "无"), store.war.roster.officers.get(corps.get("commander_id", ""), {}).get("name", "无")]
	wounded.mouse_filter = MOUSE_FILTER_PASS
	var terrain: String = store.war.Terrain.name_of(store.war.Tactical.terrain_class(army["tactical"]["cell"])) if army.has("tactical") else "行军途中"
	task.text = "%s  %s" % [terrain, army.get("tactical", {}).get("phase", "待命")]
	task.text += "\n主将 %s  主帅 %s" % [card.get("name", "无"), store.war.roster.officers.get(corps.get("commander_id", ""), {}).get("name", "无")]
	if army.has("autonomy") and str(army["autonomy"].get("stance", "obey")) != "obey":
		task.text += "\n独立立场 %s：%s" % [preload("res://scripts/agents/officer_autonomy.gd").label(str(army["autonomy"]["stance"])), str(army["autonomy"].get("reason", ""))]
	var command_roles := CommandRoles.resolve(store.war, army)
	command_personnel.visible = command_roles["enabled"]
	command_personnel.text = CommandRoles.role_text(command_roles["commander"], "主将") + "\n" + CommandRoles.role_text(command_roles["deputy"], "副将")
	command_personnel.tooltip_text = "主将沿用现有指挥权限；副将随军展示，不新增岗位或指挥增益。"
	personnel.visible = not corps.is_empty()
	personnel.text = "军团编制（自由编组）\n" + personnel_text(store.war, corps) if not corps.is_empty() else ""
	if not corps.is_empty():
		for advice in preload("res://scripts/agents/officer_brain.gd").advice(store.war,corps):
			var stance := str(advice.get("stance", ""))
			var suffix := "（独立立场：%s）" % preload("res://scripts/agents/officer_autonomy.gd").label(stance) if stance not in ["", "obey"] else ""
			personnel.text += "\n%s%s：%s" % [advice["name"], suffix, advice["reason"]]
	if army.has("commander_fate"):
		task.text += "\n%s%s" % [army["commander_fate"]["name"], "战死" if army["commander_fate"]["status"] == "dead" else "被俘"]
	var result := decision(store.war, army)
	judgment.text = preload("res://scripts/ui/ui_text.gd").clean(str(result["text"])) if not str(result["text"]).is_empty() else "尚未返回新的判断。"
	judgment.text += "\n" + Explain.intent_text(army, {"terrain": store.war.Tactical.terrain_class(army["tactical"]["cell"]) if army.has("tactical") else "plains"}, card)
	judgment.tooltip_text = judgment.text
	var origin := "智能体返回" if result["source"] == "model" else "当前军令" if result["source"] == "orders" else "本地策略"
	if army.has("battle_ai") and not army["battle_ai"].get("plan",{}).is_empty(): origin = {"model":"部将模型建议","safety":"部将安全反应","coordination":"军团配合调整"}.get(result["source"],"部将本地判断")
	elif not corps.is_empty(): origin = "主帅" + origin
	var state := "待执行" if result["pending"] else "已下达" if result.get("applied", true) else "未执行"
	source.text = "%s%s  %s" % [origin, "  第%d日" % int(result["tick"]) if int(result["tick"]) >= 0 else "", state]
	if result.get("thinking", false): source.text += "  正在推演"
	expand_button.visible = judgment.text.length() > 52
