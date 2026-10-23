class_name PeopleValidation
extends RefCounted
## 人物数据校验规则（01-人物数据模型 §5）。纯函数：输入已读好的数据，输出 {errors, warnings}，不读写状态。
##
## 命令行入口是 tools/validate/validate_people.gd，单测直接调用这里的函数。
## 习性、履历、心结、声名四个词条库还没进仓库，第 1 条对它们只核对 id 格式；第 5 条（同岗位本事+习性重合）
## 需要习性库的岗位信息，同样暂缺，见 docs/人物系统P1-实现说明.md。
## 心结或前史事件指向地图数据里没有的城池时记为 warning：人物层可以提到当前地图切片之外的地方。
## 第 6 条 R1 由 protected_names() + scan_names() 实现。

const Circles = preload("res://scripts/people/circles.gd")

const S7_FIELDS := ["birth_year", "origin", "kin", "drives", "habits", "career", "knots", "fame", "circles", "hidden"]
const ENTRY_PATTERNS := {"habits": "^habit_\\d{3}$", "career": "^career_\\d{3}$", "knots": "^knot_\\d{3}$", "fame": "^fame_\\d{3}$"}
const MAX_DRIVES := 2
const MAX_KNOTS := 2
const WEIGHT_TOLERANCE := 0.01
const OBJECT_KINDS := ["person", "faction", "city"]


## 校验 schema 7 人物卡。refs = {offstage: {id: 条目}, circles: {id: 定义}, drives: drives.json, cities: Array, factions: Array}。
static func check_cards(cards: Array, refs: Dictionary) -> Dictionary:
	var report := {"errors": [], "warnings": []}
	var people := {}
	for card in cards: people[str(card["id"])] = card
	for id in refs["offstage"]: people[id] = refs["offstage"][id]
	for card in cards: _check_card(card, people, refs, report)
	_check_circle_members(cards, refs["circles"], people, report)
	return report


## 前史事件的 actor / target 应是人物或地图城池；都不是时记 warning（可能是地图切片外的地方，也可能是 id 写错）。
static func check_seed_events(events: Array, people_ids: Array, cities: Array) -> Dictionary:
	var report := {"errors": [], "warnings": []}
	for event in events:
		for field in ["actor", "target"]:
			var id := str(event[field])
			if not id.is_empty() and id not in people_ids and id not in cities:
				report["warnings"].append("%s %s 不是人物，也不在地图城池里：%s" % [event["eid"], field, id])
	return report


## R1 要保护的名字：人物卡的 name、字、势力名，以及不上场人物的 name、势力名。
static func protected_names(cards: Array, offstage: Array) -> Array[String]:
	var found: Array[String] = []
	for entry in cards + offstage:
		for key in ["name", "courtesy_name", "faction"]:
			var value := str(entry.get(key, ""))
			if not value.is_empty() and value not in found: found.append(value)
	return found


## R1：在 root 目录（递归）的 .gd 文件里找名字，每处命中一条「路径:行号: 名字」。
static func scan_names(root: String, names: Array[String]) -> Array[String]:
	var hits: Array[String] = []
	for path in _gd_files(root):
		var lines := FileAccess.get_file_as_string(path).split("\n")
		for number in lines.size():
			for name in names:
				if lines[number].contains(name): hits.append("%s:%d: %s" % [path, number + 1, name])
	return hits


static func _check_card(card: Dictionary, people: Dictionary, refs: Dictionary, report: Dictionary) -> void:
	var id := str(card["id"])
	var errors: Array = report["errors"]
	if int(card.get("schema_version", 0)) != 7: errors.append("%s schema_version 不是 7" % id)
	for field in S7_FIELDS:
		if not card.has(field): errors.append("%s 缺字段 %s" % [id, field])
	if not card.has_all(S7_FIELDS): return
	if int(card["birth_year"]) <= 0: errors.append("%s 缺生年" % id)
	for entry in card.get("inferred", []):
		if not card.has(str(entry).get_slice(".", 0)): errors.append("%s 推定登记了不存在的字段 %s" % [id, entry])
	_check_drives(id, card, refs["drives"], errors)
	_check_entries(id, card, errors)
	_check_knots(id, card, people, refs, report)
	for link in card["kin"]:
		if not people.has(str(link["to"])): errors.append("%s 亲族不存在 %s" % [id, link["to"]])
	for circle_id in card["circles"]:
		if not refs["circles"].has(circle_id): errors.append("%s 圈子不存在 %s" % [id, circle_id])
	for entry in card["hidden"]:
		var parts := str(entry).split(".")
		if not card.has(parts[0]) or (parts.size() > 1 and parts[1] not in _entry_ids(card[parts[0]])):
			errors.append("%s 隐藏项指向不存在的内容 %s" % [id, entry])


