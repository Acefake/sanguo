class_name PersonStore
extends Node
## Autoload「People」：全部人物的运行时状态、按 id 分表的记忆/关系/印象/许诺，以及存档（01 §4、00 §7）。
##
## 人物系统只经这里读写人物，不直接改 campaign_state.state。开局 load_scenario() 读人物卡（经 OfficerRepository）
## 与 data/people/<人物包>/ 的补丁和前史事件，迁到 schema 7、生成 PersonState、写开局记忆；读档 import_state()
## 只还原存档，不再读卡。圈子定义与不上场人物是静态数据，按存档里的剧本 id 重新读取，不进存档。
## P1：relations / impressions / promises 只建表与存读档，由 P3 起的模块填写；不提供战斗侧桥接 runtime_officer()。

const Repository = preload("res://scripts/officers/officer_repository.gd")
const State = preload("res://scripts/people/person_state.gd")
const Migrate = preload("res://scripts/people/card_migrate.gd")
const Memory = preload("res://scripts/people/memory.gd")
const Circles = preload("res://scripts/people/circles.gd")

const VERSION := 1
const DATA_DIR := "res://data/people/"
const XUN_PER_MONTH := 3

var scenario := ""
var xun := 0
var persons: Dictionary = {}
var relations: Dictionary = {}
var memories: Dictionary = {}
var impressions: Dictionary = {}
var promises: Dictionary = {}
var biographies: Dictionary = {}
var offstage: Dictionary = {}
var circles: Dictionary = {}
var _next_mid := 1


## 全局旬号：(年×12 + 月−1)×3 + 旬−1，旬取 1–3（上中下旬）。
static func xun_index(year: int, month: int, xun_in_month: int) -> int:
	return (year * 12 + month - 1) * XUN_PER_MONTH + xun_in_month - 1


static func read_json(path: String) -> Variant:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	assert(parsed != null, "人物数据读取失败：" + path)
	return parsed


## 剧本声明了人物包（people_pack）时载入它，开局日期取剧本的 people_start，没有时用包的默认开局。
## 在 war.setup 之后调用；没有声明时什么都不做并返回 false。
func load_declared(scenario_spec: Dictionary) -> bool:
	if not scenario_spec.has("people_pack"): return false
	return load_scenario(str(scenario_spec["people_pack"]), scenario_spec.get("people_start", {}))


## 开新局：读当前剧本人物卡与人物包 data/people/<pack_id>/ 的补丁、前史事件，生成全部人物并写开局记忆。
## start = {year, month, xun}，为空时用包的 start。开局早于包的 pack.min_start 时拒绝载入、不动当前状态并返回 false。
func load_scenario(pack_id: String, start: Dictionary = {}) -> bool:
	var dir := DATA_DIR + pack_id + "/"
	var seed_events: Dictionary = read_json(dir + "seed_events.json")
	var opening: Dictionary = seed_events["start"] if start.is_empty() else start
	var earliest: Dictionary = seed_events["pack"]["min_start"]
	if _xun_of(opening) < _xun_of(earliest):
		push_warning("人物包 %s 最早 %d 年 %d 月开局，剧本开局 %d 年 %d 月，不载入" % [pack_id, earliest["year"], earliest["month"], opening["year"], opening["month"]])
		return false
	setup_from_scenario(pack_id, Repository.cards(), read_json(dir + "persons_s7.json"), opening)
	Memory.seed(self, seed_events, read_json(DATA_DIR + "memory_rules.json"))
	return true


## 由人物卡（schema 6 或 7）与 schema 7 补丁建立全部人物；start = {year, month, xun} 是开局日期。
func setup_from_scenario(scenario_id: String, cards: Array, patches: Array, start: Dictionary) -> void:
	_reset(scenario_id)
	xun = xun_index(int(start["year"]), int(start["month"]), int(start["xun"]))
	for card in Migrate.migrate_all(cards, patches):
		persons[str(card["id"])] = Migrate.to_state(card, xun)


