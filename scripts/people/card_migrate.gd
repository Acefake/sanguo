class_name CardMigrate
extends RefCounted
## 人物卡 schema 6 → 7，以及 schema 7 卡 → PersonState（01-人物数据模型 §2）。
##
## migrate() 按 id 把剧本补丁（data/people/<剧本>/persons_s7.json 的一条）并入人物卡：旧字段不删，
## 卡上已有的值不覆盖；补丁也没有心志时按 drives.json.infer_from_card 推定，并登记到 inferred。
## 两处例外：补丁的 relations 整体替换卡上 relations（卡上 to 是显示名，补丁 to 是人物 id；
## {group: direct_peers} 这类分组边原样保存，P3 再展开）；补丁的 faction_id 是世界剧本势力 id，卡上 faction 显示名保留。
## 同一张卡迁移两次结果不变。只读 data/people/drives.json，不写任何状态。

const Card = preload("res://scripts/officers/officer_card.gd")
const Roster = preload("res://scripts/agents/officer_context.gd")
const State = preload("res://scripts/people/person_state.gd")

const SCHEMA := 7
const DRIVES_PATH := "res://data/people/drives.json"
## schema 7 新增字段与缺省值。
const S7_FIELDS := {"birth_year": 0, "origin": {}, "kin": [], "drives": [], "habits": [], "career": [],
	"knots": [], "fame": {}, "circles": [], "hidden": []}
const REVENGE_KNOT_INTENSITY := 60
const REVENGE_SCORE := 0.8
## 次高分达到最高分的这个比例才保留第二心志（drives.json.infer_from_card.pick）。
const KEEP_SECOND_RATIO := 0.85

static var _drives_doc: Dictionary = {}


## 一张卡迁到 schema 7。patch 为空时只补缺省值和推定心志；patch 的 id 必须与卡一致。
static func migrate(card: Dictionary, patch: Dictionary = {}) -> Dictionary:
	assert(patch.is_empty() or str(patch.get("id", "")) == str(card.get("id", "")), "补丁 id 与人物卡不一致")
	var out := card.duplicate(true)
	var inferred: Array = out.get("inferred", []).duplicate()
	for field in S7_FIELDS:
		if _filled(out.get(field)): continue
		var value: Variant = patch.get(field, S7_FIELDS[field])
		if not _filled(value): value = S7_FIELDS[field]
		out[field] = value.duplicate(true) if value is Dictionary or value is Array else value
	if patch.has("relations"): out["relations"] = patch["relations"].duplicate(true)
	if patch.has("faction_id"): out["faction_id"] = str(patch["faction_id"])
	for entry in patch.get("inferred", []):
		if entry not in inferred: inferred.append(entry)
	if out["drives"].is_empty():
		out["drives"] = infer_drives(out)
		if "drives" not in inferred: inferred.append("drives")
	out["inferred"] = inferred
	out["schema_version"] = SCHEMA
	return out


## 整个剧本迁移：patches 按 id 对上人物卡，没有补丁的卡也照样迁移。
static func migrate_all(cards: Array, patches: Array) -> Array:
	var by_id := {}
	for patch in patches: by_id[str(patch["id"])] = patch
	var out: Array = []
	for card in cards: out.append(migrate(card, by_id.get(str(card["id"]), {})))
	return out


## 按卡面推定心志，只做兜底（补丁有 drives 时不调用）：八种心志各算一个分，取最高者；次高 ≥ 最高×keep_second_ratio
## 时保留为第二心志，两条按分数归一，单条权重 1.0。公式见 drives.json.infer_from_card，只用 schema 6 卡已有字段。
static func infer_drives(card: Dictionary) -> Array:
	var scores := drive_scores(card)
	var ranked := ranked_drives(card)
	var first: String = ranked[0]
	var second: String = ranked[1]
	if scores[first] <= 0.0 or scores[second] < scores[first] * KEEP_SECOND_RATIO:
		return [{"id": first, "weight": 1.0}]
	var w1 := snappedf(scores[first] / (scores[first] + scores[second]), 0.01)
	return [{"id": first, "weight": w1}, {"id": second, "weight": snappedf(1.0 - w1, 0.01)}]


