class_name OfficerContext
extends RefCounted
## 将领名册：由人物卡建立运行时人物字典，补足乡勇与各势力武将；人格轴与技能分组的定义。

const AXES := ["野心", "风险承受", "耐心", "决断", "自制", "猜疑", "自尊", "同理心", "秩序偏好", "务实", "记仇", "容人", "贪欲", "忠义"]
const SKILLS := [["带兵", "布阵", "水练", "奇袭", "治军"], ["智计", "沉着", "料敌", "应变", "辩才"], ["膂力", "体魄", "武艺", "骑术", "箭术"], ["农桑", "商贾", "吏治", "律法", "辞令"], ["威仪", "仁德", "忠义", "名望", "雅量"]]
var officers: Dictionary = {}
var parsing_audit: Array = []
const Careers = preload("res://scripts/officers/career_templates.gd")
const Card = preload("res://scripts/officers/officer_card.gd")
## 运行时额外键：GDD 有、旧 25 键没有的子属性。
const EXTRA_SKILLS := ["攻坚"]

## 读入人物卡（schema 6），经 OfficerCard 换算成运行时人物字典；换算来源记在 data_sources 与 parsing_audit。
func setup(cards: Array, mapping: Dictionary) -> void:
	officers.clear()
	parsing_audit.clear()
	for card in cards:
		var skills := Card.runtime_skills(card)
		var personality := Card.personality_axes(card, AXES)
		var sources := {"skills": skills["sources"], "personality": personality["sources"]}
		parsing_audit.append({"id": card["id"], "sources": sources.duplicate(true)})
		officers[str(card["id"])] = {"id": str(card["id"]), "name": str(card["name"]), "faction": faction_id(card, mapping), "stats": Card.dimensions(card), "skills": skills["skills"], "personality": personality["personality"], "trait_ids": Card.trait_ids(card), "portrait": str(card.get("thumbnail", "")), "positions": Card.positions_text(card), "profile_note": str(card.get("summary", "")).left(350), "relations": card.get("relations", []).duplicate(true), "failure_modes": card.get("failure_modes", []).duplicate(true), "data_sources": sources}


## 人物卡的势力 id：卡上有 faction_id 时直接用，否则把显示名 faction 经剧本的 faction_mapping 换算；都没有为 ""。
static func faction_id(card: Dictionary, mapping: Dictionary) -> String:
	if card.has("faction_id"): return str(card["faction_id"])
	return str(mapping.get(str(card.get("faction", "")), ""))


func militia(faction: String, city: String) -> String:
	var id: String = "militia:" + faction + ":" + city
	if not officers.has(id):
		var skills: Dictionary = {}
		for row in SKILLS:
			for skill in row:
				skills[skill] = 50
		for skill in EXTRA_SKILLS: skills[skill] = 50
		var personality: Dictionary = {}
		for axis in AXES:
			personality[axis] = 50
		officers[id] = {"id": id, "name": "守备将", "battlefield_role":"guard", "positions":"核心位置：守备", "faction": faction, "skills": skills, "personality": personality, "portrait": "", "profile_note": "地方守备，遵守守城与保全部队的任务。"}
	return id

## 剧本缺少历史人物时，按职业模板补足生成将（每势力至少 max(3, 城数+2) 人）。
## 名字写明模板，不冒充历史人物；全部取值由 id 的 hash 决定，可复现。
func ensure_factions(scenario: Dictionary) -> void:
	var keys: Array = []
	for row in SKILLS: keys.append_array(row)
	keys.append_array(EXTRA_SKILLS)
	# 中位数只在需要补生成武将时才算：每日两次的势力维护里几乎从不生成，却每次都要对全部武将逐项排序。
	# 第一次用到时还没有新增武将，所以与在函数开头计算的结果相同。
	var medians := {}
	for faction in scenario.get("factions", {}):
		var cities: Array = []
		for city in scenario.get("places", {}):
			if scenario["places"][city].has("population") and scenario["places"][city].get("faction", "") == faction: cities.append(city)
		if cities.is_empty(): continue
		cities.sort()
		var count := 0
		for officer in officers.values():
			if officer.get("faction", "") == faction and not str(officer["id"]).begins_with("militia:"): count += 1
		var index := -1
		while count < maxi(3, cities.size() + 2):
			index += 1
			var id := "local:%s:%d" % [faction, index]
			if officers.has(id): continue
			count += 1
			if medians.is_empty(): medians = Careers.medians(officers, keys)
			var template := Careers.pick(faction, index)
			var officer := Careers.generate(id, template, keys, AXES, medians)
			var name := str(scenario["factions"][faction].get("name", faction))
			officer.merge({"name": name + ("·代行主政" if index == 0 else "·%s%d" % [template["name"], index]), "faction": faction, "portrait": "", "home": cities[index % cities.size()], "profile_note": "地方%s，补足当前剧本缺少的武将资料。" % template["name"]})
			# 代行主政仍是君主，岗位轮廓沿用模板。
			if index == 0: officer["positions"] = "核心位置：君主\n" + str(template["positions"]).replace("核心位置", "次选位置")
			officers[id] = officer


# 旧档可能带着已经不存在的占位 ID（势力前缀与存档不符时尤其明显）。登记之后必须
# 把 ID 原样登记并回写，否则军队的 officer_id 仍是悬空引用，后续任何
# roster.officers[...] 直接下标都会崩。
func adopt_militia(army: Dictionary) -> String:
	var faction := str(army.get("faction", ""))
	var wanted := str(army.get("officer_id", ""))
	if wanted != "" and officers.has(wanted): return wanted
	var city := wanted.trim_prefix("militia:" + faction + ":")
	if city == wanted or city == "":
		city = str(army.get("home", "")).trim_prefix("militia:" + faction + ":")
	if city == "": city = str(army.get("target", ""))
	if city == "": city = str(army.get("home", army.get("id", "unknown")))
	var template := militia(faction, city)
	var resolved := wanted if wanted.begins_with("militia:") else template
	if resolved != template:
		officers[resolved] = officers[template].duplicate(true)
		officers[resolved]["id"] = resolved
	officers[resolved]["faction"] = faction
	return resolved
