class_name CampaignReports
extends RefCounted
## 军报：生成、延迟送达、玩家可见列表、会战与战役总结。
##
## 所有函数都是静态的，第一个参数 war 是 CampaignState 实例（不标类型，避免与它互相引用）。

const Combat = preload("res://scripts/war/battle/combat_system.gd")
const Tactical = preload("res://scripts/war/battle/tactical_battlefield.gd")
const Duel = preload("res://scripts/war/duel/duel_system.gd")
const Feedback = preload("res://scripts/war/battle/battle_feedback.gd")
const ReportPolicy = preload("res://scripts/war/campaign/report_policy.gd")
const StateKeys = preload("res://scripts/war/campaign/war_state_keys.gd")


## 记一条军报：写入战报反馈与部队记忆；本方且通过 ReportPolicy 时进入待送达队列。
static func _report(war, army: Dictionary, kind: String, message: String, urgent: bool, event_key: String = "") -> void:
	if ReportPolicy.eligible(kind) or kind in ["武将战死", "武将被俘", "斩获", "主将接替", "单挑", "溃败", "变阵", "粮道截断", "占领", "主帅分兵", "专长", "主帅失位", "违令", "违令请示"]: Feedback.event(war, kind, message, army["faction"])
	if kind in ["交战", "战线交战", "围城"]:
		var factors: Array = army.get("battle_factors", [])
		if not factors.is_empty(): message += " " + "；".join(factors)
	# Keep tactical memory even when the event produces no notification.
	army["memory"].append({"tick": war.state[StateKeys.TICK], "kind": kind, "event": message})
	while army["memory"].size() > 8: army["memory"].pop_front()
	if str(army["faction"]) != str(war.state[StateKeys.PLAYER_FACTION]): return
	if not ReportPolicy.allow(war.state, army, kind, event_key): return
	var reports: Array = war.state[StateKeys.REPORTS]
	var id: String = "report-%d-%d" % [int(war.state[StateKeys.TICK]), int(war.state[StateKeys.NEXT_ID])]
	war.state[StateKeys.NEXT_ID] += 1
	reports.append({"id": id, "army_id": army["id"], "faction": army["faction"], "kind": kind, "message": message, "sent_tick": int(war.state[StateKeys.TICK]), "sent_date": war.store.date_text(), "delivery_tick": int(war.state[StateKeys.TICK]) + (0 if kind in ["战役总结", "战役终结"] else int(war.rules["report_delay_days"])), "received": false, "urgent": urgent, "snapshot": {"commander": war.roster.officers.get(army["officer_id"], {}).get("name", army["name"]), "enemy_killed": int(army.get("enemy_killed", 0)), "commander_killed": int(war.state[StateKeys.OFFICER_PERSONAL_KILLS].get(army["officer_id"], 0)), "troop_killed": int(army.get("enemy_killed", 0)) - int(army.get("personal_soldier_kills", 0)), "commander_fate": army.get("commander_fate", {}).duplicate(true), "location": army["location"].duplicate(true), "strength": Combat.strength(army), "morale": army["morale"], "grain_days": int(war.food_days(army)), "battle_factors": army.get("battle_factors", []).duplicate() if kind in ["交战", "战线交战", "围城"] else [], "wounded": int(army["wounded"]), "organization": float(army["organization"]), "fatigue": float(army["fatigue"]), "daily_loss": int(army.get("daily_loss", 0)) if int(army.get("daily_loss_tick", -1)) == int(war.state[StateKeys.TICK]) else 0, "terrain": Tactical.terrain_class(army["tactical"]["cell"]) if army.has("tactical") else "", "reason": str(army["last_reason"]), "ended": str(army["status"]) == "ended", "cities": army["intel"]["cities"].duplicate(true)}})
	while reports.size() > 200:
		reports.pop_front()


## 送达到期军报并标记紧急事件；同时让养伤到期的武将恢复可用。
static func _deliver_reports(war) -> void:
	Duel.recover(war)
	for report in war.state[StateKeys.REPORTS]:
		if not bool(report["received"]) and int(report["delivery_tick"]) <= int(war.state[StateKeys.TICK]):
			report["received"] = true
			report["received_date"] = war.store.date_text()
			var army: Dictionary = war.state[StateKeys.ARMIES].get(report["army_id"], {})
			if not army.is_empty(): army["last_report"] = report.duplicate(true)
			if bool(report["urgent"]): war.urgent_event = true
	for id in war.state[StateKeys.OFFICER_STATES]:
		var officer: Dictionary = war.state[StateKeys.OFFICER_STATES][id]
		if str(officer.get("status", "")) == "recovering" and int(officer.get("available_after", 0)) <= int(war.state[StateKeys.TICK]):
			var corps: Dictionary = war.state[StateKeys.CORPS].get(officer.get("corps_id", ""), {})
			officer["status"] = "deployed" if not corps.is_empty() and not corps.get("ended", false) else "available"
			officer.erase("duel_wounded")


## 已送达的军报，新的在前。
static func visible_reports(war) -> Array:
	var result: Array = []
	for report in war.state[StateKeys.REPORTS]:
		if bool(report["received"]): result.push_front(report)
	return result


