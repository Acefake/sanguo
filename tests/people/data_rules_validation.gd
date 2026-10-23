extends SceneTree
## 人物数据校验规则：官渡真实数据（卡、前史事件、规则表）零 error、零 warning；每条规则在坏数据上都会报出来
## （含 v1.1 新增：词条库、faction_id 与关系边、宗族圈、事件目录 / 衰减档 / 关系规则 / 心志来源互相覆盖）；
## R1 在 scripts/ 下零命中、在含人名的探针文件上命中。
##
##   godot --headless --path . --script res://tests/people/data_rules_validation.gd

const Repository = preload("res://scripts/officers/officer_repository.gd")
const Migrate = preload("res://scripts/people/card_migrate.gd")
const Store = preload("res://scripts/people/person_store.gd")
const Validation = preload("res://scripts/people/people_validation.gd")

const PROBE_DIR := "user://people_r1_probe"

var failures: Array[String] = []
var cards: Array = []
var refs: Dictionary = {}


func check(value: bool, message: String) -> void:
	if not value:
		failures.append(message)
		push_error(message)


## 改坏一份规则表后核对三表覆盖，应出现含 expected 的 error。
func expect_table_error(memory_rules: Dictionary, drives: Dictionary, relation_rules: Dictionary, mutate: Callable, expected: String) -> void:
	var m := memory_rules.duplicate(true)
	var d := drives.duplicate(true)
	var r := relation_rules.duplicate(true)
	mutate.call(m, d, r)
	var errors: Array = Validation.check_rule_tables(m, d, r)["errors"]
	check(errors.any(func(line): return str(line).contains(expected)), "应报「%s」，实际 %s" % [expected, str(errors)])


## 改坏第 index 张卡后校验，应出现含 expected 的 error。
func expect_error(index: int, mutate: Callable, expected: String) -> void:
	var broken := cards.duplicate(true)
	mutate.call(broken[index])
	var errors: Array = Validation.check_cards(broken, refs)["errors"]
	check(errors.any(func(line): return str(line).contains(expected)), "应报「%s」，实际 %s" % [expected, str(errors)])


