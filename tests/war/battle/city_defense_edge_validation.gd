extends SceneTree
const Defense = preload("res://scripts/war/battle/city_defense.gd")
const Fixtures = preload("res://tests/war/battle/city_defense_separation_validation.gd")

func _initialize() -> void:
	var war := Fixtures.War.new()
	var infantry := {"units": {"infantry": 100, "archers": 0, "cavalry": 0}, "faction": "attacker"}
	var legacy := {"wall_max": 200.0, "wall": 0.0, "morale": 100.0, "organization": 100.0}
	Defense.migrate(war, "city", legacy)
	assert(legacy["breach_open"] and legacy["gate_max"] == 100)
	var saved := legacy.duplicate(true)
	Defense.migrate(war, "city", legacy)
	assert(legacy == saved)
	war.state["sieges"]["city"] = legacy
	Defense.persist(war, "city", legacy)
	# 围城结束、敌军换主将和存档往返均不能恢复已损伤城墙。
	war.state["sieges"].clear()
	var resumed := Defense.create(war, "city", infantry)
	assert(resumed["wall"] == 0 and resumed["breach_open"])
	war.store.city = JSON.parse_string(JSON.stringify(war.store.city))
	assert(Defense.create(war, "city", infantry)["wall"] == 0)
	Defense.repair(war, "city", -10)
	assert(war.store.city["fort_wall"] == 0)
	Defense.repair(war, "city", 1000)
	assert(war.store.city["fort_wall"] == war.store.city["fort_wall_max"])
	var siege := Defense.create(war, "city", infantry)
	war.state["sieges"]["city"] = siege
	assert(not Defense.breach_open(war, "city"))
	assert(Defense.breach_cell(war, "city") == -1)
	siege["breach_open"] = true
	siege["morale"] = 0.0
	assert(not Defense.occupation_state(war, "city", siege, [infantry], {"garrison": 101}, 1000)["ok"])
	assert(Defense.occupation_state(war, "city", siege, [infantry], {"garrison": 99}, 100)["ok"])
	assert(not Defense.occupation_state(war, "city", siege, [{"units": {"infantry": 0}}], {"garrison": 0}, 1000)["ok"])
	print("CITY_DEFENSE_EDGES_OK")
	quit()
