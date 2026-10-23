extends RefCounted
## 小沛独立战场：两军分别从小沛、濮阳出发接战，用于战斗测试与 --xiaopei-battle 入口。

const StateKeys = preload("res://scripts/war/campaign/war_state_keys.gd")
const Sides = preload("res://scripts/war/battle/battle_sides.gd")
const Corps = preload("res://scripts/war/campaign/army_corps.gd")
const PeopleStore = preload("res://scripts/people/person_store.gd")
const CONFIG := "res://data/war/xiaopei_battle.json"

## 参战势力与主帅读自 data/war/xiaopei_battle.json，人物按名册势力归边（BattleSides）；
## 某方连生成将都没有时报错并不开战。游戏日期与人物包用同一个开局（PersonStore.declared_start，配置须声明 people_pack），
## war.setup 之后载入人物包（只建人物状态，不碰战场）。
static func setup(store: Node, preformed: bool = false, options: Dictionary = {}) -> void:
	store._load_demo()
	store.war.setup(store, {})
	var config: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(CONFIG))
	var start := PeopleStore.declared_start(config)
	store.year = int(start["year"])
	store.month = int(start["month"])
	store.day = (int(start["xun"]) - 1) * 10 + 1
	PeopleStore.autoload().load_declared(config)
	var plan := Sides.plan(store.war.roster.officers, config["sides"], func(members): return Corps.best_member(store.war, members, "主帅"))
	for warning in plan["warnings"]: push_warning("小沛战场：" + warning)
	if not str(plan["error"]).is_empty():
		push_error("小沛战场：" + str(plan["error"]))
		return
	store.war.state[StateKeys.PLAYER_FACTION] = str(config["player_faction"])
	for side in plan["sides"]:
		var faction: String = side["faction"]
		var defender: bool = side["role"] == "defender"
		var strength := int(options.get(faction + "_strength", 20000))
		var home := "xiaopei" if defender else "puyang"
		var target := "puyang" if preformed and defender else "xiaopei"
		var city: Dictionary = store.city_state(home)
		city["faction"] = faction
		city["garrison"] = strength
		city["units"] = {"infantry": int(strength * 0.7), "archers": int(strength * 0.2), "cavalry": int(strength * 0.1)}
		city["grain"] = 100000
		city["training"] = 70
		city["equipment"] = 70
		var path: Dictionary = store.war.graph.path(home, "puyang" if home == "xiaopei" else "xiaopei")
		var army: Dictionary = store.war._mobilize({"home": home, "target": target, "officer_id": side["leader"], "strength": strength, "grain": 3600, "mission_type": "defend" if not preformed and defender else "capture"})
		army["location"] = {"node": home, "from": home, "to": "puyang" if home == "xiaopei" else "xiaopei", "edge": path["edges"][0], "progress": 0.04 if defender else 0.92}
		Corps.form(store.war, army, side["members"], not preformed)

	if not preformed:
		var city: Dictionary = store.city_state("xiaopei")
		city.merge({"garrison": 3000, "units": {"infantry": 2400, "archers": 600, "cavalry": 0}, "grain": 18000, "defense": 65}, true)
	store.war._observe_all()
	preload("res://scripts/war/battle/tactical_battlefield.gd").setup(store.war)
	Corps.deploy(store.war)
	if not preformed:
		var grid = preload("res://scripts/war/battle/tactical_battlefield.gd").grid()
		var cities: Array = JSON.parse_string(FileAccess.get_file_as_string("res://assets/rtk14/cities_map.json"))
		for city in cities:
			if city["name"] == "小沛": store.war.state[StateKeys.BATTLEFIELD]["objectives"] = {"xiaopei": grid.pick(Vector2(city["x"], city["z"]))}
	for army in store.war.active_armies(): army["intel"]["enemies"].clear()
	store.war._observe_all()
	store.war._update_operations()
