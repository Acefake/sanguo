extends SceneTree
const F = preload("res://scripts/war/battle_feedback.gd")
const War = preload("res://scripts/war/campaign_state.gd")
var failures: Array[String] = []
func _initialize(): call_deferred("run")
func check(ok: bool, message: String):
	if not ok: failures.append(message); push_error(message)
func run():
	var army := {"faction":"a","units":{"infantry":1000,"archers":0,"cavalry":0},"morale":100,"organization":100,"training":50,"equipment":50,"fatigue":0,"skills":{},"name":"甲"}
	var healthy := F.advantage([army],"a")
	army["morale"] = 40
	check(F.advantage([army],"a") < healthy,"优势条不受军心影响")
	var lower := F.advantage([army],"a")
	army["units"]["infantry"] = 500
	check(F.advantage([army],"a") < lower,"优势条不受兵力影响")
	var store = root.get_node("GameState")
	store.persist_enabled = false
	store.prepare_battle_test()
	var war = store.war
	var text := " ".join(F.factors(army,army,war.rules,"forest"))
	check("森林" in text and "士气" in text,"地形或低军心解释缺失")
	army["morale"] = 100
	check(F.factors(army,army,war.rules,"plains").is_empty(),"没有显著因素时硬凑解释")
	var previous_test: bool = store.battle_test
	store.battle_test = false
	var balance := F.visible_advantage(war)
	for enemy in war.active_armies("yuan_shao"):
		enemy["morale"] = 10
		enemy["organization"] = 10
	check(F.visible_advantage(war)["theirs"] < balance["theirs"] and not F.visible_advantage(war)["estimated"],"优势条未使用敌方实时士气与组织")
	for enemy in war.active_armies("yuan_shao"):
		enemy["morale"] = 100
		enemy["organization"] = 100
	store.battle_test = previous_test
	for day in range(5): await war.step(null)
	var snapshot := F.snapshot(war)
	for side in snapshot: check(side["initial"] == side["accounted"],"会战兵员账本不守恒")
	# Exercise the actual tactical flank callback on a legal adjacent pair.
	var a: Dictionary = war.active_armies("liu_bei")[0]
	var b: Dictionary = war.active_armies("yuan_shao")[0]
	for other in war.active_armies():
		if other != a and other != b: other["status"] = "ended"
	war.state["corps"] = {}
	war.rules["duel"]["enabled"] = false
	var cell: int = a["tactical"]["cell"]
	var adjacent := -1
	for neighbor in war.Tactical.neighbors(cell):
		if war.Tactical.row_of(neighbor) == war.Tactical.row_of(cell) and war.Tactical.in_battlefield(war.state["battlefield"],neighbor): adjacent = neighbor; break
	check(adjacent >= 0,"侧击夹具没有合法横邻格")
	if adjacent >= 0:
		b["tactical"]["cell"] = adjacent
		a["action"] = {"type":"flank"}
		a["tactical"]["flank_ready"] = true
		b["action"] = {"type":"engage"}
		war.state["tick"] += 1
		war._observe_all()
		war.Tactical.resolve(war)
		check(F.book(war).get("pending_events",[]).any(func(e):return e["kind"] == "侧击"),"真实侧击没有写入会战事件")
	for kind in ["单挑","破墙"]: F.event(war,kind,"测试事件")
	F.record_day(war,snapshot)
	var events: Array = F.book(war)["log"][-1]["events"]
	check(events.size() >= 3,"会战事件没有全部记录")
	var saved: Dictionary = war.export_state()
	var restored = War.new()
	restored.setup(store,saved)
	check(F.book(restored)["log"] == F.book(war)["log"],"会战日志没有往返保存")
	for day in range(250):
		war.state["tick"] += 1
		F.record_day(war,snapshot)
	check(F.book(war)["log"].size() == 240,"会战日志没有限制240条")
	store.restore_battle_test()
	print("BATTLE_FEEDBACK_OK: advantage, deterministic factors, conservation, events, 240 day bound and saves" if failures.is_empty() else "BATTLE_FEEDBACK_FAILED")
	quit(0 if failures.is_empty() else 1)
