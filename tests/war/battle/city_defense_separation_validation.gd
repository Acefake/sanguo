extends SceneTree
## 可在无 Autoload 的最小项目运行；不依赖战役或模型服务。
const Defense = preload("res://scripts/war/battle/city_defense.gd")
const Fort = preload("res://scripts/war/battle/city_fortifications.gd")

class Store extends RefCounted:
	var city := {"defense": 50, "garrison": 1000, "faction": "defender"}
	func city_state(_node: String) -> Dictionary: return city

class War extends RefCounted:
	var store := Store.new()
	var state := {"tick": 1, "sieges": {}}
	var armies: Array = []
	var rules := preload("res://scripts/war/battle/battle_terrain.gd").rules()
	func active_armies() -> Array: return armies
	func hostile(a: String, b: String) -> bool: return a != b

func army(type: String, count: int) -> Dictionary:
	var result := {"units": {"infantry": 0, "archers": 0, "cavalry": 0}, "faction": "attacker", "status": "active", "returning": false, "training": 50, "equipment": 50, "organization": 100, "fatigue": 0, "morale": 100}
	result["units"][type] = count
	return result

func _initialize() -> void:
	var war := War.new()
	var infantry := army("infantry", 8000)
	var cavalry := army("cavalry", 8000)
	var archers := army("archers", 8000)
	var siege := Defense.create(war, "city", infantry)
	war.state["sieges"]["city"] = siege
	assert(siege["wall"] == 200 and siege["gate"] == 100)
	assert(not Defense.breach_open(war, "city"))
	assert(Defense.facility_power(war, [cavalry, archers])["total"] == 0)
	var snapshot := siege.duplicate(true)
	Defense.damage_facilities(war, "city", siege, [cavalry, archers])
	assert(siege["wall"] == snapshot["wall"] and siege["gate"] == snapshot["gate"])
	Defense.damage_facilities(war, "city", siege, [infantry])
	assert(siege["wall"] < snapshot["wall"] and siege["gate"] < snapshot["gate"])
	assert(war.store.city["garrison"] == 1000)
	assert(Defense.interior_exchange(war, "city", siege, [infantry], cavalry, "plains")["defender_loss"] == 0)
	assert(not Defense.occupation_state(war, "city", siege, [infantry], {"garrison": 0}, 8000)["ok"])
	# 使用确定的测试城防几何，不依赖三维素材布局。
	Fort._sites = {"city": {"id": "city", "cells": [100], "gate": 100, "center": 100}}
	siege["wall"] = 1.0
	assert(Defense.damage_facilities(war, "city", siege, [infantry])["new_breach"])
	assert(Defense.breach_cell(war, "city") == 100)
	assert(not Defense.damage_facilities(war, "city", siege, [infantry])["new_breach"])
	assert(not Defense.occupation_state(war, "city", siege, [], {"garrison": 0}, 8000)["ok"])
	assert(Defense.occupation_state(war, "city", siege, [infantry], {"garrison": 0}, 8000)["ok"])
	var board := {"fortifications": Fort._sites}
	infantry["tactical"] = {"cell": 100}
	cavalry["tactical"] = {"cell": 101}
	archers["tactical"] = {"cell": 100}
	archers["returning"] = true
	war.armies = [infantry, cavalry, archers]
	assert(Defense.inside_attackers(war, "city", board) == [infantry])
	var exchange := Defense.interior_exchange(war, "city", siege, [infantry], cavalry, "plains")
	assert(exchange["defender_loss"] > 0 and exchange["attacker_loss"] > 0)
	assert(exchange["attacker_personal"] >= 0 and exchange["attacker_personal"] <= 1)
	Defense.repair(war, "city", 20)
	assert(not Defense.breach_open(war, "city") and not siege.has("breach_cell"))
	assert(siege["wall"] > 0 and siege["wall"] <= siege["wall_max"])
	assert(war.store.city["fort_wall"] == siege["wall"])
	var resumed := Defense.create(war, "city", infantry)
	assert(resumed["wall"] == siege["wall"] and resumed["gate"] == siege["gate"])
	print("CITY_DEFENSE_SEPARATION_OK")
	quit()
