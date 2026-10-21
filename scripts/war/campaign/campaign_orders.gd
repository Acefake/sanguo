class_name CampaignOrders
extends RefCounted
## 军令与违令：军令默认值与候选过滤、玩家下令与批复请示、违令判定与记录。
##
## 所有函数都是静态的，第一个参数 war 是 CampaignState 实例（不标类型，避免与它互相引用）。

const Conduct = preload("res://scripts/officers/officer_conduct.gd")
const Policy = preload("res://scripts/agents/baseline_policy.gd")
const Corps = preload("res://scripts/war/campaign/army_corps.gd")
const Strategic = preload("res://scripts/war/campaign/strategic_ai.gd")
const Dissent = preload("res://scripts/agents/officer_dissent.gd")
const Autonomy = preload("res://scripts/agents/officer_autonomy.gd")


## 军队当前生效的军令：规则默认值叠加该军自己的设置。
static func orders_for(war, army: Dictionary) -> Dictionary:
	var orders: Dictionary = {"engage": true, "retreat": true, "pursue": true, "after_battle": "withdraw", "intent": str(war.rules.get("orders", {}).get("default_intent", "稳扎")), "risk_allowance": str(war.rules.get("orders", {}).get("default_risk", "常规")), "retreat_line": {"strength": 0.0, "morale": 0.0}}
	orders.merge(army.get("orders", {}), true)
	orders.erase("report_level")
	return orders


## 按风险许可过滤部队行动候选。
static func filter_candidates(war, candidates: Array, orders: Dictionary) -> Array:
	# 保守许可在候选生成阶段就挡掉侧击、追击等高风险行动。
	if str(orders.get("risk_allowance", "常规")) != "保守": return candidates
	return candidates.filter(func(candidate): return str(candidate.get("action", {}).get("type", "")) not in ["flank", "pursue"])


## 按风险许可过滤主帅分派的任务候选。
static func filter_commander_candidates(war, candidates: Array, orders: Dictionary) -> Array:
	if str(orders.get("risk_allowance", "常规")) != "保守": return candidates
	return candidates.filter(func(candidate): return str(candidate.get("action", {}).get("task", "")) not in ["raid_rear", "cut_supply"])


## 玩家修改军令或下撤军令；军团主队的军令同步给各部（自主拒令者除外）。
static func command_army(war, id: String, changes: Dictionary = {}, withdraw: bool = false) -> Dictionary:
	if war.campaign_finished(): return {"ok": false, "message": "战役已经结束"}
	if war.store.busy:
		return {"ok": false, "message": "日期正在推进，请稍候。"}
	var army: Dictionary = war.state["armies"].get(id, {})
	if army.is_empty() or army.get("faction", "") != war.state["player_faction"]:
		return {"ok": false, "message": "只能向本方军队下令。"}
	if army.get("status", "") == "ended":
		return {"ok": false, "message": "这支军队已结束任务。"}
	if withdraw and bool(army["returning"]):
		return {"ok": false, "message": "军队正在撤退。"}
	var orders: Dictionary = orders_for(war, army)
	for key in changes:
		if key in ["engage", "retreat", "pursue", "local_disengage", "must_hold_objective"] and typeof(changes[key]) == TYPE_BOOL:
			orders[key] = changes[key]
		elif key == "after_battle" and changes[key] in ["withdraw", "hold"]:
			orders[key] = changes[key]
		elif key == "intent" and changes[key] in war.rules.get("orders", {}).get("intents", ["速胜", "稳扎", "牵制", "斩首", "保存实力"]):
			orders[key] = changes[key]
		elif key == "risk_allowance" and changes[key] in war.rules.get("orders", {}).get("risk_levels", ["保守", "常规", "放手"]):
			orders[key] = changes[key]
		elif key == "retreat_line" and typeof(changes[key]) == TYPE_DICTIONARY:
			orders[key] = {"strength": clampf(float(changes[key].get("strength", 0.0)), 0.0, 1.0), "morale": clampf(float(changes[key].get("morale", 0.0)), 0.0, 100.0)}
		elif key in ["pursuit_limit_cells","local_retreat_cells"] and typeof(changes[key]) in [TYPE_INT,TYPE_FLOAT]: orders[key] = clampi(int(changes[key]),1,5)
		else:
			return {"ok": false, "message": "未知军令。"}
	if withdraw: orders["retreat"] = true
	var corps: Dictionary = war.state["corps"].get(army.get("corps_id", ""), {})
	if not corps.is_empty() and corps["root_id"] == id:
		for unit_id in corps["units"].duplicate():
			var unit: Dictionary = war.state["armies"][unit_id]
			if unit["status"] == "ended": continue
			if str(unit["officer_id"]) != str(corps["commander_id"]):
				Autonomy.ensure_evaluated(war, corps, str(unit["officer_id"]), {"action": {"type": "player_orders"}, "reason": "玩家军令"})
				if Autonomy.blocks_override(war, corps, str(unit["officer_id"])).get("blocked", false): continue
			unit["orders"] = orders.duplicate(true)
			unit["decision_key"] = ""
	var refused := false
	if not corps.is_empty() and str(army["officer_id"]) != str(corps["commander_id"]):
		Autonomy.ensure_evaluated(war, corps, str(army["officer_id"]), {"action": {"type": "player_orders"}, "reason": "玩家军令"})
		refused = bool(Autonomy.blocks_override(war, corps, str(army["officer_id"])).get("blocked", false))
	if not refused: army["orders"] = orders
	army["decision_key"] = ""
	if withdraw:
		army["last_reason"] = "收到主公撤军令，各部将独立决定执行。"
		if not corps.is_empty() and corps["root_id"] == id:
			Corps.issue(war, corps, {"type": "withdraw_corps"}, "玩家撤军令")
		elif corps.is_empty() or not Autonomy.blocks_override(war, corps, str(army["officer_id"])).get("blocked", false):
			war._execute(army, {"type": "withdraw"})
		war._report(army, "撤退军令", army["name"] + "已收到撤退命令。", false)
	war.store._save()
	war.store.campaign_changed.emit()
	return {"ok": true, "message": "撤退军令已下达，各角色按自身判断执行。" if withdraw else "军令已更新。"}