func _initialize() -> void:
	refs = Validation.load_refs()
	var offstage: Array = refs["offstage"].values()
	cards = Migrate.migrate_all(Repository.cards(), Store.read_json(Store.DATA_DIR + "guandu/persons_s7.json"))
	var memory_rules: Dictionary = Store.read_json(Store.DATA_DIR + "memory_rules.json")
	var relation_rules: Dictionary = Store.read_json(Store.DATA_DIR + "relation_rules.json")
	var events: Array = Store.read_json(Store.DATA_DIR + "guandu/seed_events.json")["events"]
	var people_ids: Array = cards.map(func(c): return c["id"]) + refs["offstage"].keys()
	var catalog := Validation.catalog_kinds(memory_rules)

	for report in [Validation.check_cards(cards, refs), Validation.check_seed_events(events, people_ids, refs["cities"], catalog),
			Validation.check_rule_tables(memory_rules, refs["drives"], relation_rules)]:
		check(report["errors"].is_empty() and report["warnings"].is_empty(), "官渡数据应零 error、零 warning：%s %s" % [str(report["errors"]), str(report["warnings"])])

	expect_error(0, func(c): c["drives"] = [{"id": "功名", "weight": 0.5}], "权重和")
	expect_error(0, func(c): c["drives"] = [{"id": "功名", "weight": 0.4}, {"id": "天下", "weight": 0.3}, {"id": "学问", "weight": 0.3}], "心志 3 条")
	expect_error(0, func(c): c["drives"] = [{"id": "成仙", "weight": 1.0}], "未知心志")
	expect_error(0, func(c): c["drives"] = [{"id": "安身", "weight": 0.5}, {"id": "报仇", "weight": 0.5}], "心志互斥")
	expect_error(0, func(c): c["drives"] = [{"id": "安身", "weight": 1.0}]; c["habits"] = ["habit_032"], "与习性 habit_032 互斥")
	expect_error(0, func(c): c["habits"] = ["habit_999"], "词条不存在 habit_999")
	expect_error(0, func(c): c["fame"] = {"id": "fame_999"}, "词条不存在 fame_999")
	expect_error(0, func(c): c.erase("faction_id"), "faction_id 不在世界剧本")
	expect_error(0, func(c): c["relations"] = [{"to": "nobody", "信任": 50}], "关系对象不存在")
	expect_error(0, func(c): c["relations"] = [{"group": "everyone", "信任": 50}], "关系边既无 to")
	expect_error(0, func(c): c["knots"] = [{"id": "knot_001", "object": {"kind": "city", "id": "atlantis"}, "intensity": 30}], "心结对象城池不在世界剧本")
	expect_error(0, func(c): c["knots"] = [{"id": "knot_001", "object": {"kind": "person", "id": "nobody"}, "intensity": 30}], "心结对象人物不存在")
	expect_error(0, func(c): c["knots"] = [{"id": "knot_001", "object": {"kind": "faction", "id": "nowhere_army"}, "intensity": 30}], "心结对象势力不存在")
	expect_error(0, func(c): c["knots"] = [{"id": "knot_001", "object": {"kind": "star", "id": "x"}, "intensity": 30}], "心结对象种类")
	var three_knots := func(c):
		var knot := {"id": "knot_001", "object": {"kind": "person", "id": cards[1]["id"]}, "intensity": 30}
		c["knots"] = [knot, knot, knot]
	expect_error(0, three_knots, "心结 3 条")
	expect_error(0, func(c): c["kin"] = [{"to": "nobody", "type": "子"}], "亲族不存在")
	expect_error(0, func(c): c["circles"] = ["circle_nowhere"], "圈子不存在")
	expect_error(0, func(c): c["circles"] = [], "没登记在 circles")
	expect_error(0, func(c): c["hidden"] = ["habits.habit_999"], "隐藏项")
	expect_error(0, func(c): c["birth_year"] = 0, "缺生年")
	expect_error(0, func(c): c["inferred"] = ["no_such_field"], "推定登记了不存在的字段")
	expect_error(0, func(c): c.erase("career"), "缺字段 career")
	expect_error(0, func(c): c["schema_version"] = 6, "schema_version")

	var circles_broken: Dictionary = refs["circles"].duplicate(true)
	var clan_id: String = circles_broken.keys().filter(func(id): return circles_broken[id]["kind"] == "宗族")[0]
	circles_broken[clan_id]["members_rule"] = {"origin.commandery": "x"}
	circles_broken[clan_id].erase("members")
	var clan_refs := refs.duplicate()
	clan_refs["circles"] = circles_broken
	check(Validation.check_cards(cards, clan_refs)["errors"].any(func(line): return str(line).contains("宗族圈")), "宗族圈按出身入圈应报 error")
	var offstage_refs := refs.duplicate(true)
	offstage_refs["offstage"][offstage[0]["id"]]["faction"] = "nowhere_army"
	check(Validation.check_cards(cards, offstage_refs)["errors"].any(func(line): return str(line).contains("势力不在世界剧本 nowhere_army")), "不上场人物势力应是世界剧本 id")

	var bad_events := [{"eid": "e1", "kind": "deed", "actor": cards[0]["id"], "target": "nobody"}, {"eid": "e2", "kind": "betrayed_by", "actor": cards[0]["id"], "target": ""}]
	var seed_errors: Array = Validation.check_seed_events(bad_events, people_ids, refs["cities"], catalog)["errors"]
	check(seed_errors.size() == 2 and str(seed_errors[0]).contains("nobody") and str(seed_errors[1]).contains("不在事件目录"), "前史事件对象不存在、kind 不在目录都应报 error：%s" % str(seed_errors))

	expect_table_error(memory_rules, refs["drives"], relation_rules, func(m, _d, _r): m["events"].erase("visited"), "事件 visited 在目录里但规则表没有")
	expect_table_error(memory_rules, refs["drives"], relation_rules, func(m, _d, _r): m["events"]["made_up"] = [], "规则表事件 made_up 不在目录里")
	expect_table_error(memory_rules, refs["drives"], relation_rules, func(m, _d, _r): m["event_catalog"]["P2_P3"].append("betrayed_by"), "betrayed_by 既是可发事件又标为 memory_only")
	expect_table_error(memory_rules, refs["drives"], relation_rules, func(m, _d, _r): m["weight_class"]["light"].erase("consulted"), "记忆 consulted 没有衰减档")
	expect_table_error(memory_rules, refs["drives"], relation_rules, func(_m, _d, r): r["from_memory"].erase("ally_killed"), "记忆 ally_killed 关系规则未声明")
	expect_table_error(memory_rules, refs["drives"], relation_rules, func(_m, d, _r): d["rules"].append({"drive": "功名", "on": "moon_rises", "delta": 1}), "on=moon_rises 无来源")

	var names := Validation.protected_names(Repository.cards(), offstage)
	check(names.size() > 30 and str(Repository.cards()[0]["name"]) in names and str(offstage[0]["name"]) in names, "R1 名单应含人物卡与不上场人物的名字")
	check(str(Repository.cards()[0]["faction"]) in names, "R1 名单应含势力名")
	check(Validation.scan_names("res://scripts", names).is_empty(), "scripts/ 下不应出现人名或势力名：%s" % str(Validation.scan_names("res://scripts", names)))
	DirAccess.make_dir_recursive_absolute(PROBE_DIR)
	var probe := FileAccess.open(PROBE_DIR + "/probe.gd", FileAccess.WRITE)
	probe.store_string("extends RefCounted\nconst WHO := \"%s\"\n" % names[0])
	probe.close()
	var hits := Validation.scan_names(PROBE_DIR, names)
	check(hits.size() == 1 and hits[0].ends_with(":2: " + names[0]), "R1 应命中探针文件第 2 行：%s" % str(hits))
	DirAccess.remove_absolute(PROBE_DIR + "/probe.gd")
	DirAccess.remove_absolute(PROBE_DIR)

	print("PEOPLE_DATA_RULES: %s（%d 处失败）" % ["PASS" if failures.is_empty() else "FAIL", failures.size()])
	quit(1 if not failures.is_empty() else 0)
