extends SceneTree

const Terrain = preload("res://scripts/war/battle_terrain.gd")
const Feedback = preload("res://scripts/war/battle_feedback.gd")
var failures: Array[String] = []
func _initialize(): call_deferred("run")
func check(ok: bool, message: String):
	if not ok: failures.append(message); push_error(message)
func run():
	var store = root.get_node("GameState")
	store.persist_enabled = false
	var grid = store.war.Tactical.grid()
	var original_words: PackedInt32Array = grid.words.duplicate()
	Terrain.table()
	var original_table: Dictionary = Terrain._table.duplicate(true)
	var results := []
	for extended in [false,true]:
		grid.words = original_words.duplicate()
		Terrain._table = original_table.duplicate(true)
		if not extended:
			Terrain._table["codes"] = {}
			for cell in range(grid.COUNT):
				if grid.terrain(cell) == 13: grid.words[cell*4+1] = (grid.words[cell*4+1] & ~255) | 1
		for seed_value in [1910901,12345,6482,42,98765]:
			store.prepare_battle_test()
			var war = store.war
			if not extended:
				war.rules["duel"]["enabled"] = false
			war.rng.seed = seed_value
			var start := Time.get_ticks_msec()
			var trace := []
			for day in range(120):
				await war.step(null)
				var sides := Feedback.snapshot(war)
				for side in sides: check(side["initial"] == side["accounted"],"多种子兵员不守恒 seed=%d tick=%d" % [seed_value,war.state["tick"]])
				var cells := {}
				for unit in war.active_armies():
					if not unit.has("tactical"): continue
					var cell: int = unit["tactical"]["cell"]
					check(grid.walkable(cell) and not cells.has(cell),"多种子越界或重叠")
					cells[cell] = true
				trace.append({"tick":war.state["tick"],"sides":sides,"active":war.active_armies().size(),"returning":war.active_armies().filter(func(a):return a["returning"]).size()})
				if war.state["battlefield"].has("winner"): break
			check(war.state["battlefield"].has("winner"),"会战120日未结束 seed=%d extended=%s" % [seed_value,extended])
			# 收束账本：任何一条结束路径都不能让兵员凭空消失（家乡易手、退路断绝、
			# 守援/期限到期时，存活兵员此前既不进城也不计俘/亡）。
			for unit in war.state["armies"].values():
				var book: Dictionary = war.ledger(unit)
				check(int(book["missing"]) == 0, "兵员账本缺口 seed=%d %s 缺%d" % [seed_value, str(unit["id"]), int(book["missing"])])
			var result := {"extended":extended,"seed":seed_value,"days":war.state["tick"],"winner":war.state["battlefield"].get("winner","unfinished"),"elapsed_ms":Time.get_ticks_msec()-start,"summary":Feedback.summary(war),"trace":trace}
			results.append(result)
			print("CAMPAIGN_SEED ",JSON.stringify({"extended":extended,"seed":seed_value,"days":result["days"],"winner":result["winner"],"ms":result["elapsed_ms"]}))
	grid.words = original_words
	Terrain._table = original_table
	store.restore_battle_test()
	var file := FileAccess.open("res://docs/validation/battle-extension-campaign-seeds.json",FileAccess.WRITE)
	file.store_string(JSON.stringify({"control":"关闭新增地形战斗修正和单挑，并保留旧川格通行；阵型系统已移除，同一版本规则引擎，非旧提交快照","results":results},"\t"))
	print("BATTLE_EXTENSION_CAMPAIGN_OK: five seeds, control and extended, termination, occupancy and conservation" if failures.is_empty() else "BATTLE_EXTENSION_CAMPAIGN_FAILED")
	quit(0 if failures.is_empty() else 1)
