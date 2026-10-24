extends SceneTree

const Policy = preload("res://scripts/agents/baseline_policy.gd")
const Dissent = preload("res://scripts/agents/officer_dissent.gd")
const Roster = preload("res://scripts/agents/officer_context.gd")
var failures: Array = []


func check(value: bool, message: String) -> void:
	if not value: failures.append(message); push_error(message)


func persona(values: Dictionary = {}) -> Dictionary:
	var out := {}
	for axis in Roster.AXES: out[axis] = float(values.get(axis, 50))
	return out


func context(orders: Dictionary, personality: Dictionary, army: Dictionary = {}) -> Dictionary:
	var own := {"strength": 5000, "initial_strength": 5000, "morale": 80, "organization": 80, "grain_days": 10, "units": {"infantry": 5000}}
	own.merge(army, true)
	return {"officer": {"personality": personality}, "army": own, "orders": orders, "enemies": [], "allies": [], "operation": {}, "mission_type": "capture", "observation_revision": 7, "candidates": [{"id": "engage", "action": {"type": "engage"}, "description": "与敌交战。"}, {"id": "hold", "action": {"type": "hold"}, "description": "驻守待命。"}, {"id": "withdraw", "action": {"type": "withdraw"}, "description": "撤退保存兵力。"}]}


func _initialize() -> void: call_deferred("_run")


