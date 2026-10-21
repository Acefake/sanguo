extends RefCounted
## 单挑预览的对阵：两名人物取自 data/war/duel_preview.json（人物 id），代码里不写人名。

const Duel = preload("res://scripts/war/duel/duel_system.gd")
const PATH := "res://data/war/duel_preview.json"

class PreviewContext extends RefCounted:
	var rules: Dictionary
	var state: Dictionary = {"tick":0}
	var rng := RandomNumberGenerator.new()

static func build(war) -> Dictionary:
	var pair: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(PATH))
	var fighters: Array = []
	for side in ["left", "right"]:
		var card: Dictionary = war.roster.officers.get(str(pair[side]), {})
		if not card.is_empty():
			fighters.append({"officer_id":card["id"], "stats":card.get("stats", []), "name":card["name"], "skills":card["skills"].duplicate(true), "units":{"cavalry":1}})
	assert(fighters.size() == 2, "Preview officers must exist in the roster")
	var context := PreviewContext.new()
	context.rules = war.rules.duplicate(true)
	context.rng.randomize()
	return {"left":fighters[0], "right":fighters[1], "record":Duel.contest(context, fighters[0], fighters[1])}