## 是否有尚未送达的紧急军报。
static func has_pending_urgent_report(war) -> bool:
	for report in war.state[StateKeys.REPORTS]:
		if not bool(report["received"]) and bool(report["urgent"]): return true
	return false


## 本方各军最近一次观测到的位置标记。
static func player_markers(war) -> Array:
	var result: Array = []
	for army in war.state[StateKeys.ARMIES].values():
		if str(army["faction"]) != str(war.state[StateKeys.PLAYER_FACTION]): continue
		var observation: Dictionary = army.get("last_observation", {})
		if not observation.is_empty() and not bool(observation.get("ended", false)):
			result.append({"id": army["id"], "name": army["name"], "location": observation["location"], "date": observation["date"], "strength": observation["strength"]})
	return result


## 玩家即时查询的战况：不传 army_id 为全局摘要，否则为该军详情。
static func request_battle_summary(war, army_id: String = "") -> Dictionary:
	# Player requests are immediate reads and do not consume notification dedup keys.
	if army_id.is_empty(): return Feedback.summary(war)
	var army: Dictionary = war.state[StateKeys.ARMIES].get(army_id, {})
	if army.is_empty() or army.get("faction", "") != war.state[StateKeys.PLAYER_FACTION]: return {}
	return {"army": army.duplicate(true), "decisions": army.get("decision_history", []).duplicate(true), "orders": war.state[StateKeys.CORPS].get(army.get("corps_id", ""), {}).get("orders", []).duplicate(true)}


## 会战、军团行动、整个战役结束时各发一条总结军报。
static func _summarize_finished_battles(war) -> void:
	var boards: Array = war.state.get(StateKeys.BATTLEFIELDS, {}).values().duplicate()
	if war.state.has(StateKeys.BATTLEFIELD) and not war.state[StateKeys.BATTLEFIELD] in boards: boards.append(war.state[StateKeys.BATTLEFIELD])
	var covered := {}
	for board in boards:
		if not board.has("ended_at"): continue
		var board_id := str(board.get("battle_id", "field:" + str(board.get("anchor", ""))))
		var members: Array = war.state[StateKeys.ARMIES].values().filter(func(army): return army.get("battlefield_id", "") == board_id or army.get("last_battlefield_id", "") == board_id)
		var sample: Dictionary = {}
		for army in members:
			covered[ReportPolicy.scope(army)] = true
			if army["faction"] == war.state[StateKeys.PLAYER_FACTION] and sample.is_empty(): sample = army
		if sample.is_empty(): continue
		var starting_strength := 0
		for army in members: starting_strength += int(army.get("initial_strength", 0))
		var key_objective: bool = bool(board.get("key_objective", false)) or not board.get("control_point", {}).is_empty() or not board.get("objectives", {}).is_empty()
		if starting_strength < int(war.rules.get("report_policy", {}).get("major_strength", 10000)) and not board.get("major_battle", false) and not key_objective: continue
		var message := "会战结束：%s。%s" % [str(board.get("victory_reason", board.get("winner", "双方已脱离战场"))), _casualty_summary(war, members)]
		_report(war, sample, "战役总结", message, true, "battle:" + board_id)
	for corps in war.state[StateKeys.CORPS].values():
		if covered.has(str(corps.get("id", ""))): continue
		var members: Array = []
		for id in corps.get("units", []):
			if war.state[StateKeys.ARMIES].has(id): members.append(war.state[StateKeys.ARMIES][id])
		if members.is_empty() or members.any(func(army): return army["status"] != "ended"): continue
		var strength := 0
		for army in members: strength += int(army.get("initial_strength", 0))
		if strength < int(war.rules.get("report_policy", {}).get("major_strength", 10000)) and not corps.get("major_battle", false): continue
		var fought: bool = members.any(func(army): return int(army.get("combat_tick", -1)) >= int(army.get("started", 0)) or int(army.get("enemy_killed", 0)) > 0 or int(army.get("dead", 0)) + int(army.get("wounded", 0)) > 0)
		if not fought and not corps.get("major_battle", false): continue
		var sample: Dictionary = members[0]
		if sample["faction"] != war.state[StateKeys.PLAYER_FACTION]: continue
		_report(war, sample, "战役总结", str(corps.get("name", "军团")) + "行动结束。" + _casualty_summary(war, members), true, "corps:" + str(corps.get("id", sample.get("corps_id", ""))))
	var result: Dictionary = war.state.get(StateKeys.CAMPAIGN_RESULT, {})
	if not result.is_empty():
		for army in war.state[StateKeys.ARMIES].values():
			if army["faction"] != war.state[StateKeys.PLAYER_FACTION]: continue
			_report(war, army, "战役终结", str(result.get("message", "战役结束")) + _casualty_summary(war, war.state[StateKeys.ARMIES].values()), true, "campaign:" + str(result.get("tick", "")))
			break


## 一组军队的出战、阵亡、伤兵、被俘合计文本。
static func _casualty_summary(war, members: Array) -> String:
	var initial := 0
	var dead := 0
	var wounded := 0
	var captured := 0
	for army in members:
		initial += int(army.get("initial_strength", 0))
		dead += int(army.get("dead", 0))
		wounded += int(army.get("wounded", 0))
		captured += int(army.get("captured", 0))
	return "出战%d，阵亡%d，伤兵%d，被俘%d。" % [initial, dead, wounded, captured]
