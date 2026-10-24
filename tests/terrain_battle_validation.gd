extends SceneTree
const Combat = preload("res://scripts/war/battle/combat_system.gd")
const Terrain = preload("res://scripts/war/battle/battle_terrain.gd")
const T = preload("res://scripts/war/battle/tactical_battlefield.gd")
var failures: Array[String] = []
func _initialize(): call_deferred("run")
func check(ok: bool, message: String):
	if not ok: failures.append(message); push_error(message)
func army(type: String = "infantry") -> Dictionary:
	var units := {"infantry":0,"archers":0,"cavalry":0}
	units[type] = 3000
	return {"units":units,"training":50,"equipment":50,"organization":100,"morale":100,"fatigue":0,"skills":{},"action":{"type":"engage"}}
func run():
	var rules := Terrain.rules()
	var a := army()
	var b := army()
	check(Combat.losses(a,b,rules,"forest",1) < Combat.losses(a,b,rules,"plains",1),"森林防护没有降低伤亡")
	check(Combat.power(army("cavalry"),rules,"mountains") < Combat.power(army("cavalry"),rules,"plains"),"山地骑兵没有受限")
	check(Combat.losses(army("archers"),b,rules,"forest",1) < Combat.losses(army("archers"),b,rules,"plains",1)*0.9,"森林没有削弱远射")
	a["tactical"] = {"terrain_delay":"ford"}
	check(Combat.losses(a,b,rules,"plains",1) == 0,"进入渡口当日仍然攻击")
	a["tactical"]["terrain_delay"] = "mountains"
	check(is_equal_approx(Terrain.entry_factor(a,rules),0.85),"山地当日迟滞没有生效")
	a["tactical"].erase("terrain_delay")
	check(Combat.losses(a,b,rules,"plains",1) > 0,"迟滞解除后攻击没有恢复")
	check(Terrain.from_code(255) == "plains" and Terrain.from_code(5) == "forest" and Terrain.from_code(12) == "ford", "真实地形映射或未知码回退错误")
	var audit: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://docs/validation/terrain-code-audit.json"))
	var total := 0
	for code in audit["codes"]:
		total += int(audit["codes"][code]["count"])
		check(Terrain.settings(Terrain.from_code(int(code))).has("name"),"地形码没有分类或回退")
	check(total == 48400,"全国地形审计没有覆盖所有格")
	var store = root.get_node("GameState")
	store.persist_enabled = false
	store.prepare_battle_test(true)
	var war = store.war
	var own: Dictionary = war.active_armies()[0]
	# Exercise the real move pipeline on the shared grid, rather than setting only a flag.
	for other in war.active_armies():
		if other != own: other["status"] = "ended"
	war.state["corps"] = {}
	own["intel"]["enemies"].clear()
	var start: int = own["tactical"]["cell"]
	var destination := -1
	for neighbor in T.neighbors(start):
		if T.in_battlefield(war.state["battlefield"],neighbor): destination = neighbor; break
	check(destination >= 0,"没有迟滞移动夹具格")
	if destination >= 0:
		var original: int = T.grid().words[destination*4+1]
		for row in [[12,"ford",0.0],[9,"mountains",0.85]]:
			own["tactical"] = {"cell":start,"role":"raid_rear","lane":T.column_of(start)}
			own["corps_task"] = {"type":"raid_rear","cell":destination}
			own["action"] = {"type":"continue"}
			T.grid().words[destination*4+1] = (original & ~255) | int(row[0])
			war.state["tick"] += 1
			T.move(war)
			check(own["tactical"]["cell"] == destination and own["tactical"].get("terrain_delay","") == row[1],"真实移动没有设置进入地形迟滞")
			check(is_equal_approx(Terrain.entry_factor(own,war.rules),float(row[2])),"真实进入地形攻击修正不符")
			war.state["tick"] += 1
			T.move(war)
			check(not own["tactical"].has("terrain_delay"),"渡口或山地迟滞持续超过当日")
		T.grid().words[destination*4+1] = original
	own["tactical"]["terrain_delay"] = "mountains"
	own["action"] = {"type":"hold"}
	war.state["tick"] += 1
	T.move(war)
	check(not own["tactical"].has("terrain_delay"),"次日移动阶段没有清除迟滞")
	var old_cell: int = own["tactical"]["cell"]
	var old_word: int = T.grid().words[old_cell*4+1]
	T.grid().words[old_cell*4+1] = (old_word & ~255) | 13
	var reloaded = load("res://scripts/war/campaign/campaign_state.gd").new()
	reloaded.setup(store,war.export_state())
	var migrated: Dictionary = reloaded.state["armies"][own["id"]]
	check(migrated["tactical"]["cell"] != old_cell and T.grid().walkable(migrated["tactical"]["cell"]),"旧档川格部队没有就近归岸")
	T.grid().words[old_cell*4+1] = old_word
	store.restore_battle_test()
	print("TERRAIN_BATTLE_OK: audit, defense, cavalry, ranged, ford lock, mountain delay and next day" if failures.is_empty() else "TERRAIN_BATTLE_FAILED")
	quit(0 if failures.is_empty() else 1)
