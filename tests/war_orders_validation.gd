extends SceneTree

const Store = preload("res://scripts/game_state.gd")
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func check(value: bool, message: String) -> void:
	if not value:
		failures.append(message)
		push_error(message)

func sandbox() -> Node:
	var store := Store.new()
	store.persist_enabled = false
	store._load_demo()
	return store

func _run() -> void:
	root.get_node("GameState").persist_enabled = false
	var store: Node = sandbox()
	var home: Dictionary = store.city_state("chengdu")
	home["faction"] = "liu_bei"
	home["garrison"] = 8000
	home["units"] = {"infantry": 8000, "archers": 0, "cavalry": 0}
	home["grain"] = 50000
	var officer: String = store.war.available_officers("liu_bei")[0]["id"]
	var dispatch: Dictionary = store.war.dispatch("chengdu", "wudu", officer)
	check(bool(dispatch["ok"]), "军令测试派遣失败")
	var id: String = dispatch["army_id"]
	var army: Dictionary = store.war.state["armies"][id]
	army["intel"]["enemies"]["enemy"] = {"id": "enemy", "location": {"node": "chengdu", "edge": ""}, "routing": true}
	check(store.war.command_army(id, {"engage": false, "retreat": false, "pursue": false, "after_battle": "hold"})["ok"], "军令设置失败")
	for candidate in store.war.context_for(army)["candidates"]:
		check(candidate["action"]["type"] not in ["engage", "pursue", "withdraw"], "被禁止的行动仍可选择")
	check(not store.war.command_army(id, {"unknown": true})["ok"], "未知军令通过校验")
	check(not store.war.command_army(id, {"engage": "false"})["ok"], "错误类型军令通过校验")
	var enemy_city: Dictionary = store.city_state("wudu")
	enemy_city["faction"] = "yuan_shao"
	enemy_city["garrison"] = 3000
	enemy_city["units"] = {"infantry": 3000, "archers": 0, "cavalry": 0}
	enemy_city["grain"] = 50000
	var enemy_officer: String = store.war.roster.militia("yuan_shao", "wudu")
	var enemy: Dictionary = store.war._mobilize(store.war.preview_dispatch("wudu", "wudu", enemy_officer, true))
	enemy["location"] = army["location"].duplicate(true)
	enemy["action"] = {"type": "hold"}
	var before: int = store.war.Combat.strength(army)
	store.war._resolve_contacts({})
	# Formal contact now deploys a board; move the two units into real adjacent contact.
	if army.has("tactical"):
		var point: int = army["tactical"]["cell"]
		for cell in store.war.Tactical.neighbors(point):
			if store.war.Tactical.can_enter(store.war, enemy, cell): enemy["tactical"]["cell"] = cell; break
		store.war._observe_all()
	check(store.war.Combat.strength(army) == before, "无视军令仍主动挑起交战")
	enemy["action"] = {"type": "engage", "enemy": id}
	store.war._resolve_contacts({})
	check(store.war.Combat.strength(army) < before, "无视军令错误地免疫敌军攻击")
	check(int(army.get("combat_tick", -1)) == int(store.war.state["tick"]) and int(enemy.get("combat_tick", -1)) == int(store.war.state["tick"]), "实际交战没有发布动画事件")
	var copy: Node = sandbox()
	copy.war.setup(copy, store.war.export_state())
	check(copy.war.orders_for(copy.war.state["armies"][id]) == store.war.orders_for(army), "军令没有随存档恢复")
	army["faction"] = "yuan_shao"
	check(not store.war.command_army(id, {}, true)["ok"], "玩家能够控制敌军撤退")
	army["faction"] = "liu_bei"
	army["morale"] = 10
	store.war._check_rout(army)
	check(army["returning"], "禁止自主撤退阻止了溃败保命")
	store.free()
	copy.free()
	# Capture followed by hold stays at the captured city until a new order.
	store = sandbox()
	home = store.city_state("chengdu")
	home["faction"] = "liu_bei"
	home["garrison"] = 8000
	home["units"] = {"infantry": 8000, "archers": 0, "cavalry": 0}
	home["grain"] = 50000
	var target: Dictionary = store.city_state("wudu")
	target["faction"] = "yuan_shao"
	target["garrison"] = 0
	target["units"] = {"infantry": 0, "archers": 0, "cavalry": 0}
	dispatch = store.war.dispatch("chengdu", "wudu", officer)
	id = dispatch["army_id"]
	army = store.war.state["armies"][id]
	store.war.command_army(id, {"after_battle": "hold"})
	army["location"] = {"node": "wudu", "edge": "", "progress": 0.0}
	army["action"] = {"type": "besiege"}
	store.war._resolve_sieges()
	check(target["faction"] == "liu_bei" and not army["returning"], "攻取后待命仍自动撤退")
	await store.war.step()
	check(army["action"]["type"] == "hold" and army["status"] == "active" and army["location"]["edge"] == "", "智能体打断了攻取后待命")
	store.war.command_army(id, {"after_battle": "withdraw"})
	await store.war.step()
	check(army["status"] == "ended", "待命后改为归营没有生效")
	store.free()
	if failures.is_empty(): print("WAR_ORDERS_OK: authority, typed commands, candidate restrictions, persistence, emergency retreat and capture/hold/return")
	quit(0 if failures.is_empty() else 1)
