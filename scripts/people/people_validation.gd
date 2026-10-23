class_name PeopleValidation
extends RefCounted
## 人物数据校验规则（01-人物数据模型 §5）。纯函数：输入已读好的数据，输出 {errors, warnings}，不读写状态。
##
## 命令行入口是 tools/validate/validate_people.gd，单测直接调用这里的函数；只有 load_refs() 读数据文件。
## 词条查 data/people/libraries/ 的四个词条库；城池与势力查世界剧本（places、factions 的 id）。
## 第 5 条（同岗位本事+习性重合）未做，见 docs/人物系统P1-实现说明.md。
## check_rule_tables() 核对事件目录、衰减档、关系规则、心志规则互相覆盖（与 check_people_data.py 同口径）。
## 第 6 条 R1 由 protected_names() + scan_names() 实现。

const Circles = preload("res://scripts/people/circles.gd")
const Migrate = preload("res://scripts/people/card_migrate.gd")

const DATA_DIR := "res://data/people/"
const WORLD_SCENARIO := "res://data/scenario_world_demo.json"

const S7_FIELDS := ["birth_year", "origin", "kin", "drives", "habits", "career", "knots", "fame", "circles", "hidden"]
## 卡上字段 → 词条库（data/people/libraries/<文件>.json）。
const LIBRARY_FILES := {"habits": "habits", "career": "careers", "knots": "knots", "fame": "fame"}
const MAX_DRIVES := 2
const MAX_KNOTS := 2
const WEIGHT_TOLERANCE := 0.01
const OBJECT_KINDS := ["person", "faction", "city"]
const CLAN_KIND := "宗族"
const PEER_GROUP := "direct_peers"
## 心志规则里不由事件目录发出、也不是 signals 的 on：主公之死由势力生命周期直接处理。
const DRIVE_ON_EXTRA := ["lord_died"]


## 读 check_cards() 要的参照数据：不上场人物、圈子、心志表、四个词条库，以及世界剧本的城池与势力 id。
static func load_refs() -> Dictionary:
	var library := {}
	for field in LIBRARY_FILES:
		library[field] = _read(DATA_DIR + "libraries/%s.json" % LIBRARY_FILES[field]).map(func(entry): return str(entry["id"]))
	var world: Dictionary = _read(WORLD_SCENARIO)
	return {"offstage": _by_id(_read(DATA_DIR + "offstage.json")), "circles": _by_id(_read(DATA_DIR + "circles.json")),
		"drives": Migrate.drives_doc(), "library": library, "cities": world["places"].keys(), "factions": world["factions"].keys()}


## 校验 schema 7 人物卡、不上场人物与圈子定义。
## refs = {offstage: {id: 条目}, circles: {id: 定义}, drives: drives.json, library: {字段: [词条 id]},
##         cities: 世界剧本城池 id, factions: 世界剧本势力 id}。
static func check_cards(cards: Array, refs: Dictionary) -> Dictionary:
	var report := {"errors": [], "warnings": []}
	var people := {}
	for card in cards: people[str(card["id"])] = card
	for id in refs["offstage"]: people[id] = refs["offstage"][id]
	for card in cards: _check_card(card, people, refs, report)
	for id in refs["offstage"]:
		var faction := str(refs["offstage"][id].get("faction", ""))
		if not faction.is_empty() and faction not in refs["factions"]: report["errors"].append("%s 势力不在世界剧本 %s" % [id, faction])
	_check_circles(refs["circles"], refs["factions"], report)
	_check_circle_members(cards, refs["circles"], people, report)
	return report


## 前史事件：actor / target 必须是人物或世界剧本城池，kind 必须在事件目录里。
static func check_seed_events(events: Array, people_ids: Array, cities: Array, catalog_kinds: Array) -> Dictionary:
	var report := {"errors": [], "warnings": []}
	for event in events:
		for field in ["actor", "target"]:
			var id := str(event[field])
			if not id.is_empty() and id not in people_ids and id not in cities:
				report["errors"].append("%s %s 不是人物，也不在世界剧本城池里：%s" % [event["eid"], field, id])
		if str(event["kind"]) not in catalog_kinds: report["errors"].append("%s kind %s 不在事件目录" % [event["eid"], event["kind"]])
	return report


## 事件目录里可 emit 的全部 kind（各阶段 + bio_only，不含 memory_only）。
static func catalog_kinds(memory_rules: Dictionary) -> Array:
	var catalog: Dictionary = memory_rules["event_catalog"]
	var out: Array = catalog["P1_war_hooks"].keys()
	for stage in ["P2_P3", "P5_P7", "bio_only"]: out.append_array(catalog[stage])
	return out


