extends SceneTree

const Tactical = preload("res://scripts/war/tactical_battlefield.gd")
var failures: Array[String] = []

func _initialize() -> void: call_deferred("_run")

func check(value: bool, message: String) -> void:
	if not value:
		failures.append(message)
		push_error(message)

func _run() -> void:
	var store: Node = root.get_node("GameState")
	store.persist_enabled = false
	store.prepare_battle_test(true)
	var board: Dictionary = store.war.state["battlefield"]
	var anchor: int = int(board["anchor"])
	var own: Dictionary = store.war.active_armies("liu_bei")[0]
	var enemies: Array = store.war.active_armies("yuan_shao").slice(0, 6)
	while enemies.size() < 6:
		var extra: Dictionary = enemies[0].duplicate(true)
		extra["id"] = "encirclement-fixture-%d" % enemies.size()
		store.war.state["armies"][extra["id"]] = extra
		store.war.state["missions"][extra["id"]] = {"status": "active", "result": ""}
		enemies.append(extra)
	for army in store.war.active_armies(): army["status"] = "ended"
	store.war.state["battlefield"]["blocked"] = []
	own["units"] = {"infantry": 14000, "archers": 4000, "cavalry": 2000}
	own["initial_strength"] = 20000
	own["status"] = "active"
	own["tactical"]["cell"] = anchor
	own["returning"] = true
	own["action"] = {"type": "withdraw"}
	var cells := Tactical.neighbors(anchor)
	for index in range(6):
		enemies[index]["status"] = "active"
		enemies[index]["tactical"]["cell"] = cells[index]
		enemies[index]["action"] = {"type": "hold"}
	store.war._observe_all()
	var before: int = store.war.Combat.strength(own)
	for day in range(3):
		store.war.state["tick"] += 1
		store.war._observe_all()
		Tactical.move(store.war)
		check(own["tactical"]["cell"] == anchor, "六面包围仍可立刻溜走")
	Tactical.resolve(store.war)
	check(store.war.Combat.strength(own) < before and own["organization"] < 100, "被围撤退未承受攻击或组织损耗")
	enemies[1]["status"] = "ended"
	for day in range(7):
		store.war.state["tick"] += 1
		store.war._observe_all()
		Tactical.move(store.war)
		if own["tactical"]["cell"] != anchor: break
	check(own["tactical"]["cell"] != anchor, "打开缺口后仍不能准备突围")
	# A lone healthy main force must not abandon its line to chase an enemy.
	for enemy in enemies: enemy["status"] = "ended"
	enemies[0]["status"] = "active"
	enemies[0]["tactical"]["cell"] = Tactical.offset_cell(board, 0, 6)
	own["status"] = "active"
	own["returning"] = false
	own["organization"] = 100
	own["tactical"]["cell"] = anchor
	own["tactical"]["lane"] = Tactical.column_of(anchor)
	own["operation"]["role"] = "main_attack"
	own["action"] = {"type": "engage", "enemy": enemies[0]["id"]}
	store.war._observe_all()
	Tactical.move(store.war)
	check(own["tactical"]["cell"] == anchor and own["tactical"]["phase"] == "等待友军跟进", "主攻孤立时仍脱离阵线追敌")
	# Even a successful disengagement exposes the army to a parting attack.
	own["returning"] = true
	own["tactical"]["cell"] = anchor
	own["tactical"]["withdraw_preparation"] = 2
	enemies[0]["tactical"]["cell"] = Tactical.offset_cell(board, 0, 1)
	store.war._observe_all()
	Tactical.move(store.war)
	check(Tactical.distance(own, enemies[0]) > 1, "已准备部队无法向空旷退路脱离")
	before = store.war.Combat.strength(own)
	Tactical.resolve(store.war)
	check(store.war.Combat.strength(own) < before, "脱离接触瞬间没有承受追击")
	store.restore_battle_test()
	print("ENCIRCLEMENT_OK: pinned retreat, occupied ring, attrition, breakout through opening" if failures.is_empty() else "ENCIRCLEMENT_FAILED")
	quit(0 if failures.is_empty() else 1)
