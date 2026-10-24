class_name PersonState
extends RefCounted
## 一个人物的运行时状态（01-人物数据模型 §3）。
##
## 开局由 CardMigrate.to_state() 从 schema 7 人物卡生成，之后只由 scripts/people/* 修改；读档时从
## to_dict() 的结果还原，不再读卡。字段只用 Dictionary/Array/基本类型，保证能原样序列化。
## 关系、记忆、印象数据量大，不放在这里，由 PersonStore 按 id 分表保存。
## 访问器只读；P1 不做伤病、年龄对属性的修正（属于 05 成长与一生）。

var id := ""
var alive := true
var status := "serving"
var faction := ""
var lord := ""
var post := ""
var location := ""

var attrs: Dictionary = {}
var potentials: Dictionary = {}
var xp: Dictionary = {}
var birth_year := 0

var origin: Dictionary = {}
var kin: Array = []
var circles: Array[String] = []
var hidden: Array[String] = []

var axes: Dictionary = {}
var axes_base: Dictionary = {}
var habits: Array[String] = []

var drives: Array = []
var drive_meter: Dictionary = {}

var traits: Array[String] = []
var career: Array[String] = []
var knots: Array = []
var fame: Dictionary = {}

var health := 100
var injuries: Array = []
var mood := 50
var stress := 0

const _FIELDS := ["id", "alive", "status", "faction", "lord", "post", "location", "attrs", "potentials", "xp", "birth_year",
	"origin", "kin", "circles", "hidden", "axes", "axes_base", "habits", "drives", "drive_meter", "traits", "career",
	"knots", "fame", "health", "injuries", "mood", "stress"]
const _INT_FIELDS := ["birth_year", "health", "mood", "stress"]


## 年龄：当前年份减生年；生年未知时返回 0。
func age(current_year: int) -> int:
	return current_year - birth_year if birth_year > 0 else 0


## 属性当前值；没有这项时返回 0。
func attr(key: String) -> float:
	return float(attrs.get(key, 0))


## 人格轴当前值；没有这条轴时按中值 50。
func axis(axis_name: String) -> float:
	return float(axes.get(axis_name, 50))


## 某种心志的权重；没有时为 0。
func drive_weight(drive_id: String) -> float:
	for drive in drives:
		if str(drive["id"]) == drive_id: return float(drive["weight"])
	return 0.0


func has_habit(habit_id: String) -> bool:
	return habit_id in habits


## 指向某对象的心结；没有时返回空字典。
func knot_on(kind: String, obj_id: String) -> Dictionary:
	for knot in knots:
		var target: Dictionary = knot.get("object", {})
		if str(target.get("kind", "")) == kind and str(target.get("id", "")) == obj_id: return knot
	return {}


func to_dict() -> Dictionary:
	var out := {}
	for field in _FIELDS:
		var value: Variant = get(field)
		out[field] = value.duplicate(true) if value is Dictionary or value is Array else value
	return out


static func from_dict(data: Dictionary) -> PersonState:
	var state := new()
	for field in _FIELDS:
		if not data.has(field): continue
		var value: Variant = data[field]
		if field in _INT_FIELDS: value = int(value)
		var current: Variant = state.get(field)
		if current is Array:
			current.assign(value.duplicate(true))
		elif current is Dictionary:
			state.set(field, value.duplicate(true))
		else:
			state.set(field, value)
	return state