## 八种心志按推定分从高到低排列。
static func ranked_drives(card: Dictionary) -> Array:
	var scores := drive_scores(card)
	var ranked: Array = drives_doc()["ids"].duplicate()
	ranked.sort_custom(func(a, b): return scores[a] > scores[b])
	return ranked


## 心志 id → 推定分（drives.json.infer_from_card.score）。
static func drive_scores(card: Dictionary) -> Dictionary:
	var p: Dictionary = card.get("personality", {})
	var values: Dictionary = p.get("values", {})
	var weights: Dictionary = p.get("decision_weights", {})
	var loyalty: Dictionary = p.get("loyalty", {})
	var attrs: Dictionary = card.get("attributes", {})
	var risk := float(p.get("risk_preference", 0.5))
	var gong := float(weights.get("个人功业", weights.get("功业偏好", values.get("功业", 0.0))))
	var faith := _num(attrs, "信义") / 100.0
	var wits := _num(attrs, "智计") / 100.0
	var learned := not _common(card.get("habits", []), drives_doc()["infer_from_card"]["learning_habits"]).is_empty()
	return {
		"功名": 0.5 * _num(values, "功业") + 0.3 * gong + 0.2 * risk + (0.1 if _num(attrs, "武艺") >= 85 else 0.0),
		"忠义": 0.4 * _num(loyalty, "承诺坚持") + 0.35 * _num(loyalty, "私人依附") + 0.25 * faith - 0.15,
		"财货": 0.8 * _num(values, "个人利益") + 0.2 * (1.0 - faith) - 0.15,
		"家族": 0.4 * _num(loyalty, "私人依附") + (0.25 if not card.get("kin", []).is_empty() else 0.0) - 0.1,
		"天下": 0.45 * _num(values, "群体利益") + 0.3 * _num(values, "秩序") + 0.25 * wits - 0.25 + (0.1 if wits >= 0.88 else 0.0),
		"安身": 0.5 * _num(weights, "损失厌恶") + 0.5 * (1.0 - risk) - 0.3,
		"学问": 0.3 * wits - 0.2 + (0.4 if learned else 0.0),
		"报仇": REVENGE_SCORE if _has_revenge_knot(card) else 0.0,
	}


## schema 7 卡生成开局运行时状态；xun 为开局全局旬号，卡上心结从这一旬算起。
static func to_state(card: Dictionary, xun: int) -> State:
	var state := State.new()
	state.id = str(card["id"])
	state.faction = str(card.get("faction_id", ""))
	state.birth_year = int(card.get("birth_year", 0))
	state.origin = card.get("origin", {}).duplicate(true)
	state.kin = card.get("kin", []).duplicate(true)
	state.circles.assign(card.get("circles", []))
	state.hidden.assign(card.get("hidden", []))
	state.axes = Card.personality_axes(card, Roster.AXES)["personality"]
	state.axes_base = state.axes.duplicate()
	state.habits.assign(card.get("habits", []))
	state.drives = card.get("drives", []).duplicate(true)
	for drive in state.drives: state.drive_meter[str(drive["id"])] = 0
	state.traits.assign(Card.trait_ids(card))
	state.career.assign(card.get("career", []))
	for knot in card.get("knots", []):
		var entry: Dictionary = knot.duplicate(true)
		entry["since_xun"] = xun
		state.knots.append(entry)
	state.fame = card.get("fame", {}).duplicate(true)
	return state


static func drives_doc() -> Dictionary:
	if _drives_doc.is_empty():
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(DRIVES_PATH))
		assert(parsed is Dictionary, "心志数据读取失败：" + DRIVES_PATH)
		_drives_doc = parsed
	return _drives_doc


static func _has_revenge_knot(card: Dictionary) -> bool:
	for knot in card.get("knots", []):
		if not knot.get("object", {}).is_empty() and float(knot.get("intensity", 0)) >= REVENGE_KNOT_INTENSITY: return true
	return false


static func _common(a: Array, b: Array) -> Array:
	return a.filter(func(entry): return entry in b)


static func _num(source: Dictionary, key: String) -> float:
	return float(source.get(key, 0.0))


static func _filled(value: Variant) -> bool:
	if value == null: return false
	if value is Dictionary or value is Array or value is String: return not value.is_empty()
	return float(value) != 0.0