func _run() -> void:
	var store: Node = root.get_node("GameState")
	store.persist_enabled = false
	var old_day: int = store.day
	var old_tick: int = store.war.state["tick"]
	var original_agent: Node = store.agent
	store.prepare_battle_test()
	var war = store.war
	# 军令过滤候选：保守许可挡掉侧击与追击；常规不动；主帅不派绕后截粮。
	var pool: Array = [{"id": "a", "action": {"type": "flank"}}, {"id": "b", "action": {"type": "pursue"}}, {"id": "c", "action": {"type": "engage"}}, {"id": "d", "action": {"type": "hold"}}]
	var conservative: Array = war.filter_candidates(pool, {"risk_allowance": "保守"})
	check(conservative.size() == 2 and not conservative.any(func(candidate): return candidate["action"]["type"] in ["flank", "pursue"]), "保守许可不生成侧击与追击候选")
	check(war.filter_candidates(pool, {"risk_allowance": "常规"}).size() == 4, "常规许可保持全部候选")
	var commander_pool: Array = [{"id": "r", "action": {"type": "detach", "task": "raid_rear"}}, {"id": "s", "action": {"type": "assign_task", "task": "cut_supply"}}, {"id": "m", "action": {"type": "assign_task", "task": "main_attack"}}, {"id": "f", "action": {"type": "assign_task", "task": "flank"}}]
	var commander_filtered: Array = war.filter_commander_candidates(commander_pool, {"risk_allowance": "保守"})
	check(commander_filtered.size() == 2 and not commander_filtered.any(func(candidate): return candidate["action"].get("task", "") in ["raid_rear", "cut_supply"]), "保守主帅不派绕后与截粮")
	# 默认军令书：字段齐全且新旧行为等价（稳扎无偏置时自由评分与军令评分一致）。
	var defaults: Dictionary = war.orders_for({})
	check(str(defaults["intent"]) == "稳扎" and str(defaults["risk_allowance"]) == "常规" and not defaults.has("report_level"), "缺省军令书字段")
	var firm: Dictionary = war.orders_for({"orders": {"intent": "保存实力"}})
	check(str(firm["intent"]) == "保存实力" and str(firm["risk_allowance"]) == "常规", "存档军令合并缺省")
	var base_context := context(defaults, persona())
	var ordered: Dictionary = Policy.choose(base_context)
	var free: Dictionary = Policy.choose(base_context, false)
	check(str(ordered["candidate_id"]) == str(free["candidate_id"]) and is_equal_approx(float(ordered["score"]), float(free["score"])), "稳扎缺省下军令评分与自由评分等价")
	var saved_intent := defaults.duplicate(true)
	saved_intent["intent"] = "保存实力"
	check(Policy.best_of(context(saved_intent, persona()), ["engage"]) < Policy.best_of(base_context, ["engage"]) - 0.001, "保存实力降低接战倾向")
	check(Policy.best_of(context(defaults, persona()), ["hold"]) < Policy.best_of(context(war.orders_for({"orders": {"intent": "牵制"}}), persona()), ["hold"]) - 0.001, "牵制提高守位倾向")
	# 撤退线：兵力低于下限时撤退候选获得强制加分，越过军令偏置。
	var line_orders: Dictionary = war.orders_for({"orders": {"retreat_line": {"strength": 0.5, "morale": 0.0}}})
	var line_context := context(line_orders, persona(), {"strength": 2000, "initial_strength": 5000})
	check(Policy.best_of(line_context, ["withdraw"]) > Policy.best_of(base_context, ["withdraw"]), "撤退线为撤退候选强制加分")
	# 违令概率公式、上下限与封顶0.6。
	var params: Dictionary = war.rules["orders"]["dissent"]
	var neutral: float = Dissent.probability({}, persona(), defaults, "中立", false, 0.0, params)
	check(is_equal_approx(neutral, 0.15 + 0.03), "概率基础公式（基础+稳扎严格度）")
	var extreme: float = Dissent.probability({}, persona({"自尊": 100, "风险承受": 100, "决断": 100, "忠义": 0, "秩序偏好": 0, "自制": 0}), defaults, "宿怨", true, 0.2, params)
	check(is_equal_approx(extreme, 0.6), "违令概率封顶0.6")
	var loyal: float = Dissent.probability({"trust": 0.2}, persona({"自尊": 0, "风险承受": 0, "决断": 0, "忠义": 100, "秩序偏好": 100, "自制": 100}), defaults, "同袍", false, 0.0, params)
	check(loyal >= 0.0 and loyal < neutral, "忠义秩序自制与信任降低违令概率")
	# 固定种子可复现。
	check(is_equal_approx(Dissent.roll("1910901:army-0001:12:dissent"), Dissent.roll("1910901:army-0001:12:dissent")), "同一决策违令结果可复现")
	check(not is_equal_approx(Dissent.roll("1910901:army-0001:12:dissent"), Dissent.roll("1910901:army-0001:13:dissent")), "不同日决策种子不同")
	# 默认军令下不产生违令记录（自由评分与军令评分一致）。
	var corps: Dictionary = war.state["corps"].values().filter(func(c): return c["faction"] == war.state["player_faction"])[0]
	var army: Dictionary = war.state["armies"][corps["root_id"]]
	var record: Dictionary = {}
	war._evaluate_dissent(army, war.context_for(army), record)
	check(not army.has("dissent_history") and record.is_empty(), "默认军令不触发违令")
	# 请示批准：立刻按 _execute 执行建议并增加信任。
	# 旧实现只写 approved_action，次日 step 绕过 _execute 直接赋值 action，行军/侦察/
	# 补粮/求援全无副作用，且 last_decision 被预置为当日使模型与本地兜底两次校验都过期。
	army["pending_request"] = {"tick": war.state["tick"], "action": {"type": "hold"}, "reason": "测试建议", "probability": 0.5}
	var approved: Dictionary = war.resolve_request(army["id"], true)
	check(bool(approved.get("ok", false)) and not army.has("pending_request") and float(army.get("trust", 0.0)) > 0.0, "批准请示并增加信任")
	check(not army.has("approved_action"), "批准不再留下待执行动作")
	check(str(army["action"]["type"]) == "hold" and int(army["last_decision"]) == int(war.state["tick"]), "批准的建议当日即成为行动")
	var history: Array = army.get("decision_history", [])
	check(history.size() > 0 and str(history[-1].get("source", "")) == "player_approval", "批准的决策进入复盘记录")
	# 侦察类批准必须真的更新 scouted_at（走 _execute 而不是直接赋值 action）。
	army.erase("scouted_at")
	army["pending_request"] = {"tick": war.state["tick"], "action": {"type": "scout"}, "reason": "先侦察", "probability": 0.5}
	war.resolve_request(army["id"], true)
	check(int(army["scouted_at"]) == int(war.state["tick"]), "批准的侦察立刻更新侦察日")
	# 行军类批准必须写 location.from/to/edge；旧实现下这些字段永远为空，部队原地不动。
	var saved_location: Dictionary = army["location"].duplicate(true)
	var link: Dictionary = war.graph.neighbors(str(army["location"]["node"]))[0]
	# Exercise approval side effects on a legal friendly transit node.
	store.city_state(str(link["node"]))["faction"] = army["faction"]
	army["pending_request"] = {"tick": war.state["tick"], "action": {"type": "march", "target": str(link["node"]), "edge": str(link["edge"])}, "reason": "立即出发", "probability": 0.5}
	war.resolve_request(army["id"], true)
	check(str(army["location"].get("edge", "")) == str(link["edge"]) and str(army["location"].get("to", "")) == str(link["node"]), "批准的行军真正落到 location")
	army["location"] = saved_location
	army["action"] = {"type": "hold"}
	# 求援类批准必须登记求援日。
	army["pending_request"] = {"tick": war.state["tick"], "action": {"type": "request_support"}, "reason": "请求增援", "probability": 0.5}
	war.resolve_request(army["id"], true)
	check(int(army["last_support"]) == int(war.state["tick"]), "批准的求援登记求援日")
	# 请示驳回：清空请示，自尊高者增加不满。
	army["pending_request"] = {"tick": war.state["tick"], "action": {"type": "hold"}, "reason": "测试建议", "probability": 0.5}
	var rejected: Dictionary = war.resolve_request(army["id"], false)
	check(bool(rejected.get("ok", false)) and not army.has("pending_request"), "驳回清空请示")
	# 超时默认驳回。
	army["pending_request"] = {"tick": int(war.state["tick"]) - 1, "action": {"type": "hold"}, "reason": "测试建议", "probability": 0.5}
	var report_count: int = war.state["reports"].size()
	war._expire_requests()
	check(not army.has("pending_request") and army["memory"].any(func(item): return item["kind"] == "请示超时"), "超时默认驳回并保留本地记录")
	check(war.state["reports"].size() == report_count, "日常请示超时不主动发报")
	# 非玩家势力不能由玩家批复。
	var enemy_army: Dictionary = war.active_armies().filter(func(a): return a["faction"] != war.state["player_faction"])[0]
	enemy_army["pending_request"] = {"tick": war.state["tick"], "action": {"type": "hold"}, "reason": "测试建议", "probability": 0.5}
	check(not bool(war.resolve_request(enemy_army["id"], true).get("ok", false)), "非本方请示不可批复")
	enemy_army.erase("pending_request")
	# 存档恢复后 pending_request 保持。
	army["pending_request"] = {"tick": war.state["tick"], "action": {"type": "hold"}, "reason": "存档测试", "probability": 0.4}
	var exported: Dictionary = war.export_state()
	var sandbox := preload("res://scripts/core/game_state.gd").new()
	sandbox.persist_enabled = false
	sandbox._load_demo()
	sandbox.war.setup(sandbox, exported)
	var restored: Dictionary = sandbox.war.state["armies"][army["id"]].get("pending_request", {})
	check(str(restored.get("reason", "")) == "存档测试" and int(restored.get("tick", -1)) == int(war.state["tick"]), "存档恢复后请示保持")
	sandbox.free()
	army.erase("pending_request")
	# 端到端：批准违令后的次日部队必须重新决策，而不是被 last_decision 冻结。
	# 旧实现把 last_decision 写成当日，次日模型与本地兜底两次校验都被判过期，
	# decision_key 又被写回，于是既不执行也不记录，最长三日原地不动。
	# 走的是自由部队路径——军团成员由主帅下令，不经过 decision_key 重判。
	var owner_army: Dictionary = war.state["armies"][corps["root_id"]]
	var free_officer_id: String = war.roster.militia(str(war.state["player_faction"]), str(owner_army["home"]))
	var free_preview: Dictionary = war.preview_dispatch(str(owner_army["home"]), str(owner_army["target"]), free_officer_id)
	var free_army: Dictionary = war._mobilize(free_preview)
	free_army["last_decision"] = int(war.state["tick"])
	free_army["pending_request"] = {"tick": war.state["tick"], "action": {"type": "hold"}, "reason": "冻结回归", "probability": 0.5}
	war.resolve_request(free_army["id"], true)
	var before_history: int = free_army.get("decision_history", []).size()
	await war.step(null)
	check(int(free_army["last_decision"]) >= int(war.state["tick"]), "批准后部队的决策日没有推进")
	check(free_army.get("decision_history", []).size() > before_history, "批准后次日没有重新决策")
	store.restore_battle_test()
	check(store.day == old_day and store.war.state["tick"] == old_tick and store.agent == original_agent, "测试退出恢复原战役")
	print("ORDERS_DISSENT_VALIDATION: " + ("PASS" if failures.is_empty() else str(failures)))
	quit(0 if failures.is_empty() else 1)
