class_name CareerTemplates
extends RefCounted
## 生成将的职业模板。
##
## 剧本缺少历史人物的势力用生成将补足。每名生成将按 id 的 hash 取一个模板，
## 属性轮廓、优势特性、局限与位置都由模板决定，同一 id 每次生成完全相同，不读全局随机状态。
## 模板主项的“峰值”不低于历史人物同项中位，保证低总分的人也有一处用得上。

const PATH := "res://data/officers/career_templates.json"

static var _data: Dictionary = {}


static func data() -> Dictionary:
	if _data.is_empty(): _data = JSON.parse_string(FileAccess.get_file_as_string(PATH))
	return _data


static func templates() -> Array:
	return data()["templates"]


## 势力内第 index 名生成将的模板：从势力 hash 起轮转，前 8 人各不相同。
static func pick(faction: String, index: int) -> Dictionary:
	var list := templates()
	return list[(absi(hash(faction)) + index) % list.size()]


## 历史人物（非生成、非守备）各子属性的中位数，模板主项不低于它。
static func medians(officers: Dictionary, keys: Array) -> Dictionary:
	var result := {}
	var historical: Array = officers.values().filter(func(o): return not bool(o.get("generated", false)) and not str(o["id"]).begins_with("militia:"))
	for key in keys:
		var values: Array = historical.map(func(o): return float(o.get("skills", {}).get(key, 50)))
		values.sort()
		result[key] = values[values.size() / 2] if not values.is_empty() else 60.0
	return result


## 由 id 与盐值确定的整数。字符串 hash 对只差前缀的 id 相关性很强，再对整数 hash 一次打散。
static func _mix(id: String, salt: String) -> int:
	return absi(hash(hash(id + ":" + salt)))


static func _roll(id: String, salt: String, band: Array) -> int:
	return int(band[0]) + _mix(id, salt) % int(band[1])


## 生成一名模板将领的人物字典（与 officer_context 的人物字段一致）。
## 两个主项里按 hash 选一个“峰值”取主项区间且不低于历史中位，另一个落在副项区间偏上；
## 另从其余子属性里挑一项“偏长”进副项区间，让同模板的人也各有长短。
static func generate(id: String, template: Dictionary, skill_keys: Array, axes: Array, medians_by_key: Dictionary) -> Dictionary:
	var rules := data()
	var primary: Array = template["primary"]
	var peak: String = primary[_mix(id, "peak") % primary.size()]
	var others: Array = skill_keys.filter(func(key): return not key in primary and not key in template["secondary"])
	var quirk: String = others[_mix(id, "quirk") % others.size()]
	var skills := {}
	for key in skill_keys:
		if key == peak: skills[key] = maxi(_roll(id, key, rules["primary"]), int(ceil(float(medians_by_key.get(key, 60)))))
		elif key in primary: skills[key] = _roll(id, key, rules["secondary"]) + 6
		elif key in template["secondary"] or key == quirk: skills[key] = _roll(id, key, rules["secondary"])
		else: skills[key] = _roll(id, key, rules["base"])
	var personality := {}
	for axis in axes: personality[axis] = clampi(_roll(id, axis, rules["personality"]) + int(template["personality"].get(axis, 0)), 0, 100)
	var advantages: Array = template["advantages"]
	var traits := [advantages[_mix(id, "trait") % advantages.size()], template["flaw"]]
	return {"id": id, "skills": skills, "personality": personality, "trait_ids": traits, "career": template["id"], "career_name": template["name"], "positions": template["positions"], "generated": true}