## 规则表互相覆盖：事件目录 ↔ 记忆规则一一对应；memory_only 不可 emit；会写出的记忆都有衰减档、
## 都在关系规则 from_memory 里声明（不改关系写 {}）；心志规则的 on 都有来源（事件目录、signals 或 DRIVE_ON_EXTRA）。
static func check_rule_tables(memory_rules: Dictionary, drives: Dictionary, relation_rules: Dictionary) -> Dictionary:
	var errors: Array = []
	var emit := catalog_kinds(memory_rules)
	var events: Dictionary = memory_rules["events"]
	for kind in emit:
		if not events.has(kind): errors.append("事件 %s 在目录里但规则表没有" % kind)
	for kind in events:
		if kind not in emit: errors.append("规则表事件 %s 不在目录里" % kind)
	for kind in memory_rules["event_catalog"]["memory_only"]:
		if kind in emit: errors.append("%s 既是可发事件又标为 memory_only" % kind)
	var classed: Array = []
	for weight_class in memory_rules["weight_class"]: classed.append_array(memory_rules["weight_class"][weight_class])
	var written: Array = []
	for kind in events:
		for rule in events[kind]:
			if str(rule["kind"]) not in written: written.append(str(rule["kind"]))
	for kind in written:
		if kind not in classed: errors.append("记忆 %s 没有衰减档" % kind)
		if not relation_rules["from_memory"].has(kind): errors.append("记忆 %s 关系规则未声明（无变化请写 {}）" % kind)
	for rule in drives["rules"] + drives["rewrite"]:
		var on := str(rule["on"])
		if on not in emit and not drives["signals"].has(on) and on not in DRIVE_ON_EXTRA: errors.append("心志规则的 on=%s 无来源" % on)
	return {"errors": errors, "warnings": []}


## R1 要保护的名字：人物卡的 name、字、势力显示名，以及不上场人物的 name、字。
## 不上场人物的 faction 是世界剧本势力 id（cao_cao 一类），属于 id 不是名字，不在名单里。
static func protected_names(cards: Array, offstage: Array) -> Array[String]:
	var found: Array[String] = []
	for entry in cards: _add_names(found, entry, ["name", "courtesy_name", "faction"])
	for entry in offstage: _add_names(found, entry, ["name", "courtesy_name"])
	return found


static func _add_names(found: Array[String], entry: Dictionary, keys: Array) -> void:
	for key in keys:
		var value := str(entry.get(key, ""))
		if not value.is_empty() and value not in found: found.append(value)


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
	_check_entries(id, card, refs["library"], errors)
	if str(card.get("faction_id", "")) not in refs["factions"]: errors.append("%s faction_id 不在世界剧本 %s" % [id, card.get("faction_id", "缺失")])
	for edge in card.get("relations", []):
		if edge.has("to"):
			if not people.has(str(edge["to"])): errors.append("%s 关系对象不存在 %s" % [id, edge["to"]])
		elif str(edge.get("group", "")) != PEER_GROUP:
			errors.append("%s 关系边既无 to 也无 %s 分组" % [id, PEER_GROUP])
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


static func _check_entries(id: String, card: Dictionary, library: Dictionary, errors: Array) -> void:
	var entries := {"habits": card["habits"], "career": card["career"], "knots": card["knots"], "fame": [] if card["fame"].is_empty() else [card["fame"]]}
	for field in entries:
		for entry_id in _entry_ids(entries[field]):
			if entry_id not in library[field]: errors.append("%s %s 词条不存在 %s" % [id, field, entry_id])


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
				if target_id not in refs["cities"]: report["errors"].append("%s 心结对象城池不在世界剧本 %s" % [id, target_id])
			_:
				report["errors"].append("%s 心结对象种类应为 %s 之一，实际 %s" % [id, "/".join(OBJECT_KINDS), kind])


## 圈子定义：派系圈的势力是世界剧本 id；宗族圈必须列成员，按出身规则入圈的只能是同乡。
static func _check_circles(circles: Dictionary, factions: Array, report: Dictionary) -> void:
	for circle_id in circles:
		var circle: Dictionary = circles[circle_id]
		var faction := str(circle.get("faction", ""))
		if not faction.is_empty() and faction not in factions: report["errors"].append("圈子 %s 势力不在世界剧本 %s" % [circle_id, faction])
		if str(circle.get("kind", "")) == CLAN_KIND and circle.has("members_rule"): report["errors"].append("圈子 %s 是宗族圈，应列成员，按出身入圈的应为同乡" % circle_id)


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


static func _read(path: String) -> Variant:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	assert(parsed != null, "人物校验数据读取失败：" + path)
	return parsed


static func _by_id(entries: Array) -> Dictionary:
	var out := {}
	for entry in entries: out[str(entry["id"])] = entry
	return out


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
