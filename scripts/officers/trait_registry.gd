extends RefCounted
## 战斗特性注册表。
##
## 读 data/officers/ 下的 hook 表、特性库，以及人物卡（OfficerRepository）上的特性配置，加载时一次校验，
## 运行时只回答一件事：这支部队在当前情境下，某个 hook 被特性改了多少。
## 单个特性的幅度在加载时按档位校验；同一 hook 的合计上限在查询时统一夹住，
## 调用方不再各自判断特性名。

const HOOKS_PATH := "res://data/officers/hooks.json"
const TRAITS_PATH := "res://data/officers/traits.json"
const Card = preload("res://scripts/officers/officer_card.gd")
const Repository = preload("res://scripts/officers/officer_repository.gd")
const TIERS := ["common", "elite", "flaw", "unique"]
const OPERATORS := ["==", "!=", ">=", "<=", ">", "<", "in"]
## Notion 原文的错字；人物卡与特性名里出现即校验失败。
const TYPOS := ["运筹帷幂", "骄秽", "带兽", "带养", "臀力", "故兔", "急造", "尤豫", "记仄"]

static var _hooks: Dictionary = {}
static var _traits: Dictionary = {}
## 特性 id -> hook -> 该 hook 上的效果数组，查询时免去逐条比对。
static var _index: Dictionary = {}
static var _assignments: Dictionary = {}
static var _errors: Array[String] = []
static var _loaded := false


static func _ensure() -> void:
	if _loaded: return
	load_data(_read(HOOKS_PATH), _read(TRAITS_PATH), Card.assignments(Repository.cards()))


static func _read(path: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}


## 用给定数据替换注册表并校验，返回错误列表。测试用它喂入坏数据。
static func load_data(hooks: Dictionary, traits: Dictionary, assignments: Dictionary) -> Array[String]:
	_loaded = true
	_hooks = hooks
	_traits.clear()
	_index.clear()
	_errors.clear()
	for definition in traits.get("traits", []):
		var id := str(definition.get("id", ""))
		if _traits.has(id): _errors.append("特性 id 重复：%s" % id)
		_traits[id] = definition
		var by_hook: Dictionary = {}
		for effect in definition.get("effects", []):
			var hook := str(effect.get("hook", ""))
			if not by_hook.has(hook): by_hook[hook] = []
			by_hook[hook].append(effect)
		_index[id] = by_hook
	_assignments = assignments.get("officers", {})
	for id in _traits: _errors.append_array(_validate_trait(_traits[id]))
	_errors.append_array(_validate_assignments())
	return _errors.duplicate()


## 当前注册表的全部校验错误（含人物卡错字与人物特性配置）。
static func validate(cards: Array = []) -> Array[String]:
	_ensure()
	var errors: Array[String] = _errors.duplicate()
	if cards.is_empty(): cards = Repository.cards()
	for card in cards:
		var text := JSON.stringify(card)
		for typo in TYPOS:
			if text.contains(typo): errors.append("%s 人物卡含错字：%s" % [card.get("name", card.get("id", "")), typo])
	return errors


static func definition(id: String) -> Dictionary:
	_ensure()
	return _traits.get(id, {})


static func all_ids() -> Array:
	_ensure()
	return _traits.keys()


static func hook_spec(hook: String) -> Dictionary:
	_ensure()
	var hooks: Dictionary = _hooks.get("hooks", {})
	if hook.begins_with("attribute."): return hooks.get("attribute", {})
	return hooks.get(hook, {})


## 某个历史人物的生效特性 id；没有配置的人物（生成将、守备将）返回空数组。
static func ids_for_officer(officer_id: String) -> Array:
	_ensure()
	return _assignments.get(officer_id, {}).get("trait_ids", []).duplicate()


static func has(army: Dictionary, id: String) -> bool:
	return id in army.get("trait_ids", [])


static func tier_of(id: String) -> String:
	return str(definition(id).get("tier", ""))


static func flaws(army: Dictionary) -> Array:
	return army.get("trait_ids", []).filter(func(id): return tier_of(str(id)) == "flaw")