## 玩家批准或驳回违令请示；批准即执行建议的行动。
static func resolve_request(war, army_id: String, approve: bool) -> Dictionary:
	if war.campaign_finished(): return {"ok": false, "message": "战役已经结束"}
	if war.store.busy: return {"ok": false, "message": "日期正在推进，请稍候。"}
	var army: Dictionary = war.state["armies"].get(army_id, {})
	var request: Dictionary = army.get("pending_request", {})
	if army.is_empty() or request.is_empty(): return {"ok": false, "message": "没有待批复的请示。"}
	if str(army.get("faction", "")) != str(war.state["player_faction"]): return {"ok": false, "message": "只能批复本方请示。"}
	var officer: Dictionary = war.roster.officers.get(str(army["officer_id"]), {})
	army.erase("pending_request")
	if approve:
		var action: Dictionary = request.get("action", {}).duplicate(true)
		var reason: String = str(request.get("reason", "临机行动"))
		army["trust"] = minf(0.5, float(army.get("trust", 0.0)) + 0.1)
		war._report(army, "违令批准", "主公批准%s执行建议：%s。" % [army["name"], reason], true)
		# 批准即执行。只写 approved_action 会绕过 _execute 的副作用（march 不写
		# location.from/to/edge、scout 不更新 scouted_at、resupply 不转粮、
		# request_support 不发报），而次日 step 把 last_decision 置为当日又让
		# validate_decision 的两次校验全部过期，部队原地冻结且不入复盘记录。
		war._execute(army, action)
		if str(army.get("status", "active")) != "ended":
			army["last_reason"] = "主公批准违令：" + reason
			# 只记当日，不预写次日；否则明日两次校验都会被判为已执行。
			army["last_decision"] = int(war.state["tick"])
			army["decision_key"] = ""
			_record_approved(war, army, request, action)
	else:
		if float(officer.get("personality", {}).get("自尊", 50)) >= 65.0: army["resentment"] = minf(0.5, float(army.get("resentment", 0.0)) + 0.1)
		war._report(army, "违令驳回", "主公驳回%s的违令请示，按原军令执行。" % army["name"], false)
	war.store._save()
	war.store.campaign_changed.emit()
	return {"ok": true, "approved": approve}


# 主公批准的违令也要进入复盘记录，否则决策历史里查不到这天为什么反常。
static func _record_approved(war, army: Dictionary, request: Dictionary, action: Dictionary) -> void:
	var summary := "主公批准违令：" + str(request.get("reason", "临机行动"))
	var record: Dictionary = {"request_id": "approved:%s:%d" % [str(army["id"]), int(war.state["tick"])], "tick": int(war.state["tick"]), "army_id": army["id"], "candidate_id": str(request.get("candidate_id", "")), "action": action.duplicate(true), "reason_summary": summary, "source": "player_approval", "model": "", "rules_version": war.rules["version"], "prompt_version": 5, "policy_version": Policy.version(), "weights_version": Policy.weights().get("version", 0), "score_breakdown": {}, "vetoed": false, "fallback_reason": "", "observation": war.context_for(army).duplicate(true)}
	war.state["decisions"].append(record)
	while war.state["decisions"].size() > 160: war.state["decisions"].pop_front()
	if not army.has("decision_history"): army["decision_history"] = []
	army["decision_history"].append(record)


## 上一日未批复的违令请示作废，按原军令执行。
static func _expire_requests(war) -> void:
	for army in war.state["armies"].values():
		var request: Dictionary = army.get("pending_request", {})
		if request.is_empty(): continue
		if int(request.get("tick", 0)) >= int(war.state["tick"]): continue
		army.erase("pending_request")
		war._report(army, "请示超时", "%s的违令请示未获批复，按原军令执行。" % army["name"], false)


