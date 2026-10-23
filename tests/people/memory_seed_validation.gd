extends SceneTree
## 开局记忆：官渡前史事件经记忆规则写入后，与 Python 参考预演（tests/fixtures/people/guandu_seed_memories.preview.json，
## 由 check_people_data.py 生成，不含性格系数）逐人逐条同序、强度差 ≤0.05；重档保底 base×0.4；生平取 bio=true；
## 同一份数据 seed 两次结果相同。
##
##   godot --headless --path . --script res://tests/people/memory_seed_validation.gd

const Store = preload("res://scripts/people/person_store.gd")
const Memory = preload("res://scripts/people/memory.gd")

const PREVIEW := "res://tests/fixtures/people/guandu_seed_memories.preview.json"
const INTENSITY_TOLERANCE := 0.05

var failures: Array[String] = []


func check(value: bool, message: String) -> void:
	if not value:
		failures.append(message)
		push_error(message)


func _initialize() -> void:
	var store := Store.new()
	store.load_scenario("guandu")
	var preview: Dictionary = Store.read_json(PREVIEW)
	check(preview.size() == 11, "预演应覆盖 11 人，实际 %d" % preview.size())
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
	check(compared == 19, "应逐条对齐 19 条，实际 %d" % compared)

	var mids := {}
	for owner in store.memories:
		for entry in store.memories[owner]:
			check(not mids.has(entry["mid"]), "mid 重复 %s" % entry["mid"])
			mids[entry["mid"]] = true
			check(entry["about"].is_empty() or entry["about"]["kind"] == "person", "开局记忆对象都应是人物：%s" % str(entry["about"]))

	var rules: Dictionary = Store.read_json(Store.DATA_DIR + "memory_rules.json")
	check(is_equal_approx(Memory.decayed(50.0, "heavy", 1000, rules), 20.0), "重档衰减到底应保底 base×0.4")
	check(Memory.decayed(50.0, "mid", 1000, rules) == 0.0 and is_equal_approx(Memory.decayed(25.0, "mid", 10, rules), 15.0), "中档线性衰减到 0、无保底")

	var events: Array = Store.read_json(Store.DATA_DIR + "guandu/seed_events.json")["events"]
	var bio_total := 0
	for id in store.persons:
		var expected_eids: Array = []
		for event in events:
			if event["bio"] and (event["actor"] == id or id in event["data"].get("bio_also", [])): expected_eids.append(event["eid"])
		var got_eids: Array = store.biographies.get(id, []).map(func(entry): return entry["eid"])
		check(got_eids == expected_eids, "%s 生平 %s，应为 %s" % [id, str(got_eids), str(expected_eids)])
		bio_total += got_eids.size()
	check(bio_total == 46, "20 人生平节点合计应为 46（45 条 bio 事件，其中 1 条两人共享），实际 %d" % bio_total)

	var again := Store.new()
	again.load_scenario("guandu")
	check(JSON.stringify(again.export_state()) == JSON.stringify(store.export_state()), "同一份数据 seed 两次结果应相同")
	again.free()
	store.free()

	print("MEMORY_SEED: %s（%d 处失败，逐条对齐 %d 条）" % ["PASS" if failures.is_empty() else "FAIL", failures.size(), compared])
	quit(1 if not failures.is_empty() else 0)
