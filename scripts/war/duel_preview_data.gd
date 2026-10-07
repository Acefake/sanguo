extends RefCounted

const Duel = preload("res://scripts/war/duel_system.gd")

class PreviewContext extends RefCounted:
	var rules: Dictionary
	var rng := RandomNumberGenerator.new()

static func build(war) -> Dictionary:
	var fighters: Array = []
	for name in ["关羽", "颜良"]:
		for card in war.roster.officers.values():
			if card.get("name", "") == name:
				fighters.append({"name":name, "skills":card["skills"].duplicate(true), "units":{"cavalry":1}})
				break
	assert(fighters.size() == 2, "Preview officers must exist in the roster")
	var context := PreviewContext.new()
	context.rules = war.rules.duplicate(true)
	context.rng.randomize()
	return {"left":fighters[0], "right":fighters[1], "record":Duel.contest(context, fighters[0], fighters[1])}