## 自由选择与军令选择差距过大时掷违令：服从、直接违令、由主公裁决或向玩家请示。
static func _evaluate_dissent(war, army: Dictionary, context: Dictionary, record: Dictionary) -> void:
	if army.get("returning", false) or str(army["status"]) == "ended": return
	if army.has("pending_request"): return
	var ranked_free: Array = Policy.rank(context, false)
	if ranked_free.is_empty(): return
	var ordered_top := str(Policy.choose(context).get("candidate_id", ""))
	var best_free: Dictionary = ranked_free[0]
	if str(best_free["candidate"]["id"]) == ordered_top: return
	var params: Dictionary = war.rules.get("orders", {}).get("dissent", {})
	var ordered_score := 0.0
	for entry in ranked_free:
		if str(entry["candidate"]["id"]) == ordered_top: ordered_score = float(entry["score"])
	var gap := float(best_free["score"]) - ordered_score
	if gap <= float(params.get("gap", 12)): return
	var officer: Dictionary = war.roster.officers.get(str(army["officer_id"]), {})
	var relation_name := "中立"
	var corps: Dictionary = war.state["corps"].get(army.get("corps_id", ""), {})
	if not corps.is_empty():
		relation_name = Dissent.relation(officer, war.roster.officers.get(str(corps.get("commander_id", "")), {}))
	var orders: Dictionary = orders_for(war, army)
	var contact: Dictionary = army.get("tactical", {}).get("contact", {})
	var urgent := Dissent.urgent(army, contact, war.supply_enabled())
	var probability := clampf(Dissent.probability(army, officer.get("personality", {}), orders, relation_name, urgent, float(army.get("counter_intel_dissent", 0.0)), params) + Conduct.dissent_shift(officer), 0.0, float(params.get("max", 0.6)))
	var roll := Dissent.roll("%s:%d:%s:dissent" % [str(war.state.get("dissent_seed", 0)), army["id"], int(war.state["tick"])], war.state)
	var entry: Dictionary = {"tick": war.state["tick"], "army_id": army["id"], "probability": probability, "gap": gap, "ordered": ordered_top, "suggested": best_free["candidate"]["id"], "roll": roll, "relation": relation_name, "urgent": urgent}
	if roll >= probability:
		entry["result"] = "服从"
		_append_dissent(war, army, entry)
		record["dissent"] = entry
		return
	var extreme := float(officer.get("personality", {}).get("自尊", 50)) >= 85.0 and float(officer.get("personality", {}).get("风险承受", 50)) >= 85.0
	if bool(params.get("direct", false)) and extreme:
		entry["result"] = "直接违令"
		war._execute(army, best_free["candidate"]["action"].duplicate(true))
		army["last_reason"] = "违令：" + str(best_free["candidate"].get("description", "临机行动"))
		war._report(army, "违令", "%s拒绝遵从军令，擅自%s。" % [army["name"], str(best_free["candidate"].get("description", "临机行动"))], true)
		_append_dissent(war, army, entry)
		record["dissent"] = entry
		return
	if str(army["faction"]) != str(war.state["player_faction"]):
		var lord := Strategic.lord_of(war.roster, str(army["faction"]))
		var permit := urgent or float(lord.get("personality", {}).get("风险承受", 50)) >= 45.0
		entry["result"] = "主公批准" if permit else "主公驳回"
		if permit:
			war._execute(army, best_free["candidate"]["action"].duplicate(true))
			army["last_reason"] = "主公批准临机调整：" + str(best_free["candidate"].get("description", ""))
		_append_dissent(war, army, entry)
		record["dissent"] = entry
		return
	entry["result"] = "建议违令"
	army["pending_request"] = {"tick": war.state["tick"], "army_id": army["id"], "officer_id": army["officer_id"], "officer": army["name"], "candidate_id": best_free["candidate"]["id"], "action": best_free["candidate"]["action"].duplicate(true), "reason": str(best_free["candidate"].get("description", "临机行动")), "probability": probability, "gap": gap}
	war._report(army, "违令请示", "%s请求违令：建议%s（把握%.0f%%），等待主公批复。" % [army["name"], str(best_free["candidate"].get("description", "临机行动")), probability * 100.0], true)
	_append_dissent(war, army, entry)
	record["dissent"] = entry


## 追加一条违令记录，只留最近 12 条。
static func _append_dissent(war, army: Dictionary, entry: Dictionary) -> void:
	if not army.has("dissent_history"): army["dissent_history"] = []
	army["dissent_history"].append(entry)
	while army["dissent_history"].size() > 12: army["dissent_history"].pop_front()


## 部队是否处于自主行动期，或主帅的军令对它无效。
static func _has_independent_action(war, army: Dictionary) -> bool:
	var autonomy: Dictionary = army.get("autonomy", {})
	if str(autonomy.get("stance", "obey")) != "obey" and int(autonomy.get("until", 0)) > int(war.state["tick"]): return true
	var corps: Dictionary = war.state["corps"].get(army.get("corps_id", ""), {})
	return not corps.is_empty() and bool(Autonomy.blocks_override(war, corps, str(army["officer_id"])).get("blocked", false))
