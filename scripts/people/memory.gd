class_name PeopleMemory
extends RefCounted
## 主观记忆（03-记忆与心结）。P1 只实现开局 seed()；ingest/decay/top_for 等在 P3。
##
## 开局记忆不手写：前史事件（data/people/<剧本>/seed_events.json）走 data/people/memory_rules.json，
## 一条事件按规则给多个人写各自的记忆，再按「开局旬号 − 事件旬号」线性衰减：
## intensity = max(base − base × r × 经过旬数, base × floor_ratio)，r 与 floor_ratio 按 weight_class 分轻/中/重三档，
## 重档保底 base×0.4；data.tag 为 key_moment.tag（「关口」）的事件 r 乘 key_moment.r_mult（减半）；
## 强度不超过 drop_below 的不写。只用不晚于开局旬的事件（事件只记到月，按当月上旬算）。bio=true 的事件同时进当事人的生平。
## P1 不乘性格系数（记仇、自尊等），与 Python 参考预演同序同值。
## 读 store.persons / store.circles，写 store.memories / store.biographies。

## 需要战场或任职上下文才能求出的接收方（同城同军的目击者、同岗位的竞争者）；前史事件没有这些上下文，开局时跳过。
const Store = preload("res://scripts/people/person_store.gd")

const CONTEXT_ONLY_RECIPIENTS := ["witnesses", "rivals_same_post"]
const DEFAULT_WEIGHT_CLASS := "mid"


## 把前史事件写成开局记忆与生平。store 须已 setup_from_scenario，开局旬号取 store.xun。
static func seed(store: Store, events_doc: Dictionary, rules: Dictionary) -> void:
	var classes := weight_classes(rules)
	var key_moment: Dictionary = rules["key_moment"]
	for event in events_doc["events"]:
		var event_xun := Store.xun_index(int(event["year"]), int(event["month"]), 1)
		if event_xun > store.xun: continue
		if bool(event.get("bio", false)): _record_bio(store, event)
		var r_mult := float(key_moment["r_mult"]) if str(event["data"].get("tag", "")) == str(key_moment["tag"]) else 1.0
		for rule in rules["events"].get(str(event["kind"]), []):
			if not _condition_holds(rule, event): continue
			var about_id := _about(str(rule["about"]), event)
			var weight_class: String = classes.get(str(rule["kind"]), DEFAULT_WEIGHT_CLASS)
			var intensity := decayed(float(rule["base"]), weight_class, store.xun - event_xun, rules, r_mult)
			if intensity <= float(rules["drop_below"]): continue
			for owner in _recipients(str(rule["who"]), event, store):
				if not store.persons.has(owner) or owner == about_id: continue
				store.add_memory(owner, {
					"owner": owner, "xun": event_xun, "kind": str(rule["kind"]),
					"about": {} if about_id.is_empty() else {"kind": store.object_kind(about_id), "id": about_id},
					"event_ref": str(event["eid"]), "valence": int(rule["valence"]),
					"intensity": intensity, "base": float(rule["base"]),
					"tags": rule.get("tags", []).duplicate(), "public": bool(rule.get("public", false)),
				})


## 经过 elapsed 旬后的强度：线性衰减，不低于该档保底。r_mult 是关口事件的衰减倍率。
static func decayed(base: float, weight_class: String, elapsed: int, rules: Dictionary, r_mult: float = 1.0) -> float:
	var r := float(rules["decay_r"][weight_class]) * r_mult
	return maxf(base - base * r * elapsed, base * float(rules["floor_ratio"][weight_class]))


## 记忆 kind → 衰减档（light/mid/heavy）。
static func weight_classes(rules: Dictionary) -> Dictionary:
	var out := {}
	for weight_class in rules["weight_class"]:
		for kind in rules["weight_class"][weight_class]: out[kind] = weight_class
	return out


static func _record_bio(store: Store, event: Dictionary) -> void:
	var owners: Array = [str(event["actor"])]
	owners.append_array(event["data"].get("bio_also", []))
	for owner in owners:
		if not store.persons.has(owner): continue
		if not store.biographies.has(owner): store.biographies[owner] = []
		store.biographies[owner].append({"eid": str(event["eid"]), "year": int(event["year"]), "month": int(event["month"]),
			"kind": str(event["kind"]), "tag": str(event["data"].get("tag", "")), "text": str(event.get("text", ""))})


## 规则的 if 只有「data.<键> != ''」一种写法：该键有非空值才成立。
static func _condition_holds(rule: Dictionary, event: Dictionary) -> bool:
	if not rule.has("if"): return true
	var condition := str(rule["if"])
	assert(condition.begins_with("data.") and condition.ends_with("!= ''"), "不支持的记忆规则条件：" + condition)
	var value: Variant = event["data"].get(condition.get_slice(" ", 0).trim_prefix("data."), "")
	return value != null and not str(value).is_empty()


## 规则的 about 指向的对象 id；没有时为空串。
static func _about(about: String, event: Dictionary) -> String:
	var data: Dictionary = event["data"]
	match about:
		"actor", "target": return str(event[about])
		"lord", "enemy_commander": return str(data.get(about, ""))
	if about.begins_with("data."): return str(data.get(about.trim_prefix("data."), ""))
	return ""


## 规则的 who 解析成接收记忆的人物 id，去重保序。
static func _recipients(who: String, event: Dictionary, store: Store) -> Array[String]:
	var data: Dictionary = event["data"]
	var actor := str(event["actor"])
	var found: Array = []
	match who:
		"actor": found = [actor]
		"target": found = [str(event["target"])]
		"lord", "enemy_commander": found = [str(data.get(who, ""))]
		"participants", "former_subordinates", "rival_advisers": found = data.get(who, [])
		"kin_of_actor": found = store.kin_of(actor)
		"kin_of_target": found = store.kin_of(str(event["target"]))
		"circle_of_actor": found = store.circle_mates(actor)
		"court": found = store.court_of(actor)
		_:
			if who.begins_with("data."): found = [str(data.get(who.trim_prefix("data."), ""))]
			else: assert(who in CONTEXT_ONLY_RECIPIENTS, "未知的记忆接收方：" + who)
	var out: Array[String] = []
	for id in found:
		if not str(id).is_empty() and str(id) not in out: out.append(str(id))
	return out
