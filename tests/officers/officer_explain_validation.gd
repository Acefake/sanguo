extends SceneTree
## 特色可见性：军报署名找对人和来源；面板理由带来源；人物卡有“适合/吃亏”；模型上下文含核心定义、特性与关系。
##
##   godot --headless --path . --script res://tests/officers/officer_explain_validation.gd

const Explain = preload("res://scripts/officers/officer_explain.gd")
const Process = preload("res://scripts/officers/officer_process.gd")
const Roster = preload("res://scripts/agents/officer_context.gd")

var failures: Array[String] = []


func check(value: bool, message: String) -> void:
	if not value:
		failures.append(message)
		push_error(message)


func _initialize() -> void:
	var cards: Array = JSON.parse_string(FileAccess.get_file_as_string("res://data/officers.json"))
	var roster := Roster.new()
	roster.setup(cards, {})
	var by_name := {}
	for officer in roster.officers.values(): by_name[officer["name"]] = officer

	var yan: Dictionary = by_name["颜良"]
	var wen: Dictionary = by_name["文丑"]
	var tian: Dictionary = by_name["田丰"]
	var zhang: Dictionary = by_name["张郃"]
	var line := Explain.signed(wen, "pursuit深入", "越过退路追击，反被截击")
	check(line == "文丑穷追：越过退路追击，反被截击", "局限特性署名：" + line)
	check(Explain.signed(zhang, "intel误差", "识破林中伏兵", {"independent_groups": 3, "cross_checked": true}) == "张郃多源研判：识破林中伏兵", "特性优先于属性署名")
	var plain_tian := tian.duplicate(true)
	plain_tian["trait_ids"] = []
	check(Explain.signed(plain_tian, "ambush识破", "识破林中伏兵") == "田丰料敌：识破林中伏兵", "无特性时按高属性署名（GDD 名）")
	check(Explain.signed(by_name["淳于琼"], "ambush识破", "识破林中伏兵") == "识破林中伏兵", "属性不够高不署名")
	check(Explain.signed(yan, "commit投入", "未等侧翼就位便投入").begins_with("颜良急躁："), "急躁署名")

	var army := {"name": "颜良", "units": {"infantry": 3000, "archers": 0, "cavalry": 3000}, "skills": yan["skills"], "trait_ids": yan["trait_ids"], "action": {"type": "engage"}}
	Process.issue_order(army, {"terrain": "plains"})
	var panel := Explain.intent(army, {}, yan)
	var sources := {}
	for reason in panel["reasons"]: sources[reason["source"]] = true
	check(panel["intent"] == "正面接战" and panel["phase"] == "整理命令", "面板意图与阶段")
	check(sources.has("属性") and sources.has("特性"), "面板理由同时标出属性与特性来源：%s" % str(panel["reasons"]))
	check(panel["reasons"].size() <= 3 and not panel["abort"].is_empty(), "理由不超过 3 条且有放弃条件")
	print("EXPLAIN 面板示例：\n" + Explain.intent_text(army, {}, yan))

	for officer in roster.officers.values():
		var summary := Explain.card(officer)
		check(not summary["suits"].is_empty() and not summary["weak"].is_empty(), "%s 人物卡应有适合与吃亏两面" % officer["name"])
	var profile := Explain.model_profile(by_name["曹操"], roster.officers.values())
	check(not str(profile["core"]).is_empty() and profile["traits"].size() == 3, "模型上下文含核心定义与 3 个特性")
	check(profile["traits"].any(func(t): return t["name"] == "过度负责"), "模型上下文含局限特性")
	var relations: Array = Explain.model_profile(by_name["袁绍"], roster.officers.values())["relations"]
	check(relations.any(func(r): return r["name"] == "审配" and r["relation"] == "同袍"), "关系来自人物卡有向边：袁绍→审配 信任78")
	print("EXPLAIN 袁绍与同僚关系（卡面有向边）：%s" % str(relations.map(func(r): return "%s%s" % [r["name"], r["relation"]])))
	print("OFFICER_EXPLAIN_VALIDATION: " + ("PASS" if failures.is_empty() else "FAIL " + str(failures)))
	quit(0 if failures.is_empty() else 1)