static func _check_drives(id: String, card: Dictionary, doc: Dictionary, errors: Array) -> void:
	var drives: Array = card["drives"]
	var total := 0.0
	for drive in drives:
		total += float(drive["weight"])
		if drive["id"] not in doc["ids"]: errors.append("%s 未知心志 %s" % [id, drive["id"]])
	if drives.is_empty() or drives.size() > MAX_DRIVES or absf(total - 1.0) > WEIGHT_TOLERANCE:
		errors.append("%s 心志 %d 条、权重和 %.2f（应 1–%d 条、和为 1）" % [id, drives.size(), total, MAX_DRIVES])
	var ids := _entry_ids(drives)
	for pair in doc["exclusive"]:
		if pair[0] in ids and pair[1] in ids: errors.append("%s 心志互斥 %s/%s" % [id, pair[0], pair[1]])
	for drive_id in doc["exclusive_habits"]:
		if drive_id not in ids: continue
		for habit in doc["exclusive_habits"][drive_id]:
			if habit in card["habits"]: errors.append("%s 心志 %s 与习性 %s 互斥" % [id, drive_id, habit])


static func _check_entries(id: String, card: Dictionary, errors: Array) -> void:
	var entries := {"habits": card["habits"], "career": card["career"], "knots": card["knots"], "fame": [] if card["fame"].is_empty() else [card["fame"]]}
	for field in entries:
		var regex := RegEx.create_from_string(ENTRY_PATTERNS[field])
		for entry_id in _entry_ids(entries[field]):
			if regex.search(entry_id) == null: errors.append("%s %s 词条 id 格式不对 %s" % [id, field, entry_id])


static func _check_knots(id: String, card: Dictionary, people: Dictionary, refs: Dictionary, report: Dictionary) -> void:
	if card["knots"].size() > MAX_KNOTS: report["errors"].append("%s 心结 %d 条（上限 %d）" % [id, card["knots"].size(), MAX_KNOTS])
	for knot in card["knots"]:
		var target: Dictionary = knot.get("object", {})
		var kind := str(target.get("kind", ""))
		var target_id := str(target.get("id", ""))
		match kind:
			"person":
				if not people.has(target_id): report["errors"].append("%s 心结对象人物不存在 %s" % [id, target_id])
			"faction":
				if target_id not in refs["factions"]: report["errors"].append("%s 心结对象势力不存在 %s" % [id, target_id])
			"city":
				if target_id not in refs["cities"]: report["warnings"].append("%s 心结对象城池不在地图数据里 %s" % [id, target_id])
			_:
				report["errors"].append("%s 心结对象种类应为 %s 之一，实际 %s" % [id, "/".join(OBJECT_KINDS), kind])


## 圈子两边一致：名单成员、规则成员都要在自己的 circles 里登记；登记了的人也必须是成员。
static func _check_circle_members(cards: Array, circles: Dictionary, people: Dictionary, report: Dictionary) -> void:
	var by_id := {}
	for card in cards: by_id[str(card["id"])] = card
	for circle_id in circles:
		var circle: Dictionary = circles[circle_id]
		for card_id in by_id:
			var card: Dictionary = by_id[card_id]
			var member: bool = card_id in circle["members"] if circle.has("members") else Circles.matches_rule(circle.get("members_rule", {}), card.get("origin", {}))
			var listed: bool = circle_id in card.get("circles", [])
			if member and not listed: report["errors"].append("%s 是圈子 %s 的成员，但没登记在 circles" % [card_id, circle_id])
			if listed and not member: report["errors"].append("%s 登记了圈子 %s，但不是其成员" % [card_id, circle_id])
		for member_id in circle.get("members", []):
			if not people.has(member_id):
				report["errors"].append("圈子 %s 的成员不存在 %s" % [circle_id, member_id])


static func _entry_ids(entries: Array) -> Array:
	return entries.map(func(entry): return str(entry["id"]) if entry is Dictionary else str(entry))


static func _gd_files(root: String) -> Array[String]:
	var out: Array[String] = []
	var dir := DirAccess.open(root)
	if dir == null: return out
	for name in dir.get_files():
		if name.ends_with(".gd"): out.append(root.path_join(name))
	for name in dir.get_directories(): out.append_array(_gd_files(root.path_join(name)))
	return out
