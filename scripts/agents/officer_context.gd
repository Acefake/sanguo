extends RefCounted

const AXES := ["野心", "风险承受", "耐心", "决断", "自制", "猜疑", "自尊", "同理心", "秩序偏好", "务实", "记仇", "容人", "贪欲", "忠义"]
const SKILLS := [["带兵", "布阵", "水练", "奇袭", "治军"], ["智计", "沉着", "料敌", "应变", "辩才"], ["膂力", "体魄", "武艺", "骑术", "箭术"], ["农桑", "商贾", "吏治", "律法", "辞令"], ["威仪", "仁德", "忠义", "名望", "雅量"]]
var officers: Dictionary = {}
var parsing_audit: Array = []
const Battle = preload("res://scripts/war/battle/officer_battle.gd")

static func numeric(value: Variant, maximum: int) -> Dictionary:
	if typeof(value) not in [TYPE_INT,TYPE_FLOAT] and not (value is String and value.is_valid_float()): return {"value":50,"source":"invalid_default"}
	var number := float(value)
	if is_nan(number) or is_inf(number): return {"value":50,"source":"invalid_default"}
	return {"value":int(clampf(number,0,maximum)),"source":"clamped_card" if number < 0 or number > maximum else "card"}


func setup(cards: Array, mapping: Dictionary) -> void:
	officers.clear()
	parsing_audit.clear()
	for card in cards:
		var skills: Dictionary = {}
		var sources := {"skills":{},"personality":{}}
		var rows: Array = card.get("substats", []) if card.get("substats",[]) is Array else []
		for row in range(mini(rows.size(), SKILLS.size())):
			if not rows[row] is Array: continue
			for col in range(mini(rows[row].size(), SKILLS[row].size())):
				var parsed := numeric(rows[row][col],120)
				skills[SKILLS[row][col]] = parsed["value"]
				sources["skills"][SKILLS[row][col]] = parsed["source"]
		for group in SKILLS:
			for skill in group:
				if not skills.has(skill): skills[skill] = 50; sources["skills"][skill] = "missing_default"
		var personality: Dictionary = {}
		var text: String = str(card.get("sections", {}).get("人格数值", "")).replace("记仄", "记仇")
		for axis in AXES:
			var regex := RegEx.new()
			regex.compile(axis + "[\\s:：=]*([+-]?[0-9]+(?:\\.[0-9]+)?)")
			var match_value := regex.search(text)
			var parsed := numeric(match_value.get_string(1),100) if match_value != null else {"value":50,"source":"invalid_default" if text.contains(axis) else "missing_default"}
			personality[axis] = parsed["value"]
			sources["personality"][axis] = parsed["source"]
		parsing_audit.append({"id":card["id"],"sources":sources.duplicate(true)})
		# Keep parsing provenance separate from the card's original values.
		officers[str(card["id"])] = {"id": str(card["id"]), "name": str(card["name"]), "faction": str(mapping.get(str(card.get("faction", "")), "")), "stats": card.get("stats", []).duplicate(), "skills": skills, "personality": personality, "battle_traits": Battle.traits(card), "portrait": card.get("thumbnail", ""), "positions": str(card.get("sections", {}).get("位置", "")), "profile_note": str(card.get("sections", {}).get("核心定义", "")).left(350)}
		officers[str(card["id"])]["data_sources"] = sources


func militia(faction: String, city: String) -> String:
	var id: String = "militia:" + faction + ":" + city
	if not officers.has(id):
		var skills: Dictionary = {}
		for row in SKILLS:
			for skill in row:
				skills[skill] = 50
		var personality: Dictionary = {}
		for axis in AXES:
			personality[axis] = 50
		officers[id] = {"id": id, "name": "守备将", "battlefield_role":"guard", "positions":"核心位置：守备", "faction": faction, "skills": skills, "personality": personality, "portrait": "", "profile_note": "地方守备，遵守守城与保全部队的任务。"}
	return id

# Deterministic local officers keep incomplete historical data playable. Their
# names explicitly identify the role; they are not fabricated historical cards.
func ensure_factions(scenario: Dictionary) -> void:
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
			var skills := {}
			for row in SKILLS:
				for skill in row: skills[skill] = 55 + absi(hash(id + str(skill))) % 21
			var personality := {}
			for axis in AXES: personality[axis] = 40 + absi(hash(id + str(axis))) % 31
			var name := str(scenario["factions"][faction].get("name", faction))
			officers[id] = {"id": id, "name": name + ("·代行主政" if index == 0 else "·地方将%d" % index), "faction": faction, "skills": skills, "personality": personality, "battle_traits": [], "portrait": "", "positions": "核心位置：君主" if index == 0 else "地方将领", "generated": true, "home": cities[index % cities.size()], "profile_note": "地方代理将领，补足当前剧本缺少的武将资料。"}


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
