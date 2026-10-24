extends RefCounted
## 战场喊话（项目自写，不引原作台词）。
##
## 台词在 data/war/battle_chatter.json：lines 按事件给通用台词，personal 按人物 id 给个人台词，
## 有个人台词时优先。代码里不写人名。

const PATH := "res://data/war/battle_chatter.json"
static var _data: Dictionary = {}


## officer_id 的人物在 event 时说的话；没有个人台词时按 variation 取通用台词，未知事件按 hold。
static func line_for(officer_id: String, event: String, variation: int) -> String:
	if _data.is_empty(): _data = JSON.parse_string(FileAccess.get_file_as_string(PATH))
	var personal: Dictionary = _data["personal"].get(officer_id, {})
	if personal.has(event): return personal[event]
	var lines: Dictionary = _data["lines"]
	var options: Array = lines.get(event, lines["hold"])
	return options[posmod(variation, options.size())]
