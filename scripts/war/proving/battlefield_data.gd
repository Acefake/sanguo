class_name ProvingGroundData
extends RefCounted
## 检验战场的数据入口：读 data/scenarios/battlefields/<id>.json，检查引用，按试验（trial）换上人物。
##
## 字段契约由 tools/validate/validate_battlefields.py 完整校验；这里只查运行时会出错的引用
## （区域、道路、人物 id、试验里换人的部队），出错返回错误列表，不静默兜底。

const Repository = preload("res://scripts/officers/officer_repository.gd")
const Roster = preload("res://scripts/agents/officer_context.gd")
const DIR := "res://data/scenarios/battlefields"
## 对照组用的“常将”：子属性全 60、人格全 50、无特性。
const NEUTRAL_ID := "neutral"
const NEUTRAL_SKILL := 60

static var _officers: Dictionary = {}


static func ids() -> Array:
	var result: Array = []
	for file in DirAccess.get_files_at(DIR):
		if file.ends_with(".json"): result.append(file.get_basename())
	result.sort()
	return result


static func load_field(id: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string("%s/%s.json" % [DIR, id]))
	return parsed if parsed is Dictionary else {}


## 运行时人物字典（OfficerContext 换算后的 skills、personality、trait_ids），含“常将”。
static func officers() -> Dictionary:
	if _officers.is_empty():
		var roster := Roster.new()
		roster.setup(Repository.cards(), {})
		_officers = roster.officers.duplicate()
		var skills := {}
		for row in Roster.SKILLS:
			for key in row: skills[key] = NEUTRAL_SKILL
		for key in Roster.EXTRA_SKILLS: skills[key] = NEUTRAL_SKILL
		var personality := {}
		for axis in Roster.AXES: personality[axis] = 50
		_officers[NEUTRAL_ID] = {"id": NEUTRAL_ID, "name": "常将", "skills": skills, "personality": personality, "trait_ids": [], "relations": []}
	return _officers


static func officer(id: String) -> Dictionary:
	return officers().get(id, {})


## 引用检查：区域、道路、部队位置、人物、试验换人。返回错误列表。
static func check(field: Dictionary) -> Array[String]:
	var errors: Array[String] = []
	var zones := {}
	for zone in field.get("zones", []): zones[str(zone["id"])] = true
	for link in field.get("links", []):
		for end in [link[0], link[1]]:
			if not zones.has(str(end)): errors.append("%s 道路引用了不存在的区域 %s" % [field.get("id", ""), end])
	var units := {}
	for side in field.get("sides", {}):
		var spec: Dictionary = field["sides"][side]
		for key in ["retreat", "lure_zone", "baggage"]:
			if spec.has(key) and not zones.has(str(spec[key])): errors.append("%s.%s 区域不存在：%s" % [side, key, spec[key]])
		if spec.has("depot") and not zones.has(str(spec["depot"]["zone"])): errors.append("%s 粮囤区域不存在" % side)
		for unit in spec.get("units", []):
			units[str(unit["id"])] = true
			if not zones.has(str(unit["zone"])): errors.append("%s 位置不存在：%s" % [unit["id"], unit["zone"]])
			for key in ["officer", "adviser"]:
				if unit.has(key) and officer(str(unit[key])).is_empty(): errors.append("%s.%s 人物不存在：%s" % [unit["id"], key, unit[key]])
	for trial in field.get("trials", []):
		for unit_id in trial.get("assign", {}):
			if not units.has(str(unit_id)): errors.append("试验 %s 换人的部队不存在：%s" % [trial["id"], unit_id])
			if officer(str(trial["assign"][unit_id])).is_empty(): errors.append("试验 %s 人物不存在：%s" % [trial["id"], trial["assign"][unit_id]])
	return errors


## 某个试验下的战场：深拷贝后按 assign 换主将（adviser_assign 换参军）。
static func with_trial(field: Dictionary, trial: Dictionary) -> Dictionary:
	var copy := field.duplicate(true)
	for side in copy["sides"]:
		for unit in copy["sides"][side]["units"]:
			var id := str(unit["id"])
			if trial.get("assign", {}).has(id): unit["officer"] = trial["assign"][id]
			if trial.get("adviser_assign", {}).has(id): unit["adviser"] = trial["adviser_assign"][id]
	return copy
