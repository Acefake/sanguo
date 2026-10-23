extends SceneTree
## People 存储：官渡开局 20 人可查；export_state → JSON 文本 → import_state 往返后状态一致、类型还原；
## 版本不认识的存档不动当前状态；亲族、圈子查询。
##
##   godot --headless --path . --script res://tests/people/person_store_validation.gd

const Store = preload("res://scripts/people/person_store.gd")
const State = preload("res://scripts/people/person_state.gd")

var failures: Array[String] = []


func check(value: bool, message: String) -> void:
	if not value:
		failures.append(message)
		push_error(message)


## 经过一次 JSON 文本后按键排序，消除整数/浮点与键序差异。
func normalized(state: Dictionary) -> String:
	return JSON.stringify(JSON.parse_string(JSON.stringify(state)), "", true)


func _initialize() -> void:
	check(Store.xun_index(200, 2, 1) == (200 * 12 + 1) * 3 and Store.xun_index(200, 2, 3) - Store.xun_index(200, 1, 3) == 3, "全局旬号按年月旬递增")
	var store := Store.new()
	store.load_scenario("guandu")
	check(store.persons.size() == 20 and store.xun == Store.xun_index(200, 2, 1), "开局 20 人、旬号取前史事件的开局日期")
	var first_id: String = store.persons.keys()[0]
	var first: State = store.get_person(first_id)
	check(first != null and first.id == first_id and store.get_person("nobody") == null, "get_person")
	var same_faction := store.by_faction(first.faction)
	check(not same_faction.is_empty() and same_faction.all(func(s): return s.faction == first.faction) and same_faction.size() < 20, "by_faction 只返回同势力的人")
	for id in store.persons:
		for link in store.persons[id].kin:
			if store.persons.has(link["to"]): check(id in store.kin_of(link["to"]), "亲族应双向可查：%s ↔ %s" % [id, link["to"]])
		for mate in store.circle_mates(id):
			check(mate != id, "circle_mates 不含本人")

	var saved := store.export_state()
	check(int(saved["people_version"]) == 1 and saved["scenario"] == "guandu", "存档带 people_version 1 与剧本 id")
	var text := JSON.stringify(saved)
	var restored := Store.new()
	check(restored.import_state(JSON.parse_string(text)), "读档应成功")
	check(normalized(restored.export_state()) == normalized(saved), "存读档往返后状态应一致")
	var back: State = restored.get_person(first_id)
	check(back.habits is Array[String] and back.birth_year is int and back.birth_year == first.birth_year, "读档后类型化字段还原")
	check(restored.circles.size() == store.circles.size() and restored.offstage.size() == store.offstage.size(), "读档后按剧本重读圈子与不上场人物")
	var added: Dictionary = restored.add_memory(first_id, {"kind": "praised"})
	check(int(str(added["mid"]).trim_prefix("m_")) == int(saved["next_mid"]), "读档后 mid 接着编号，不与存档内重复")

	check(not restored.import_state({"people_version": 99}), "未知版本应拒绝")
	check(restored.persons.size() == 20, "拒绝读档时不动当前状态")

	store.free()
	restored.free()
	print("PERSON_STORE: %s（%d 处失败）" % ["PASS" if failures.is_empty() else "FAIL", failures.size()])
	quit(1 if not failures.is_empty() else 0)