static func display_names(ids: Array) -> Array:
	return ids.map(func(id): return str(definition(str(id)).get("name", id)))


## 同一 hook 上全部生效特性的合计修正，已按 hook 的合计上限夹住。
## percent 为相对倍率（-0.05 即耗时 -5%），pp 为概率绝对值，behavior 按各自单位。
static func modifier(army: Dictionary, hook: String, ctx: Dictionary = {}) -> float:
	_ensure()
	ctx = _with_task(hook, ctx)
	var total := 0.0
	for id in army.get("trait_ids", []):
		for effect in _index.get(id, {}).get(hook, []):
			if _applies(effect, army, ctx): total += float(effect["value"])
	var cap := _total_cap(hook)
	return clampf(total, -cap, cap)


## 本任务的属性点修正：attribute.<子属性> 合计，限制在 ±6 点。
static func attribute_points(army: Dictionary, key: String, ctx: Dictionary = {}) -> int:
	return int(modifier(army, "attribute." + key, ctx))


## 哪些特性改了这个 hook、各改多少（未夹上限前），供战报和面板标注来源。
static func sources(army: Dictionary, hook: String, ctx: Dictionary = {}) -> Array:
	_ensure()
	ctx = _with_task(hook, ctx)
	var result: Array = []
	for id in army.get("trait_ids", []):
		for effect in _index.get(id, {}).get(hook, []):
			if _applies(effect, army, ctx): result.append({"id": id, "name": str(_traits[id]["name"]), "value": float(effect["value"])})
	return result


## 专属机制的参数；部队没有该机制时返回空字典。
static func mechanism(army: Dictionary, type: String) -> Dictionary:
	_ensure()
	for id in army.get("trait_ids", []):
		var params: Dictionary = _traits.get(id, {}).get("mechanism", {})
		if str(params.get("type", "")) == type: return params
	return {}


## 调用方没说任务种类时，按 hook 所在流程补上（hooks.json 的 task），供 task.kind 条件判断。
static func _with_task(hook: String, ctx: Dictionary) -> Dictionary:
	var task := str(hook_spec(hook).get("task", ""))
	if task.is_empty() or ctx.has("task"): return ctx
	var merged := ctx.duplicate()
	merged["task"] = task
	return merged


static func _total_cap(hook: String) -> float:
	var spec := hook_spec(hook)
	var caps: Dictionary = _hooks.get("caps", {})
	match str(spec.get("kind", "")):
		"percent": return float(caps.get("percent", {}).get("total", 0.10))
		"pp": return float(caps.get("pp", {}).get("total", 0.05))
		"attribute_point": return float(caps.get("attribute_point", {}).get("total", 6))
		"behavior": return float(spec.get("total", 0.0))
	return 0.0


static func _applies(effect: Dictionary, army: Dictionary, ctx: Dictionary) -> bool:
	for condition in effect.get("when", []):
		var actual: Variant = _field(str(condition[0]), army, ctx)
		if actual == null or not _compare(actual, str(condition[1]), condition[2]): return false
	return true


## 条件字段取值（字段名沿用 Notion 特性库 v1.1）。ctx.* / task.* / intel.* / person.* 由调用方在 ctx 里给出，
## 缺失视为“不知道”，条件不成立；cargo.X 读 ctx.cargo_X；task.kind 读 ctx.task（_with_task 已按 hook 补上）；
## task.recipient_count 未给出时按标准指挥单元数推定；unit.* 从部队编成算出；person.mounted 未给出时按骑兵过半推定。
static func _field(field: String, army: Dictionary, ctx: Dictionary) -> Variant:
	if field.begins_with("ctx."): return ctx.get(field.trim_prefix("ctx."), null)
	if field == "task.kind": return ctx.get("task", null)
	if field == "task.recipient_count": return ctx.get("recipient_count", _recipients(army))
	if field.begins_with("cargo."): return ctx.get("cargo_" + field.trim_prefix("cargo."), null)
	if field.begins_with("task.") or field.begins_with("intel."): return ctx.get(field.get_slice(".", 1), null)
	if field.begins_with("person.") and field != "person.mounted": return ctx.get(field.trim_prefix("person."), null)
	match field:
		"unit.infantry_ratio": return _ratio(army, "infantry")
		"unit.cavalry_ratio": return _ratio(army, "cavalry")
		"unit.archer_ratio": return _ratio(army, "archers")
		"unit.training": return float(army.get("training", 50))
		"person.mounted": return bool(ctx.get("mounted", _ratio(army, "cavalry") >= 0.5))
	return null


