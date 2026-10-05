extends RefCounted

const AXES := ["野心", "风险承受", "耐心", "决断", "自制", "猜疑", "自尊", "同理心", "秩序偏好", "务实", "记仇", "容人", "贪欲", "忠义"]
const SKILLS := [["带兵", "布阵", "水练", "奇袭", "治军"], ["智计", "沉着", "料敌", "应变", "辩才"], ["膂力", "体魄", "武艺", "骑术", "箭术"], ["农桑", "商贾", "吏治", "律法", "辞令"], ["威仪", "仁德", "忠义", "名望", "雅量"]]
var officers: Dictionary = {}
const Battle = preload("res://scripts/war/officer_battle.gd")


func setup(cards: Array, mapping: Dictionary) -> void:
	for card in cards:
		var skills: Dictionary = {}
		var rows: Array = card.get("substats", [])
		for row in range(mini(rows.size(), SKILLS.size())):
			for col in range(mini(rows[row].size(), SKILLS[row].size())):
				skills[SKILLS[row][col]] = clampi(int(rows[row][col]), 0, 120)
		var personality: Dictionary = {}
		var text: String = str(card.get("sections", {}).get("人格数值", "")).replace("记仄", "记仇")
		for axis in AXES:
			var regex := RegEx.new()
			regex.compile(axis + "\\s*(\\d{1,3})")
			var match_value := regex.search(text)
			personality[axis] = clampi(int(match_value.get_string(1)), 0, 100) if match_value != null else 50
		officers[str(card["id"])] = {"id": str(card["id"]), "name": str(card["name"]), "faction": str(mapping.get(str(card.get("faction", "")), "")), "skills": skills, "personality": personality, "battle_traits": Battle.traits(card), "portrait": card.get("thumbnail", ""), "positions": str(card.get("sections", {}).get("位置", "")), "profile_note": str(card.get("sections", {}).get("核心定义", "")).left(350)}


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
		officers[id] = {"id": id, "name": "守备将", "faction": faction, "skills": skills, "personality": personality, "portrait": "", "profile_note": "地方守备，遵守守城与保全部队的任务。"}
	return id
