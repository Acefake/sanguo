extends SceneTree
const Policy = preload("res://scripts/war/report_policy.gd")
var failures: Array[String] = []
func _initialize(): call_deferred("run")
func check(ok: bool, message: String) -> void:
	if not ok: failures.append(message); push_error(message)
func run() -> void:
	var store = root.get_node("GameState")
	store.persist_enabled = false
	store.prepare_battle_test()
	var war = store.war
	war.state["reports"] = []
	war.state["report_policy"] = {"sent": {}}
	var army: Dictionary = war.active_armies("liu_bei")[0]
	var friend: Dictionary = army.duplicate(true)
	friend["id"] = "test-friend"
	for day in range(10):
		war.state["tick"] += 1
		for kind in ["交战", "战线交战", "围城", "行军报告", "主帅分兵", "违令请示", "任务结束"]:
			war._report(army, kind, "daily", true)
		war._observe_all()
	check(war.state["reports"].is_empty(), "日常战斗因 urgent 绕过报告政策")
	check(not war.player_markers().is_empty(), "静默观察未保留地图部队")
	check(not army["intel"]["enemies"].is_empty(), "关闭发报导致敌情消失")
	check(not war.player_city_intel(str(army["home"])).is_empty(), "关闭发报导致城市情报消失")
	var old_scope: String = str(friend.get("corps_id", ""))
	friend["corps_id"] = Policy.scope(army)
	war._report(army, "破城", "breach", true, "siege:test:0")
	war._report(friend, "破城", "breach", true, "siege:test:0")
	war.state["tick"] += 1
	war._report(army, "破城", "breach", true, "siege:test:0")
	check(war.state["reports"].size() == 1, "军团关键节点未跨部队和日期去重")
	friend["corps_id"] = old_scope
	var board: Dictionary = war.state["battlefield"]
	board["ended_at"] = war.state["tick"]
	board["winner"] = "liu_bei"
	var initial: Dictionary = {}
	for member in war.state["armies"].values():
		initial[member["id"]] = member["initial_strength"]
		member["initial_strength"] = 100
	board["objectives"] = {}
	board.erase("control_point")
	war._summarize_finished_battles()
	check(war.state["reports"].size() == 1, "小规模日常战场结束仍自动总结")
	board["major_battle"] = true
	war._summarize_finished_battles()
	check(war.state["reports"].size() == 2, "明确重大战场未生成总结")
	board.erase("major_battle")
	var original_board_id: String = board["battle_id"]
	board["battle_id"] = original_board_id + ":key"
	board["key_objective"] = true
	for member in war.state["armies"].values(): member["battlefield_id"] = board["battle_id"]
	war._summarize_finished_battles()
	check(war.state["reports"].size() == 3, "低兵力关键目标战场未生成总结")
	board["battle_id"] = original_board_id
	board.erase("key_objective")
	for member in war.state["armies"].values(): member["battlefield_id"] = original_board_id
	for member in war.state["armies"].values(): member["initial_strength"] = initial[member["id"]]
	war._summarize_finished_battles()
	var count: int = war.state["reports"].size()
	war._summarize_finished_battles()
	check(war.state["reports"].size() == count and count == 3, "重大战役结束未仅总结一次")
	check(not war.request_battle_summary().is_empty(), "主动当前总结不可用")
	check(not war.request_battle_summary(str(army["id"])).get("army", {}).is_empty(), "交战中主动复盘不可用")
	check(war.state["reports"].size() == count, "主动请求污染自动报告去重")
	var view = preload("res://scripts/war/military_reports.gd").new()
	view.store = store
	root.add_child(view)
	view.show_summary()
	check(view.mode == "summary", "当前总结按钮入口失败")
	view.show_review(str(army["id"]))
	check(view.count_label.text == "当前复盘", "交战中复盘界面入口失败")
	view.free()
	war.state["campaign_result"] = {"tick":war.state["tick"],"message":"victory"}
	war._summarize_finished_battles()
	war._summarize_finished_battles()
	check(war.state["reports"].size() == count + 1, "全国战役终结未仅汇报一次")
	war._deliver_reports()
	check(war.state["reports"][-1].get("received", false) and war.state["reports"][-2].get("received", false), "结束报告需要继续推进一天才能送达")
	army["orders"] = {"report_level":"每日"}
	war.state["reports"].append({"kind":"交战","received":false})
	Policy.migrate(war.state)
	check(not army["orders"].has("report_level"), "旧每日报告选项未迁移")
	check(war.state["reports"].size() == count + 1, "旧日常待送报告未静默迁移")
	print("REPORT_POLICY_OK" if failures.is_empty() else "REPORT_POLICY_FAILED: " + str(failures))
	quit(0 if failures.is_empty() else 1)