## 部队的标准指挥单元数（每 2000 人一单元），即一次全军命令的受令单位数。
static func _recipients(army: Dictionary) -> int:
	var total := 0
	for value in army.get("units", {}).values(): total += int(value)
	return maxi(1, ceili(total / 2000.0))


static func _ratio(army: Dictionary, type: String) -> float:
	var total := 0.0
	for value in army.get("units", {}).values(): total += float(value)
	return float(army.get("units", {}).get(type, 0)) / total if total > 0 else 0.0


static func _compare(actual: Variant, op: String, expected: Variant) -> bool:
	match op:
		"==": return actual == expected
		"!=": return actual != expected
		">=": return float(actual) >= float(expected)
		"<=": return float(actual) <= float(expected)
		">": return float(actual) > float(expected)
		"<": return float(actual) < float(expected)
		"in": return expected is Array and actual in expected
	return false


static func _validate_trait(definition: Dictionary) -> Array[String]:
	var errors: Array[String] = []
	var id := str(definition.get("id", ""))
	var tier := str(definition.get("tier", ""))
	var name := str(definition.get("name", ""))
	var pattern := RegEx.create_from_string("^(trait_[0-9]{3}|trait_c[0-9]{2}|flaw_[a-z]+|unique_[a-z]+)$")
	if pattern.search(id) == null: errors.append("特性 id 不合规：%s" % id)
	if tier not in TIERS: errors.append("%s 档位未注册：%s" % [id, tier])
	if name.is_empty(): errors.append("%s 缺少名称" % id)
	for typo in TYPOS:
		if name.contains(typo) or str(definition.get("summary", "")).contains(typo): errors.append("%s 含错字：%s" % [id, typo])
	var effects: Array = definition.get("effects", [])
	if tier == "unique":
		var type := str(definition.get("mechanism", {}).get("type", ""))
		if not _hooks.get("mechanisms", {}).has(type): errors.append("%s 专属机制未注册：%s" % [id, type])
	elif effects.is_empty():
		errors.append("%s 没有任何效果" % id)
	for effect in effects: errors.append_array(_validate_effect(id, tier, effect))
	return errors


