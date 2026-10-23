extends SceneTree
## 人物数据校验规则：官渡真实数据零 error；每条规则在坏数据上都会报出来；R1 在 scripts/ 下零命中、
## 在含人名的探针文件上命中。
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


## 改坏第 index 张卡后校验，应出现含 expected 的 error。
func expect_error(index: int, mutate: Callable, expected: String) -> void:
	var broken := cards.duplicate(true)
	mutate.call(broken[index])
	var errors: Array = Validation.check_cards(broken, refs)["errors"]
	check(errors.any(func(line): return str(line).contains(expected)), "应报「%s」，实际 %s" % [expected, str(errors)])


func _initialize() -> void:
	var offstage: Array = Store.read_json(Store.DATA_DIR + "offstage.json")
	cards = Migrate.migrate_all(Repository.cards(), Store.read_json(Store.DATA_DIR + "guandu/persons_s7.json"))
	var offstage_by_id := {}
	for entry in offstage: offstage_by_id[entry["id"]] = entry
	var circles := {}
	for entry in Store.read_json(Store.DATA_DIR + "circles.json"): circles[entry["id"]] = entry
	refs = {"offstage": offstage_by_id, "circles": circles, "drives": Migrate.drives_doc(), "cities": ["ye", "xuchang"], "factions": [cards[0]["faction"]]}

	var report := Validation.check_cards(cards, refs)
	check(report["errors"].is_empty(), "官渡数据应零 error：%s" % str(report["errors"]))
	check(report["warnings"].size() == 1 and str(report["warnings"][0]).contains("juancheng"), "官渡数据只应有一条城池不在地图的 warning：%s" % str(report["warnings"]))

	expect_error(0, func(c): c["drives"] = [{"id": "功名", "weight": 0.5}], "权重和")
	expect_error(0, func(c): c["drives"] = [{"id": "功名", "weight": 0.4}, {"id": "天下", "weight": 0.3}, {"id": "学问", "weight": 0.3}], "心志 3 条")
	expect_error(0, func(c): c["drives"] = [{"id": "成仙", "weight": 1.0}], "未知心志")
	expect_error(0, func(c): c["drives"] = [{"id": "安身", "weight": 0.5}, {"id": "报仇", "weight": 0.5}], "心志互斥")
	expect_error(0, func(c): c["drives"] = [{"id": "安身", "weight": 1.0}]; c["habits"] = ["habit_032"], "与习性 habit_032 互斥")
	expect_error(0, func(c): c["habits"] = ["habit_x"], "词条 id 格式不对")
	expect_error(0, func(c): c["knots"] = [{"id": "knot_001", "object": {"kind": "person", "id": "nobody"}, "intensity": 30}], "心结对象人物不存在")
	expect_error(0, func(c): c["knots"] = [{"id": "knot_001", "object": {"kind": "faction", "id": "无名之师"}, "intensity": 30}], "心结对象势力不存在")
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

	var people_ids: Array = cards.map(func(c): return c["id"]) + offstage_by_id.keys()
	var events := [{"eid": "e1", "actor": cards[0]["id"], "target": "nobody"}, {"eid": "e2", "actor": "ye", "target": ""}]
	var seed_report := Validation.check_seed_events(events, people_ids, ["ye"])
	check(seed_report["warnings"].size() == 1 and str(seed_report["warnings"][0]).contains("nobody"), "前史事件指向未知对象应报 warning")

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