static func _xun_of(date: Dictionary) -> int:
	return xun_index(int(date["year"]), int(date["month"]), int(date.get("xun", 1)))


func get_person(id: String) -> State:
	return persons.get(id)


func by_faction(faction: String) -> Array[State]:
	var out: Array[State] = []
	for state in persons.values():
		if state.faction == faction: out.append(state)
	return out


## 亲族：此人卡上列的亲族，加上把此人列为亲族的在场人物。
func kin_of(id: String) -> Array[String]:
	var out: Array[String] = []
	var state: State = persons.get(id)
	if state != null:
		for link in state.kin: out.append(str(link["to"]))
	for other in persons.values():
		if other.id == id or other.id in out: continue
		for link in other.kin:
			if str(link["to"]) == id:
				out.append(other.id)
				break
	return out


## 同势力的其他在场人物（不含本人），按人物卡顺序；此人不在场或没有势力时为空。
func court_of(id: String) -> Array[String]:
	var out: Array[String] = []
	var state: State = persons.get(id)
	if state == null or state.faction.is_empty(): return out
	for other in by_faction(state.faction):
		if other.id != id: out.append(other.id)
	return out


## 同圈子的人（不含本人），按圈子顺序去重。
func circle_mates(id: String) -> Array[String]:
	var out: Array[String] = []
	var state: State = persons.get(id)
	if state == null: return out
	for circle_id in state.circles:
		for member in Circles.members(circles.get(circle_id, {}), persons):
			if member != id and member not in out: out.append(member)
	return out


## 对象 id 的种类：在场或不上场人物为 person，其余按城池。
func object_kind(id: String) -> String:
	return "person" if persons.has(id) or offstage.has(id) else "city"


## 给 owner 追加一条记忆，分配全局递增的 mid。
func add_memory(owner: String, entry: Dictionary) -> Dictionary:
	var stored := entry.duplicate(true)
	stored["mid"] = "m_%06d" % _next_mid
	_next_mid += 1
	if not memories.has(owner): memories[owner] = []
	memories[owner].append(stored)
	return stored


func export_state() -> Dictionary:
	var person_dicts := {}
	for id in persons: person_dicts[id] = persons[id].to_dict()
	return {
		"people_version": VERSION, "scenario": scenario, "xun": xun, "next_mid": _next_mid,
		"persons": person_dicts, "relations": relations.duplicate(true), "memories": memories.duplicate(true),
		"impressions": impressions.duplicate(true), "promises": promises.duplicate(true), "biographies": biographies.duplicate(true),
	}


## 还原 export_state() 的结果。版本不认识时不动当前状态并返回 false。
func import_state(data: Dictionary) -> bool:
	if int(data.get("people_version", 0)) != VERSION:
		push_warning("人物存档版本 %s 无法读取，保留当前人物状态" % str(data.get("people_version", "缺失")))
		return false
	_reset(str(data.get("scenario", "")))
	xun = int(data.get("xun", 0))
	_next_mid = int(data.get("next_mid", 1))
	for id in data.get("persons", {}): persons[id] = State.from_dict(data["persons"][id])
	relations = data.get("relations", {}).duplicate(true)
	memories = data.get("memories", {}).duplicate(true)
	impressions = data.get("impressions", {}).duplicate(true)
	promises = data.get("promises", {}).duplicate(true)
	biographies = data.get("biographies", {}).duplicate(true)
	return true


func _reset(scenario_id: String) -> void:
	scenario = scenario_id
	xun = 0
	_next_mid = 1
	for table in [persons, relations, memories, impressions, promises, biographies, offstage, circles]: table.clear()
	if scenario_id.is_empty(): return
	for entry in read_json(DATA_DIR + "offstage.json"): offstage[str(entry["id"])] = entry
	for entry in read_json(DATA_DIR + "circles.json"): circles[str(entry["id"])] = entry