static func _validate_effect(id: String, tier: String, effect: Dictionary) -> Array[String]:
	var errors: Array[String] = []
	var hook := str(effect.get("hook", ""))
	var spec := hook_spec(hook)
	if spec.is_empty():
		return ["%s 使用了未注册的 hook：%s" % [id, hook]]
	if hook.begins_with("attribute.") and hook.trim_prefix("attribute.") not in _hooks.get("attribute_keys", []):
		errors.append("%s 修改了不存在的子属性：%s" % [id, hook])
	var value := float(effect.get("value", 0.0))
	var magnitude := absf(value)
	var caps: Dictionary = _hooks.get("caps", {})
	var kind := str(spec.get("kind", ""))
	var label := "%s.%s=%s" % [id, hook, value]
	match kind:
		"percent":
			var band: Dictionary = caps.get("percent", {})
			var high := float(band.get("elite_max" if tier in ["elite", "unique"] else "common_max", 0.05))
			if magnitude < float(band.get("common_min", 0.03)) - 0.0001 or magnitude > high + 0.0001: errors.append("%s 超出%s档单来源范围" % [label, tier])
		"pp":
			var band: Dictionary = caps.get("pp", {})
			var high := float(band.get("elite_max" if tier in ["elite", "unique"] else "common_max", 0.02))
			if magnitude <= 0.0 or magnitude > high + 0.0001: errors.append("%s 超出%s档单来源范围" % [label, tier])
		"attribute_point":
			var band: Dictionary = caps.get("attribute_point", {})
			var up := float(band.get("elite_up" if tier in ["elite", "unique"] else "common_up", 2))
			if value != floorf(value) or value == 0.0 or value > up or value < -float(band.get("common_down", 3)): errors.append("%s 属性点超出%s档范围" % [label, tier])
		"behavior":
			if magnitude <= 0.0 or magnitude > float(spec.get("source_max", 0.0)) + 0.0001: errors.append("%s 超出单来源上限" % label)
	var better := str(spec.get("better", "neutral"))
	if better != "neutral" and value != 0.0:
		var improves := value < 0.0 if better == "lower" else value > 0.0
		if tier == "flaw" and improves: errors.append("%s 局限特性的方向写成了优势" % label)
		if tier != "flaw" and not improves: errors.append("%s 优势特性的方向写成了代价" % label)
	var fields: Dictionary = _hooks.get("fields", {})
	for condition in effect.get("when", []):
		if not condition is Array or condition.size() != 3:
			errors.append("%s 条件格式应为 [字段, 运算符, 值]" % label)
			continue
		var field := str(condition[0])
		if not fields.has(field): errors.append("%s 条件字段未注册：%s" % [label, field])
		if str(condition[1]) not in OPERATORS: errors.append("%s 条件运算符未注册：%s" % [label, condition[1]])
		var allowed: Array = fields.get(field, {}).get("values", [])
		if not allowed.is_empty():
			var wanted: Array = condition[2] if condition[2] is Array else [condition[2]]
			for item in wanted:
				if not item in allowed: errors.append("%s 条件取值不在 %s 的枚举内：%s" % [label, field, item])
	return errors


## GDD 8.1：技术特性每人普通≤3（含普通·局限）、卓越≤2、专属≤1、总数≤5，允许零特性；
## 人格型局限（flaw_*，卡面 personality.flaws）不占技术特性名额，每人≤2。
## 没有任何局限的人物须在卡上写明 no_flaw_reason；Notion 原文本身超预算的（卡上 gdd_exceptions.trait_budget）放行。
static func _validate_assignments() -> Array[String]:
	var errors: Array[String] = []
	for officer_id in _assignments:
		var entry: Dictionary = _assignments[officer_id]
		var name := str(entry.get("name", officer_id))
		var ids: Array = entry.get("trait_ids", [])
		var counts := {"common": 0, "elite": 0, "unique": 0, "personality": 0, "flaw": 0}
		var seen: Dictionary = {}
		for id in ids:
			if seen.has(id): errors.append("%s 特性重复：%s" % [name, id])
			seen[id] = true
			if not _traits.has(id):
				errors.append("%s 使用了未注册的特性：%s" % [name, id])
				continue
			var tier := tier_of(str(id))
			if tier == "flaw": counts["flaw"] += 1
			if str(id).begins_with("flaw_"): counts["personality"] += 1
			elif tier in ["common", "flaw"]: counts["common"] += 1
			elif counts.has(tier): counts[tier] += 1
		var over_budget: bool = counts["common"] > 3 or counts["elite"] > 2 or counts["unique"] > 1 or counts["common"] + counts["elite"] + counts["unique"] > 5
		if over_budget and str(entry.get("budget_exception", "")).is_empty():
			errors.append("%s 技术特性数量超出 GDD 8.1（普通≤3、卓越≤2、专属≤1、总数≤5）" % name)
		if counts["personality"] > 2: errors.append("%s 人格型局限超过 2 个" % name)
		if counts["flaw"] == 0 and str(entry.get("no_flaw_reason", "")).is_empty(): errors.append("%s 没有局限，也没写 no_flaw_reason" % name)
		for id in entry.get("inferred", []):
			if not id in ids: errors.append("%s 推定条目 %s 不在生效特性里" % [name, id])
	return errors
