extends SceneTree
## 开局记忆：官渡前史事件经记忆规则写入后，与 Python 参考预演（tests/fixtures/people/guandu_seed_memories.preview.json，
## 由 check_people_data.py 生成，不含性格系数）逐人逐条同序、强度差不超过预演的舍入（v1.1：48 条 / 18 人，含关口减半衰减与
## court 接收方）；重档保底 base×0.4；生平取 bio=true；同一份数据 seed 两次结果相同；
## 开局早于 pack.min_start 时拒绝载入；晚于开局旬的前史事件不进记忆和生平。
##
##   godot --headless --path . --script res://tests/people/memory_seed_validation.gd

const Store = preload("res://scripts/people/person_store.gd")
const Memory = preload("res://scripts/people/memory.gd")
const Repository = preload("res://scripts/officers/officer_repository.gd")

const PREVIEW := "res://tests/fixtures/people/guandu_seed_memories.preview.json"
## 预演强度保留一位小数（Python round），差值最多半个末位，再留一点浮点余量。
const INTENSITY_TOLERANCE := 0.051
const PREVIEW_OWNERS := 18
const PREVIEW_TOTAL := 48

var failures: Array[String] = []


func check(value: bool, message: String) -> void:
	if not value:
		failures.append(message)
		push_error(message)


func _initialize() -> void:
	var store := Store.new()
	check(store.load_scenario("guandu"), "默认开局应载入官渡人物包")
	var preview: Dictionary = Store.read_json(PREVIEW)
	check(preview.size() == PREVIEW_OWNERS, "预演应覆盖 18 人，实际 %d" % preview.size())
	check(store.memories.keys().all(func(owner): return preview.has(owner)) and preview.keys().all(func(owner): return store.memories.has(owner)),
		"有记忆的人应与预演一致：%s vs %s" % [str(store.memories.keys()), str(preview.keys())])
	var compared := 0
	for owner in preview:
		var expected: Array = preview[owner]
		var actual: Array = store.memories.get(owner, [])
		check(actual.size() == expected.size(), "%s 记忆条数 %d，预演 %d" % [owner, actual.size(), expected.size()])
		for index in mini(actual.size(), expected.size()):
			var got: Dictionary = actual[index]
			var want: Dictionary = expected[index]
			var label := "%s 第 %d 条" % [owner, index + 1]
			check(got["event_ref"] == want["eid"] and got["kind"] == want["kind"], "%s 应为 %s/%s，实际 %s/%s" % [label, want["eid"], want["kind"], got["event_ref"], got["kind"]])
			check(got["about"].get("id", "") == want["about"] and int(got["valence"]) == int(want["valence"]), "%s 对象或恩怨不同" % label)
			check(absf(float(got["intensity"]) - float(want["intensity"])) <= INTENSITY_TOLERANCE, "%s 强度 %.2f，预演 %.1f" % [label, got["intensity"], want["intensity"]])
			check(got["owner"] == owner and float(got["intensity"]) <= float(got["base"]), "%s owner 或强度超过 base" % label)
			compared += 1
	check(compared == PREVIEW_TOTAL, "应逐条对齐 %d 条，实际 %d" % [PREVIEW_TOTAL, compared])

	var mids := {}
	for owner in store.memories:
		for entry in store.memories[owner]:
			check(not mids.has(entry["mid"]), "mid 重复 %s" % entry["mid"])
			mids[entry["mid"]] = true
			check(entry["about"].is_empty() or entry["about"]["kind"] == "person", "开局记忆对象都应是人物：%s" % str(entry["about"]))

	var rules: Dictionary = Store.read_json(Store.DATA_DIR + "memory_rules.json")
	check(is_equal_approx(Memory.decayed(50.0, "heavy", 1000, rules), 20.0), "重档衰减到底应保底 base×0.4")
	check(Memory.decayed(50.0, "mid", 1000, rules) == 0.0 and is_equal_approx(Memory.decayed(20.0, "mid", 10, rules), 17.0), "中档线性衰减到 0、无保底")
	check(is_equal_approx(Memory.decayed(20.0, "mid", 10, rules, 0.5), 18.5), "关口事件衰减减半")
	var court := store.court_of("ys_001")
	check(not court.is_empty() and "ys_001" not in court and court.all(func(id): return store.get_person(id).faction == store.get_person("ys_001").faction), "court 是同势力的其他人")

	var events: Array = Store.read_json(Store.DATA_DIR + "guandu/seed_events.json")["events"]
	var bio_total := 0
	for id in store.persons:
		var expected_eids: Array = []
		for event in events:
			if event["bio"] and (event["actor"] == id or id in event["data"].get("bio_also", [])): expected_eids.append(event["eid"])
		var got_eids: Array = store.biographies.get(id, []).map(func(entry): return entry["eid"])
		check(got_eids == expected_eids, "%s 生平 %s，应为 %s" % [id, str(got_eids), str(expected_eids)])
		bio_total += got_eids.size()
	check(bio_total > 0, "应写出生平节点")

	var early := Store.new()
	check(not early.load_scenario("guandu", {"year": 191, "month": 9, "xun": 1}) and early.persons.is_empty(), "开局早于 min_start 时应拒绝载入")
	early.free()
	var cut := Store.new()
	check(cut.load_scenario("guandu", {"year": 200, "month": 2, "xun": 1}), "min_start 当旬应可开局")
	cut.setup_from_scenario("guandu", Repository.cards(), Store.read_json(Store.DATA_DIR + "guandu/persons_s7.json"), {"year": 200, "month": 1, "xun": 3})
	Memory.seed(cut, {"events": events}, rules)
	var cutoff := Store.xun_index(200, 1, 3)
	var late := events.filter(func(e): return Store.xun_index(int(e["year"]), int(e["month"]), 1) > cutoff).map(func(e): return e["eid"])
	check(not late.is_empty(), "测试数据应有晚于截止旬的事件")
	for owner in cut.memories:
		for entry in cut.memories[owner]: check(entry["event_ref"] not in late, "晚于开局的事件 %s 不应进记忆" % entry["event_ref"])
	for owner in cut.biographies:
		for entry in cut.biographies[owner]: check(entry["eid"] not in late, "晚于开局的事件 %s 不应进生平" % entry["eid"])
	cut.free()

	var again := Store.new()
	again.load_scenario("guandu")
	check(JSON.stringify(again.export_state()) == JSON.stringify(store.export_state()), "同一份数据 seed 两次结果应相同")
	again.free()
	store.free()

	print("MEMORY_SEED: %s（%d 处失败，逐条对齐 %d 条）" % ["PASS" if failures.is_empty() else "FAIL", failures.size(), compared])
	quit(1 if not failures.is_empty() else 0)
