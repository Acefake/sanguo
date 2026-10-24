extends SceneTree

# Diagnostic for: archers countering at a siege should be standing inside 城区.
# Dumps real cell coordinates instead of reasoning about them.

const T = preload("res://scripts/war/tactical_battlefield.gd")
const Fort = preload("res://scripts/war/city_fortifications.gd")
const Grid = preload("res://scripts/rtk14_hex_grid.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var store: Node = root.get_node("GameState")
	store.persist_enabled = false
	store.prepare_battle_test()
	await store.war.step(null)

	var war = store.war
	var board: Dictionary = war.state["battlefield"]
	var site := Fort.for_city(store, "xiaopei")
	print("=== 小沛 城区 ===")
	print("site center cell = ", site["center"], " gate = ", site["gate"])
	print("cells count = ", site["cells"].size())
	var in_city := {}
	for c in site["cells"]:
		in_city[int(c)] = true

	print("=== 城区格坐标 (列,行) ===")
	var cols: Array[int] = []
	var rows: Array[int] = []
	for c in site["cells"]:
		cols.append(int(c) % 220)
		rows.append(int(c) / 220)
	cols.sort()
	rows.sort()
	print("列范围 ", cols[0], "..", cols[cols.size()-1])
	print("行范围 ", rows[0], "..", rows[rows.size()-1])

	print("=== 各方可进入格（movement_board 判定）===")
	for faction in ["liu_bei", "yuan_shao"]:
		var mb := Fort.movement_board(war, board, faction)
		var enterable := 0
		for c in site["cells"]:
			if not mb["blocked"].has(int(c)) and Grid.shared().walkable(int(c)):
				enterable += 1
		print(faction, " 可进入城区格数 = ", enterable, " / ", site["cells"].size())

	print("=== 单位站位 ===")
	for id in war.state["armies"]:
		var army: Dictionary = war.state["armies"][id]
		if not army.has("tactical") or army.get("status") == "ended": continue
		var cell: int = int(army["tactical"]["cell"])
		print("  ", army["name"], " ", army["faction"],
			" cell=", cell, " 列", cell % 220, "行", cell / 220,
			" phase=", army["tactical"]["phase"],
			" archers=", army["units"].get("archers", 0),
			" 在城区=", in_city.has(cell))

	quit(0)