extends RefCounted

const Graph = preload("res://scripts/war/campaign/map_graph.gd")
const Roster = preload("res://scripts/agents/officer_context.gd")
const Repository = preload("res://scripts/officers/officer_repository.gd")
const Traits = preload("res://scripts/officers/trait_registry.gd")
const Process = preload("res://scripts/officers/officer_process.gd")
const Signature = preload("res://scripts/officers/signature_traits.gd")
const Explain = preload("res://scripts/officers/officer_explain.gd")
const Conduct = preload("res://scripts/officers/officer_conduct.gd")
const Fate = preload("res://scripts/war/campaign/officer_fate.gd")
const Combat = preload("res://scripts/war/battle/combat_system.gd")
const Policy = preload("res://scripts/agents/baseline_policy.gd")
const Corps = preload("res://scripts/war/campaign/army_corps.gd")
const Tactical = preload("res://scripts/war/battle/tactical_battlefield.gd")
const Terrain = preload("res://scripts/war/battle/battle_terrain.gd")
const Duel = preload("res://scripts/war/duel/duel_system.gd")
const Feedback = preload("res://scripts/war/battle/battle_feedback.gd")
const ReportPolicy = preload("res://scripts/war/campaign/report_policy.gd")
const Siege = preload("res://scripts/war/battle/siege_system.gd")
const Edges = preload("res://scripts/war/campaign/officer_edges.gd")
const Strategic = preload("res://scripts/war/campaign/strategic_ai.gd")
const Battlefields = preload("res://scripts/war/campaign/campaign_battlefields.gd")
const Fortifications = preload("res://scripts/war/battle/city_fortifications.gd")
const Lifecycle = preload("res://scripts/war/campaign/faction_lifecycle.gd")
const Operations = preload("res://scripts/war/campaign/campaign_operations.gd")
const Dissent = preload("res://scripts/agents/officer_dissent.gd")
const Forecast = preload("res://scripts/agents/forecast.gd")
const Experience = preload("res://scripts/agents/experience.gd")
const UnitBrain = preload("res://scripts/agents/unit_brain.gd")
const OfficerBrain = preload("res://scripts/agents/officer_brain.gd")
const Autonomy = preload("res://scripts/agents/officer_autonomy.gd")
const TacticalPlan = preload("res://scripts/agents/tactical_plan.gd")
var store: Node
var graph = Graph.new()
var roster = Roster.new()
var rules: Dictionary = {}
var state: Dictionary = {}
var urgent_event := false
var generation := 0
var planner = preload("res://scripts/agents/decision_scheduler.gd").new()
var rng := RandomNumberGenerator.new()


func setup(owner: Node, saved: Dictionary = {}) -> void:
	generation += 1
	planner.clear()
	store = owner
	rules = _json("res://data/war/campaign_rules.json")
	graph.setup(_json("res://data/world_map.json"))
	for edge in graph.edges.values():
		if Fortifications.road_path(store, str(edge["from"]), str(edge["to"])).is_empty(): graph.closed_routes.append(edge["id"])
	roster.setup(Repository.cards(), rules.get("faction_mapping", {}))
	state = {"version": 2, "tick": 0, "next_id": 1, "player_faction": "liu_bei", "armies": {}, "corps": {}, "sieges": {}, "missions": {}, "reports": [], "report_policy": {"sent": {}}, "decisions": [], "officer_states": {}, "officer_fates": {}, "officer_kills": {}, "officer_personal_kills": {}, "officer_personal_soldiers": {}, "garrison_commanders": {}, "battle_victories": {}, "defense_cooldowns": {}, "rng_state": "0", "dissent_seed": 0, "dissent_state": 0, "duels": {"pairs": {}, "counts": {}, "records": []}, "battle_feedback": {}, "strategy_log": []}
	if not saved.is_empty():
		for key in state:
			if saved.has(key) and typeof(state[key]) == TYPE_INT and typeof(saved[key]) in [TYPE_INT, TYPE_FLOAT]:
				state[key] = int(saved[key])
			elif saved.has(key) and typeof(saved[key]) == typeof(state[key]):
				state[key] = saved[key]
	state["version"] = 3
	state["battle_ai_version"] = 1
	state["battle_round"] = int(saved.get("battle_round",state["tick"]))
	for key in ["battle_ai_messages","battle_ai_model_log","battle_ai_replay"]:
		state[key] = saved.get(key,[]).duplicate(true) if saved.get(key,[]) is Array else []
	state["battle_ai_shadow"] = []
	state["officer_agents"] = saved.get("officer_agents",{}).duplicate(true) if saved.get("officer_agents",{}) is Dictionary else {}
	for key in ["faction_action_points", "faction_intel", "battlefields", "generated_officers", "faction_status", "city_policies", "campaign_result", "relations"]:
		state[key] = saved.get(key, {}).duplicate(true) if saved.get(key, {}) is Dictionary else {}
	state["campaign_started"] = bool(saved.get("campaign_started", false))
	if not saved.has("relations"): state["relations"] = store.scenario.get("relations", rules.get("relations", {})).duplicate(true)
	state["city_volleys"] = []
	for id in state["generated_officers"]: roster.officers[id] = state["generated_officers"][id].duplicate(true)
	roster.ensure_factions(store.scenario)
	for id in roster.officers:
		if roster.officers[id].get("generated", false): state["generated_officers"][id] = roster.officers[id].duplicate(true)
	if saved.get("battlefield") is Dictionary:
		state["battlefield"] = saved["battlefield"].duplicate(true)
		if not state["battlefield"].has("battle_id"): state["battlefield"]["battle_id"] = "field:" + str(state["battlefield"].get("anchor",0))
	rng.seed = 1910901
	if int(state.get("rng_state", 0)) != 0:
		rng.state = int(state["rng_state"])
	# 违令掷点走独立随机流：种子来自剧本/存档，而不是当日战斗随机流的快照，
	# 否则任何一处战斗消耗的差异都会改写全部违令结果，"同种子可复现"不再成立。
	state["dissent_seed"] = int(state.get("dissent_seed", 0))
	for army in state["armies"].values():
		# 旧档缺将领档案时先补登记，再回写 officer_id；只补不写会留下悬空引用。
		var previous_id := str(army.get("officer_id", ""))
		army["officer_id"] = roster.adopt_militia(army)
		if army["officer_id"] != previous_id:
			var previous_state: Dictionary = state["officer_states"].get(previous_id, {})
			if not previous_state.is_empty(): state["officer_states"].erase(previous_id)
			var entry: Dictionary = state["officer_states"].get(army["officer_id"], {})
			if entry.is_empty(): entry = previous_state
			entry["status"] = str(entry.get("status", "commanding"))
			entry["army_id"] = army["id"]
			state["officer_states"][army["officer_id"]] = entry
		var officer: Dictionary = roster.officers.get(str(army.get("officer_id", "")), {})
		if army.get("action", {}).get("type", "") == "scout": army["action"] = {"type": "hold"}
		army["trait_ids"] = officer.get("trait_ids", []).duplicate()
		army.erase("battle_traits")
		army["edge"] = Edges.ensure(army, officer)
		if army.has("tactical") and state.has("battlefield") and not army.has("battlefield_id"): army["battlefield_id"] = state["battlefield"]["battle_id"]
	for corps in state["corps"].values():
		Corps.migrate(self, corps)
		corps["leader_lost"] = bool(corps.get("leader_lost", false))
		corps["leader_lost_for"] = str(corps.get("leader_lost_for", ""))
		corps.erase("last_requested")
		corps.erase("request_signature")
	if not supply_enabled():
		for army in state["armies"].values():
			if army.get("action", {}).get("type", "") == "resupply": army["action"] = {"type": "hold"}
			if army.get("corps_task", {}).get("type", "") == "cut_supply":
				army["corps_task"] = {"type": "flank", "reason": "侧翼协同", "issued_at": state["tick"]}
		for corps in state["corps"].values():
			corps["known_supplies"] = {}
			corps["siege_mode"] = "assault"
			corps["supply"]["blocked_until"] = 0
	for army in state["armies"].values(): Experience.ensure(army)
	for guard in state["garrison_commanders"].values():
		var officer_id: String = str(guard["officer_id"])
		if roster.officers.has(officer_id) or not officer_id.begins_with("militia:"): continue
		var resolved := roster.adopt_militia({"officer_id": officer_id, "faction": str(guard["faction"])})
		if resolved != officer_id: guard["officer_id"] = resolved
	preload("res://scripts/war/campaign/legacy_formation_migration.gd").apply(state)
	Fate.restore(self)
	Duel.journal(self)
	for id in state["duels"].get("stamina", {}):
		Duel.stamina(self, {"officer_id":id})
	Tactical.migrate_positions(self)
	# Old saves may still contain leaderless formations on an orderly return route.
	for army in active_armies():
		if army.get("commander_unavailable", false) and Fate.unavailable(self, str(army["officer_id"])):
			Fate.disperse(self, army)
	if not state.has("battlefield"):
		for board in state["battlefields"].values():
			state["battlefield"] = board
			Tactical.migrate_positions(self)
			state.erase("battlefield")
	for city in store.scenario.get("places", {}).values():
		if city.has("garrison"):
			_sync_inventory(city)
	Lifecycle.maintain(self)
	Operations.residence(self)
	for army in active_armies():
		if army.has("tactical"): TacticalPlan.ensure(self,army)
	OfficerBrain.initialize(self)
	ReportPolicy.migrate(state)
	_observe_all()
	ReportPolicy.observe(self)


func _json(path: String) -> Variant:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var data: Variant = JSON.parse_string(file.get_as_text())
	return data


func export_state() -> Dictionary:
	state["rng_state"] = str(rng.state)
	var snapshot := state.duplicate(true)
	snapshot.erase("battle_ai_metrics")
	snapshot.erase("battle_ai_shadow")
	for corps in snapshot["corps"].values():
		corps.erase("last_requested")
		corps.erase("request_signature")
	return snapshot


func active_armies(faction: String = "") -> Array:
	var result: Array = []
	for army in state["armies"].values():
		if str(army.get("status", "")) != "ended" and (faction == "" or str(army["faction"]) == faction):
			result.append(army)
	result.sort_custom(func(a, b): return str(a["id"]) < str(b["id"]))
	return result

func ready(army: Dictionary) -> bool:
	return int(army.get("departure_at", 0)) <= int(state["tick"])

func is_besieged(city: String) -> bool:
	var siege: Dictionary = state["sieges"].get(city, {})
	return int(siege.get("active_tick", -100)) >= int(state["tick"]) - 1 and siege.get("phase", "") not in ["occupied", "解围"]

func hostile(first: String, second: String) -> bool:
	if first == second: return false
	var pair: Array = [first, second]
	pair.sort()
	return state.get("relations", {}).get("|".join(pair), "hostile") == "hostile"

func can_cross(faction: String, node: String) -> bool:
	var owner := str(store.city_state(node).get("faction", ""))
	if owner == "" or owner == faction: return true
	var pair: Array = [faction, owner]
	pair.sort()
	return state.get("relations", {}).get("|".join(pair), "hostile") == "allied"

func route(faction: String, start: String, finish: String) -> Dictionary:
	var excluded: Array = []
	for node in graph.places:
		if node != start and node != finish and not can_cross(faction, str(node)): excluded.append(node)
	return graph.path(start, finish, excluded)

func campaign_finished() -> bool:
	return not state.get("campaign_result", {}).is_empty()

func start_campaign() -> void:
	state["campaign_started"] = true
	Operations.residence(self)


func orders_for(army: Dictionary) -> Dictionary:
	var orders: Dictionary = {"engage": true, "retreat": true, "pursue": true, "after_battle": "withdraw", "intent": str(rules.get("orders", {}).get("default_intent", "稳扎")), "risk_allowance": str(rules.get("orders", {}).get("default_risk", "常规")), "retreat_line": {"strength": 0.0, "morale": 0.0}}
	orders.merge(army.get("orders", {}), true)
	orders.erase("report_level")
	return orders


func filter_candidates(candidates: Array, orders: Dictionary) -> Array:
	# 保守许可在候选生成阶段就挡掉侧击、追击等高风险行动。
	if str(orders.get("risk_allowance", "常规")) != "保守": return candidates
	return candidates.filter(func(candidate): return str(candidate.get("action", {}).get("type", "")) not in ["flank", "pursue"])


func filter_commander_candidates(candidates: Array, orders: Dictionary) -> Array:
	if str(orders.get("risk_allowance", "常规")) != "保守": return candidates
	return candidates.filter(func(candidate): return str(candidate.get("action", {}).get("task", "")) not in ["raid_rear", "cut_supply"])


func command_army(id: String, changes: Dictionary = {}, withdraw: bool = false) -> Dictionary:
	if campaign_finished(): return {"ok": false, "message": "战役已经结束"}
	if store.busy:
		return {"ok": false, "message": "日期正在推进，请稍候。"}
	var army: Dictionary = state["armies"].get(id, {})
	if army.is_empty() or army.get("faction", "") != state["player_faction"]:
		return {"ok": false, "message": "只能向本方军队下令。"}
	if army.get("status", "") == "ended":
		return {"ok": false, "message": "这支军队已结束任务。"}
	if withdraw and bool(army["returning"]):
		return {"ok": false, "message": "军队正在撤退。"}
	var orders: Dictionary = orders_for(army)
	for key in changes:
		if key in ["engage", "retreat", "pursue", "local_disengage", "must_hold_objective"] and typeof(changes[key]) == TYPE_BOOL:
			orders[key] = changes[key]
		elif key == "after_battle" and changes[key] in ["withdraw", "hold"]:
			orders[key] = changes[key]
		elif key == "intent" and changes[key] in rules.get("orders", {}).get("intents", ["速胜", "稳扎", "牵制", "斩首", "保存实力"]):
			orders[key] = changes[key]
		elif key == "risk_allowance" and changes[key] in rules.get("orders", {}).get("risk_levels", ["保守", "常规", "放手"]):
			orders[key] = changes[key]
		elif key == "retreat_line" and typeof(changes[key]) == TYPE_DICTIONARY:
			orders[key] = {"strength": clampf(float(changes[key].get("strength", 0.0)), 0.0, 1.0), "morale": clampf(float(changes[key].get("morale", 0.0)), 0.0, 100.0)}
		elif key in ["pursuit_limit_cells","local_retreat_cells"] and typeof(changes[key]) in [TYPE_INT,TYPE_FLOAT]: orders[key] = clampi(int(changes[key]),1,5)
		else:
			return {"ok": false, "message": "未知军令。"}
	if withdraw: orders["retreat"] = true
	var corps: Dictionary = state["corps"].get(army.get("corps_id", ""), {})
	if not corps.is_empty() and corps["root_id"] == id:
		for unit_id in corps["units"].duplicate():
			var unit: Dictionary = state["armies"][unit_id]
			if unit["status"] == "ended": continue
			if str(unit["officer_id"]) != str(corps["commander_id"]):
				Autonomy.ensure_evaluated(self, corps, str(unit["officer_id"]), {"action": {"type": "player_orders"}, "reason": "玩家军令"})
				if Autonomy.blocks_override(self, corps, str(unit["officer_id"])).get("blocked", false): continue
			unit["orders"] = orders.duplicate(true)
			unit["decision_key"] = ""
	var refused := false
	if not corps.is_empty() and str(army["officer_id"]) != str(corps["commander_id"]):
		Autonomy.ensure_evaluated(self, corps, str(army["officer_id"]), {"action": {"type": "player_orders"}, "reason": "玩家军令"})
		refused = bool(Autonomy.blocks_override(self, corps, str(army["officer_id"])).get("blocked", false))
	if not refused: army["orders"] = orders
	army["decision_key"] = ""
	if withdraw:
		army["last_reason"] = "收到主公撤军令，各部将独立决定执行。"
		if not corps.is_empty() and corps["root_id"] == id:
			Corps.issue(self, corps, {"type": "withdraw_corps"}, "玩家撤军令")
		elif corps.is_empty() or not Autonomy.blocks_override(self, corps, str(army["officer_id"])).get("blocked", false):
			_execute(army, {"type": "withdraw"})
		_report(army, "撤退军令", army["name"] + "已收到撤退命令。", false)
	store._save()
	store.campaign_changed.emit()
	return {"ok": true, "message": "撤退军令已下达，各角色按自身判断执行。" if withdraw else "军令已更新。"}


func resolve_request(army_id: String, approve: bool) -> Dictionary:
	if campaign_finished(): return {"ok": false, "message": "战役已经结束"}
	if store.busy: return {"ok": false, "message": "日期正在推进，请稍候。"}
	var army: Dictionary = state["armies"].get(army_id, {})
	var request: Dictionary = army.get("pending_request", {})
	if army.is_empty() or request.is_empty(): return {"ok": false, "message": "没有待批复的请示。"}
	if str(army.get("faction", "")) != str(state["player_faction"]): return {"ok": false, "message": "只能批复本方请示。"}
	var officer: Dictionary = roster.officers.get(str(army["officer_id"]), {})
	army.erase("pending_request")
	if approve:
		var action: Dictionary = request.get("action", {}).duplicate(true)
		var reason: String = str(request.get("reason", "临机行动"))
		army["trust"] = minf(0.5, float(army.get("trust", 0.0)) + 0.1)
		_report(army, "违令批准", "主公批准%s执行建议：%s。" % [army["name"], reason], true)
		# 批准即执行。只写 approved_action 会绕过 _execute 的副作用（march 不写
		# location.from/to/edge、scout 不更新 scouted_at、resupply 不转粮、
		# request_support 不发报），而次日 step 把 last_decision 置为当日又让
		# validate_decision 的两次校验全部过期，部队原地冻结且不入复盘记录。
		_execute(army, action)
		if str(army.get("status", "active")) != "ended":
			army["last_reason"] = "主公批准违令：" + reason
			# 只记当日，不预写次日；否则明日两次校验都会被判为已执行。
			army["last_decision"] = int(state["tick"])
			army["decision_key"] = ""
			_record_approved(army, request, action)
	else:
		if float(officer.get("personality", {}).get("自尊", 50)) >= 65.0: army["resentment"] = minf(0.5, float(army.get("resentment", 0.0)) + 0.1)
		_report(army, "违令驳回", "主公驳回%s的违令请示，按原军令执行。" % army["name"], false)
	store._save()
	store.campaign_changed.emit()
	return {"ok": true, "approved": approve}


# 主公批准的违令也要进入复盘记录，否则决策历史里查不到这天为什么反常。
func _record_approved(army: Dictionary, request: Dictionary, action: Dictionary) -> void:
	var summary := "主公批准违令：" + str(request.get("reason", "临机行动"))
	var record: Dictionary = {"request_id": "approved:%s:%d" % [str(army["id"]), int(state["tick"])], "tick": int(state["tick"]), "army_id": army["id"], "candidate_id": str(request.get("candidate_id", "")), "action": action.duplicate(true), "reason_summary": summary, "source": "player_approval", "model": "", "rules_version": rules["version"], "prompt_version": 5, "policy_version": Policy.version(), "weights_version": Policy.weights().get("version", 0), "score_breakdown": {}, "vetoed": false, "fallback_reason": "", "observation": context_for(army).duplicate(true)}
	state["decisions"].append(record)
	while state["decisions"].size() > 160: state["decisions"].pop_front()
	if not army.has("decision_history"): army["decision_history"] = []
	army["decision_history"].append(record)


func _expire_requests() -> void:
	for army in state["armies"].values():
		var request: Dictionary = army.get("pending_request", {})
		if request.is_empty(): continue
		if int(request.get("tick", 0)) >= int(state["tick"]): continue
		army.erase("pending_request")
		_report(army, "请示超时", "%s的违令请示未获批复，按原军令执行。" % army["name"], false)


func _evaluate_dissent(army: Dictionary, context: Dictionary, record: Dictionary) -> void:
	if army.get("returning", false) or str(army["status"]) == "ended": return
	if army.has("pending_request"): return
	var ranked_free: Array = Policy.rank(context, false)
	if ranked_free.is_empty(): return
	var ordered_top := str(Policy.choose(context).get("candidate_id", ""))
	var best_free: Dictionary = ranked_free[0]
	if str(best_free["candidate"]["id"]) == ordered_top: return
	var params: Dictionary = rules.get("orders", {}).get("dissent", {})
	var ordered_score := 0.0
	for entry in ranked_free:
		if str(entry["candidate"]["id"]) == ordered_top: ordered_score = float(entry["score"])
	var gap := float(best_free["score"]) - ordered_score
	if gap <= float(params.get("gap", 12)): return
	var officer: Dictionary = roster.officers.get(str(army["officer_id"]), {})
	var relation_name := "中立"
	var corps: Dictionary = state["corps"].get(army.get("corps_id", ""), {})
	if not corps.is_empty():
		relation_name = Dissent.relation(officer, roster.officers.get(str(corps.get("commander_id", "")), {}))
	var orders: Dictionary = orders_for(army)
	var contact: Dictionary = army.get("tactical", {}).get("contact", {})
	var urgent := Dissent.urgent(army, contact, supply_enabled())
	var probability := clampf(Dissent.probability(army, officer.get("personality", {}), orders, relation_name, urgent, float(army.get("counter_intel_dissent", 0.0)), params) + Conduct.dissent_shift(officer), 0.0, float(params.get("max", 0.6)))
	var roll := Dissent.roll("%s:%d:%s:dissent" % [str(state.get("dissent_seed", 0)), army["id"], int(state["tick"])], state)
	var entry: Dictionary = {"tick": state["tick"], "army_id": army["id"], "probability": probability, "gap": gap, "ordered": ordered_top, "suggested": best_free["candidate"]["id"], "roll": roll, "relation": relation_name, "urgent": urgent}
	if roll >= probability:
		entry["result"] = "服从"
		_append_dissent(army, entry)
		record["dissent"] = entry
		return
	var extreme := float(officer.get("personality", {}).get("自尊", 50)) >= 85.0 and float(officer.get("personality", {}).get("风险承受", 50)) >= 85.0
	if bool(params.get("direct", false)) and extreme:
		entry["result"] = "直接违令"
		_execute(army, best_free["candidate"]["action"].duplicate(true))
		army["last_reason"] = "违令：" + str(best_free["candidate"].get("description", "临机行动"))
		_report(army, "违令", "%s拒绝遵从军令，擅自%s。" % [army["name"], str(best_free["candidate"].get("description", "临机行动"))], true)
		_append_dissent(army, entry)
		record["dissent"] = entry
		return
	if str(army["faction"]) != str(state["player_faction"]):
		var lord := Strategic.lord_of(roster, str(army["faction"]))
		var permit := urgent or float(lord.get("personality", {}).get("风险承受", 50)) >= 45.0
		entry["result"] = "主公批准" if permit else "主公驳回"
		if permit:
			_execute(army, best_free["candidate"]["action"].duplicate(true))
			army["last_reason"] = "主公批准临机调整：" + str(best_free["candidate"].get("description", ""))
		_append_dissent(army, entry)
		record["dissent"] = entry
		return
	entry["result"] = "建议违令"
	army["pending_request"] = {"tick": state["tick"], "army_id": army["id"], "officer_id": army["officer_id"], "officer": army["name"], "candidate_id": best_free["candidate"]["id"], "action": best_free["candidate"]["action"].duplicate(true), "reason": str(best_free["candidate"].get("description", "临机行动")), "probability": probability, "gap": gap}
	_report(army, "违令请示", "%s请求违令：建议%s（把握%.0f%%），等待主公批复。" % [army["name"], str(best_free["candidate"].get("description", "临机行动")), probability * 100.0], true)
	_append_dissent(army, entry)
	record["dissent"] = entry


func _append_dissent(army: Dictionary, entry: Dictionary) -> void:
	if not army.has("dissent_history"): army["dissent_history"] = []
	army["dissent_history"].append(entry)
	while army["dissent_history"].size() > 12: army["dissent_history"].pop_front()


func available_officers(faction: String) -> Array:
	var result: Array = []
	var deployed: Array = active_armies().map(func(army): return army["officer_id"])
	for officer in roster.officers.values():
		if str(officer["faction"]) == faction and not deployed.has(officer["id"]) and not Fate.unavailable(self, str(officer["id"])) and not str(officer["id"]).begins_with("militia:") and str(state["officer_states"].get(officer["id"], {}).get("status", "available")) == "available":
			result.append(officer)
	result.sort_custom(func(a, b): return str(a["name"]) < str(b["name"]))
	return result


func set_player_faction(faction: String) -> bool:
	if store.busy or state.get("campaign_started", false) or not active_armies(str(state["player_faction"])).is_empty() or not store.scenario.get("factions", {}).has(faction):
		return false
	var previous := str(state["player_faction"])
	state["faction_action_points"][previous] = store.action_points
	store.action_points = int(state["faction_action_points"].get(faction, 3))
	state["player_faction"] = faction
	store._save()
	return true


func _sync_inventory(city: Dictionary) -> void:
	if not city.get("wounded_units") is Dictionary: city["wounded_units"] = {"infantry": int(city.get("wounded", 0)), "archers": 0, "cavalry": 0}
	var wounded_count := 0
	for type in Combat.TYPES:
		city["wounded_units"][type] = maxi(0, int(city["wounded_units"].get(type, 0)))
		wounded_count += int(city["wounded_units"][type])
	if wounded_count < int(city.get("wounded", 0)): city["wounded_units"]["infantry"] += int(city["wounded"]) - wounded_count
	var total: int = int(city.get("garrison", 0))
	if not city.get("units", null) is Dictionary:
		city["units"] = {"infantry": total, "archers": 0, "cavalry": 0}
	var counted: int = 0
	for type in Combat.TYPES:
		city["units"][type] = maxi(0, int(city["units"].get(type, 0)))
		counted += int(city["units"][type])
	if counted < total:
		city["units"]["infantry"] += total - counted
	elif counted > total:
		var excess: int = counted - total
		for type in Combat.TYPES:
			var loss: int = mini(excess, int(city["units"][type]))
			city["units"][type] -= loss
			excess -= loss


func recruit_units(city: Dictionary, count: int) -> void:
	_sync_inventory(city)
	# The city's garrison has already increased; replace part of the new infantry.
	var archers: int = int(count * 0.2) if int(city.get("training", 0)) >= 50 else 0
	var cavalry: int = int(count * 0.1) if int(city.get("equipment", 0)) >= 70 else 0
	city["units"]["infantry"] -= archers + cavalry
	city["units"]["archers"] += archers
	city["units"]["cavalry"] += cavalry


func preview_dispatch(home: String, target: String, officer_id: String, defending: bool = false, troop_count: int = 0) -> Dictionary:
	if campaign_finished(): return {"ok": false, "message": "战役已经结束，请开始新的战役"}
	var city: Dictionary = store.city_state(home)
	var officer: Dictionary = roster.officers.get(officer_id, {})
	var failure: Dictionary = {"ok": false, "message": "请选择可用的主将与本方出发城。"}
	if city.is_empty() or officer.is_empty() or not city.has("garrison") or not graph.places.has(target):
		return failure
	if str(city.get("faction", "")) != str(officer.get("faction", "")):
		return failure
	if not defending and str(store.city_state(target).get("faction", "")) != str(city["faction"]) and not hostile(str(city["faction"]), str(store.city_state(target).get("faction", ""))):
		return {"ok": false, "message": "双方处于互不交战关系，不能进攻"}
	if str(state["officer_states"].get(officer_id, {}).get("status", "available")) != "available" or active_armies().any(func(army): return army["officer_id"] == officer_id) or Fate.unavailable(self, officer_id):
		return {"ok": false, "message": "这位将领已经在执行任务。"}
	var path: Dictionary = route(str(city["faction"]), home, target)
	if not bool(path["found"]):
		return {"ok": false, "message": "目标没有可用通路。"}
	if Operations.assembly_days(self, home, [officer_id]) < 0: return {"ok": false, "message": "主将无法从驻地到达出发城"}
	var garrison: int = int(city.get("garrison", 0))
	var reserve: int = maxi(int(rules["minimum_reserve"]), int(ceil(garrison * float(rules["reserve_ratio"]))))
	var count: int = mini(garrison - reserve, int(garrison * float(rules["mobilization_ratio"])))
	var food_per_day: float = float(rules["grain_per_soldier_day"])
	var reserve_food: int = int(ceil(reserve * food_per_day * 10))
	var food_available: int = maxi(0, int(city.get("grain", 0)) - reserve_food)
	if supply_enabled(): count = mini(count, int(food_available / (food_per_day * 12.0)))
	if count < int(rules["minimum_army"]):
		return {"ok": false, "message": "兵力不足，需保留至少 %d 名守军。" % reserve}
	var maximum: int = count
	if troop_count > 0:
		if troop_count < int(rules["minimum_army"]) or troop_count > maximum: return {"ok": false, "message": "所选兵力超出可动员范围。"}
		count = troop_count
	var food: int = mini(food_available, int(ceil(count * food_per_day * float(rules["carry_days"])) )) if supply_enabled() else 0
	return {"ok": true, "message": "", "home": home, "target": target, "officer_id": officer_id, "strength": count, "maximum": maximum, "grain": food, "grain_days": int(food / maxf(count * food_per_day, 1)) if supply_enabled() else 999, "reserve": garrison - count, "travel_days": int(ceil(float(path["cost"]) * float(rules["route_days_per_cost"]))), "mission_type": "defend" if defending or str(store.city_state(target).get("faction", "")) == str(city["faction"]) else "capture"}


func dispatch(home: String, target: String, officer_id: String, companions: Array = [], as_corps: bool = false, troop_count: int = 0) -> Dictionary:
	companions = companions.filter(func(id): return id != officer_id)
	if store.busy:
		return {"ok": false, "message": "日期正在推进，请稍候。"}
	if str(store.city_state(home).get("faction", "")) != str(state["player_faction"]):
		return {"ok": false, "message": "只能派遣本方城池的军队。"}
	var preview: Dictionary = preview_dispatch(home, target, officer_id, false, troop_count)
	if not bool(preview["ok"]):
		return preview
	for id in companions:
		if id == officer_id or not available_officers(str(state["player_faction"])).any(func(officer): return officer["id"] == id): return {"ok": false, "message": "随军人员包含不可用武将"}
	if Operations.assembly_days(self, home, companions) < 0: return {"ok": false, "message": "随军人员没有可用的调任通路"}
	companions = Corps.select_members(self, officer_id, companions, home)
	var custom_plan: Dictionary = state.get("pending_corps_plan", {})
	if not custom_plan.is_empty():
		var validation: Dictionary = Corps.validate_plan(self, officer_id, companions, custom_plan, int(preview["strength"]))
		if not validation.get("ok", false): return validation
	var army: Dictionary = _mobilize(preview)
	if as_corps or not companions.is_empty():
		Corps.form(self, army, companions)
		if store.persist_enabled and store.agent.enabled and store.agent.has_method("supports_background_decisions"): Corps.plan_background(self, store.agent)
	_observe_all()
	_report(army, "出征", "%s奉命从%s出发，带兵%d，目标%s。" % [army["name"], graph.name_of(home), int(preview["strength"]), graph.name_of(target)], false)
	store._save()
	store.city_changed.emit(home)
	return {"ok": true, "army_id": army["id"], "message": "军队已出发，行军与作战由主将自主决定。"}


func _mobilize(preview: Dictionary) -> Dictionary:
	var city: Dictionary = store.city_state(str(preview["home"]))
	_sync_inventory(city)
	var count: int = int(preview["strength"])
	var before: int = int(city["garrison"])
	var units: Dictionary = {"infantry": 0, "archers": 0, "cavalry": 0}
	var remaining: int = count
	for index in range(Combat.TYPES.size()):
		var type: String = Combat.TYPES[index]
		var take: int = mini(int(city["units"][type]), remaining if index == Combat.TYPES.size() - 1 else int(ceil(float(count) * int(city["units"][type]) / maxf(before, 1))))
		take = mini(take, remaining)
		units[type] = take
		city["units"][type] -= take
		remaining -= take
	# Rounding cannot discard unallocated soldiers.
	for type in Combat.TYPES:
		var take: int = mini(remaining, int(city["units"][type]))
		units[type] += take
		city["units"][type] -= take
		remaining -= take
	city["garrison"] = before - count
	if supply_enabled(): city["grain"] -= int(preview["grain"])
	var id: String = "army-%04d" % int(state["next_id"])
	state["next_id"] += 1
	var officer: Dictionary = roster.officers[str(preview["officer_id"])]
	var army: Dictionary = {"id": id, "officer_id": officer["id"], "name": officer["name"], "faction": city["faction"], "home": preview["home"], "target": preview["target"], "mission_type": preview["mission_type"], "status": "active", "location": {"node": preview["home"], "edge": "", "progress": 0.0}, "units": units, "initial_strength": count, "dead": 0, "wounded": 0, "captured": 0, "deposited": 0, "training": int(city.get("training", 50)), "equipment": int(city.get("equipment", 50)), "skills": officer["skills"].duplicate(true), "trait_ids": officer.get("trait_ids", []).duplicate(), "grain": float(preview["grain"]) if supply_enabled() else 0.0, "morale": 100.0, "organization": 100.0, "fatigue": 0.0, "started": int(state["tick"]), "deadline": int(state["tick"]) + int(rules["mission_days"]), "intel": {"cities": {}, "enemies": {}}, "action": {"type": "hold"}, "last_decision": -10, "last_report": {}, "last_reason": "正在准备出征。", "returning": false, "scouted_at": -10, "siege_progress": 0.0, "outcome": "", "last_support": -10, "trust": 0.0, "resentment": 0.0, "memory": [], "experience": {"enemy_notes": {}, "battle_log": [], "streak": {"wins": 0, "losses": 0}, "drift": {}}}
	var last_victory := int(state["battle_victories"].get(str(officer["id"]), -100000))
	army["victory_chain"] = not Traits.mechanism(army, "victory_chain").is_empty() and preview["mission_type"] == "capture" and int(state["tick"]) - last_victory <= int(Traits.mechanism(army, "victory_chain").get("window_days", 0))
	army["departure_at"] = int(state["tick"]) + Operations.assembly_days(self, str(preview["home"]), [officer["id"]])
	army["deadline"] += maxi(0, int(army["departure_at"]) - int(state["tick"]))
	Operations.detach_post(self, str(officer["id"]))
	army["edge"] = Edges.ensure(army, officer, true)
	state["armies"][id] = army
	state["missions"][id] = {"army_id": id, "home": preview["home"], "target": preview["target"], "status": "active", "type": preview["mission_type"], "result": ""}
	state["officer_states"][officer["id"]] = {"status": "commanding", "army_id": id}
	return army


func step(adapter: Node = null) -> void:
	var feedback_before := Feedback.snapshot(self)
	urgent_event = false
	state["tick"] += 1
	state["battle_round"] = int(state.get("battle_round",state["tick"]-1)) + 1
	planner.begin_round(int(state["battle_round"]))
	_expire_requests()
	Fate.restore(self)
	Tactical.clear_target_cache()
	Edges.day_start(self)
	var epoch: int = generation
	_deliver_reports()
	Lifecycle.maintain(self)
	Operations.residence(self)
	if not state.has("battlefield"): _spawn_defenders()
	Strategic.plan(self, store)
	Battlefields.prepare(self)
	_observe_all()
	if rules.get("battle_ai",{}).get("mode","active") == "active":
		UnitBrain.communicate(self)
		OfficerBrain.deliberate(self,adapter)
	if not state["corps"].is_empty():
		await Corps.plan(self, adapter)
		if generation != epoch: return
	Fate.restore(self)
	_update_operations()
	var ai_mode := str(rules.get("battle_ai",{}).get("mode","active"))
	if ai_mode in ["active","shadow"]: UnitBrain.decide(self,adapter,ai_mode == "shadow")
	var contexts: Array = []
	for army in active_armies():
		if str(army.get("autonomy", {}).get("stance", "obey")) != "obey" and int(army.get("autonomy", {}).get("until", 0)) > int(state["tick"]): continue
		if uses_unit_brain(army): continue
		if not ready(army): army["last_reason"] = "等待主将与随军人员到齐，第%d日出发" % int(army["departure_at"]); continue
		if army.has("corps_id"): continue
		if bool(army["returning"]):
			# A retreat route is authoritative; the agent must not turn back or stop it.
			army["action"] = {"type": "continue"}
			if str(army["location"].get("edge", "")) == "":
				_start_return(army)
			continue
		if bool(army.get("objective_complete", false)) and orders_for(army)["after_battle"] == "hold":
			army["action"] = {"type": "hold"}
			continue
		if Combat.strength(army) > 0:
			var context: Dictionary = context_for(army)
			var key: String = _decision_key(context)
			if _should_reconsider(army, context, adapter, key):
				# decision_key 只在决策真正落地时写入（见下方提交段）。提前写入会让
				# 被丢弃的请求连续数日不再重判，部队连续数日只吃本地策略。
				context["decision_key"] = key
				contexts.append(context)
	var outputs: Dictionary = {}
	if adapter != null and adapter.has_method("supports_background_decisions"):
		var requests: Array = []
		var signatures := {}
		for context in contexts:
			var key: String = "army:" + str(context["army_id"])
			var signature: String = _decision_key(context) + str(adapter.model) + str(adapter.endpoint)
			var proposal: Dictionary = planner.take(key, signature, int(state["tick"]))
			outputs[str(context["request_id"])] = proposal["result"] if not proposal.is_empty() else Policy.choose(context)
			if str(context["officer"]["id"]).begins_with("militia:") or planner.has_pending(key): continue
			requests.append(context)
			signatures[key] = signature
		# 批次槽位被军团占住时 submit 会排队而不是丢弃；此处只兜住真正的失败。
		if not planner.submit(requests, adapter, signatures):
			adapter.metrics["dropped_batches"] = int(adapter.metrics.get("dropped_batches", 0)) + 1
	elif adapter != null and not contexts.is_empty():
		outputs = await adapter.choose_batch(contexts)
	elif adapter == null:
		for context in contexts:
			outputs[str(context["request_id"])] = Policy.choose(context)
	if generation != epoch:
		return
	# Every decision observes the same day-start state; only now commit actions.
	for context in contexts:
		var army: Dictionary = state["armies"].get(context["army_id"], {})
		var result: Dictionary = outputs.get(str(context["request_id"]), {})
		var validated: Dictionary = validate_decision(context, result)
		if not bool(validated.get("ok", false)):
			result = Policy.choose(context)
			result["fallback_reason"] = str(validated.get("message", "模型未返回结果"))
			validated = validate_decision(context, result)
			if adapter != null:
				adapter.metrics["fallbacks"] += 1
				adapter.last_status = "模型行动未通过校验  本地策略接管"
		if bool(validated.get("ok", false)):
			if str(army.get("status", "active")) == "ended": continue
			var previous_action: Dictionary = army["action"].duplicate(true)
			_execute(army, validated["action"])
			army["last_reason"] = str(result.get("reason_summary", "")).left(160)
			if previous_action != army["action"]: army["operation"]["change_reason"] = army["last_reason"]
			army["operation"]["plan_until"] = int(state["tick"]) + 3
			army["last_decision"] = int(state["tick"])
			# 请求真正落地后才登记 decision_key；否则未发出的请求会被当成已决策。
			army["decision_key"] = str(context.get("decision_key", army.get("decision_key", "")))
			army["decision_role"] = str(army["operation"].get("role", ""))
			army["decision_flanked"] = bool(context["army"].get("contact", {}).get("flanked", false))
			var record: Dictionary = {"request_id": context["request_id"], "tick": state["tick"], "army_id": army["id"], "candidate_id": result.get("candidate_id", ""), "action": validated["action"].duplicate(true), "reason_summary": army["last_reason"], "source": result.get("source", "baseline"), "model": str(adapter.model) if adapter != null else "", "rules_version": rules["version"], "prompt_version": 5, "policy_version": Policy.version(), "weights_version": Policy.weights().get("version", 0), "score_breakdown": result.get("score_breakdown", {}), "vetoed": bool(result.get("vetoed", false)), "fallback_reason": result.get("fallback_reason", ""), "observation": context.duplicate(true)}
			state["decisions"].append(record)
			if not army.has("decision_history"): army["decision_history"] = []
			army["decision_history"].append(record)
			_evaluate_dissent(army, context, record)
	while state["decisions"].size() > 160:
		state["decisions"].pop_front()
	# Immediate self-defence must run after proposals, so a routine hold decision
	# cannot overwrite the response to the previous day's arrow fire.
	if state.has("battlefield") and ai_mode != "active":
		for corps in state["corps"].values(): preload("res://scripts/war/battle/ranged_pressure.gd").respond(self, corps)
	var motions: Dictionary = _move_all()
	_resolve_contacts(motions)
	if not state["corps"].is_empty(): Corps.logistics(self)
	Fortifications.fire(self)
	_resolve_sieges()
	for army in state["armies"].values():
		if army.has("battlefield_id"): army["last_battlefield_id"] = army["battlefield_id"]
	if not store.battle_test: Battlefields.cleanup(self)
	Lifecycle.maintain(self)
	_upkeep()
	if ai_mode == "active":
		for army in active_armies(): TacticalPlan.after_round(self,army)
		for army in active_armies(): Experience.tactical_result(self,army)
	_observe_all()
	_deliver_reports()
	Experience.decay(self)
	Operations.result(self)
	preload("res://scripts/war/battle/battle_objectives.gd").update(self)
	Feedback.record_day(self, feedback_before)
	ReportPolicy.observe(self)
	_summarize_finished_battles()
	_deliver_reports()
	state["rng_state"] = str(rng.state)
	state["dissent_state"] = int(state.get("dissent_state", 0))

func uses_unit_brain(army: Dictionary) -> bool:
	return army.has("tactical") and str(rules.get("battle_ai",{}).get("mode","active")) == "active"

func set_battle_ai_mode(mode: String) -> bool:
	if mode not in ["legacy","shadow","active"]: return false
	planner.clear()
	rules["battle_ai"] = rules.get("battle_ai",{})
	rules["battle_ai"]["mode"] = mode
	if mode != "active":
		for army in active_armies():
			if army.get("action",{}).get("tactical_contract",false): army["action"] = {"type":"hold"}
	return true


func _should_reconsider(army: Dictionary, context: Dictionary, adapter, key: String) -> bool:
	var age := int(state["tick"]) - int(army["last_decision"])
	if adapter != null and adapter.has_method("is_ollama") and adapter.is_ollama() and age < 3:
		var own: Dictionary = context["army"]
		var role: String = str(context.get("operation", {}).get("role", ""))
		var urgent: bool = float(own["morale"]) < 30 or float(own["organization"]) < 25 or float(own["grain_days"]) < 4 or int(own.get("blocked_days", 0)) >= 2
		urgent = urgent or role != str(army.get("decision_role", role)) or bool(own.get("contact", {}).get("flanked", false)) and not bool(army.get("decision_flanked", false))
		urgent = urgent or float(context.get("battlefield", {}).get("enemy_to_friendly_ratio", 0)) >= 2.0
		var valid_plan := false
		for candidate in context["candidates"]:
			if candidate["action"] == army["action"]: valid_plan = true
		if not urgent and valid_plan: return false
	return key != str(army.get("decision_key", "")) or age >= 3

func _decision_key(context: Dictionary) -> String:
	var own: Dictionary = context["army"]
	var location: Dictionary = own["location"]
	var enemies: Array = []
	for enemy in context["enemies"]:
		var proximity := -1
		if own.has("cell") and int(enemy.get("tactical_cell", -1)) >= 0:
			var separation := Tactical.cell_distance(int(own["cell"]), int(enemy["tactical_cell"]))
			proximity = 0 if separation <= 1 else 1 if separation <= 3 else 2
		enemies.append([enemy["id"], int(enemy["strength_estimate"]) / 500, enemy["location"].get("node", ""), enemy["routing"], proximity])
	var allies: Array = []
	for friend in context.get("allies", []):
		allies.append([friend["id"], int(friend["strength"]) / 500, friend["can_support"], friend["returning"], friend.get("role", ""), friend["last_action"].get("type", "")])
	var operation: Dictionary = context.get("operation", {})
	var task := [operation.get("role", ""), operation.get("commander", ""), operation.get("support_id", ""), operation.get("suggested_target", "")]
	var actions: Array = []
	for candidate in context["candidates"]: actions.append(candidate["id"])
	var pressure := int(float(context.get("battlefield", {}).get("enemy_to_friendly_ratio", 0)) * 4)
	return JSON.stringify([location.get("node", ""), location.get("edge", ""), context["returning"], context["target_known"], int(float(own["grain_days"]) / 4), int(float(own["morale"]) / 15), int(float(own["organization"]) / 15), enemies, allies, pressure, task, own.get("contact", {}).get("adjacent_enemies", 0), int(own.get("blocked_days", 0)) >= 2, actions])


func _spawn_defenders() -> void:
	var approaching: Array = active_armies()
	for attacker in approaching:
		if bool(attacker.get("returning", false)) or str(attacker["mission_type"]) != "capture":
			continue
		var target: String = str(attacker["target"])
		var city: Dictionary = store.city_state(target)
		var faction: String = str(city.get("faction", ""))
		if faction == "" or not hostile(faction, str(attacker["faction"])) or not city.has("population"):
			continue
		var policy: Dictionary = Operations.policy(self, target)
		if policy["defense"] == "hold": continue
		if policy["defense"] == "adaptive" and int(city["garrison"]) < Combat.strength(attacker) * 0.7: continue
		var visible: Array = graph.visible_nodes(target)
		var location: Dictionary = attacker["location"]
		if not visible.has(location["node"]) and not visible.has(location.get("to", "")):
			continue
		var exists: bool = false
		for defender in active_armies(faction):
			if str(defender["home"]) == target:
				exists = true
		if exists or int(state["defense_cooldowns"].get(target, -100)) + 20 > int(state["tick"]):
			continue
		var officers: Array = available_officers(faction)
		var officer_id: String = str(officers[0]["id"]) if not officers.is_empty() else roster.militia(faction, target)
		if Fate.unavailable(self, officer_id): officer_id = roster.militia(faction, target + ":" + str(state["tick"]))
		var preview: Dictionary = preview_dispatch(target, target, officer_id, true)
		if bool(preview["ok"]):
			_mobilize(preview)
			state["defense_cooldowns"][target] = int(state["tick"])
			store.city_changed.emit(target)


func city_intel(node: String) -> Dictionary:
	var city: Dictionary = store.city_state(node)
	if city.is_empty(): return {}
	var result := city.duplicate(true)
	result["node"] = node
	result["strength_estimate"] = int(city.get("garrison", 0))
	result["uncertainty"] = 0
	result["observed_at"] = int(state["tick"])
	result["source"] = "live_state"
	return result


func enemy_intel(enemy: Dictionary) -> Dictionary:
	var result := {"id": enemy["id"], "location": enemy["location"].duplicate(true), "strength_estimate": Combat.strength(enemy), "observed_at": int(state["tick"]), "uncertainty": 0, "routing": bool(enemy.get("returning", false)), "fighting": int(enemy.get("combat_tick", -1)) == int(state["tick"]), "unit_mix_estimate": enemy["units"].duplicate(true), "source": "live_state"}
	if enemy.has("tactical"): result["tactical_cell"] = int(enemy["tactical"]["cell"])
	return result


func _observe_all() -> void:
	Tactical.clear_target_cache()
	var cities := {}
	for node in store.scenario.get("places", {}):
		cities[node] = city_intel(str(node))
	var armies := active_armies()
	for army in armies:
		# Keep the intelligence schema for saves and decision snapshots, with no sight limits.
		army["intel"] = {"cities": cities.duplicate(true), "enemies": {}}
		for enemy in armies:
			if hostile(str(enemy["faction"]), str(army["faction"])):
				army["intel"]["enemies"][enemy["id"]] = enemy_intel(enemy)
	ReportPolicy.observe(self)


func _update_operations() -> void:
	if not state["corps"].is_empty(): Corps.update(self)
	var assigned := {}
	for anchor in active_armies():
		if anchor.has("corps_id"): continue
		if assigned.has(anchor["id"]): continue
		var group: Array = []
		for friend in active_armies(str(anchor["faction"])):
			if not friend.has("corps_id") and not assigned.has(friend["id"]) and _near_battle(anchor["location"], friend["location"]): group.append(friend)
		group.sort_custom(func(a, b):
			var left := int(a["skills"].get("带兵",50))+int(a["skills"].get("治军",50))-(10000 if a["returning"] else 0)
			var right := int(b["skills"].get("带兵",50))+int(b["skills"].get("治军",50))-(10000 if b["returning"] else 0)
			return left > right if left != right else str(a["id"]) < str(b["id"]))
		if group.is_empty(): continue
		var covered_retreats := {}
		for index in range(group.size()):
			var army: Dictionary = group[index]
			assigned[army["id"]] = true
			var operation: Dictionary = army.get("operation", {})
			var previous_role: String = str(operation.get("role", ""))
			var role := "main_attack" if index < 2 else "flank" if index == 2 else "support" if index < group.size() - 1 else "reserve"
			if army.has("tactical"): role = army["tactical"]["role"]
			var fleeing: Array = group.filter(func(friend): return bool(friend["returning"]))
			var covered_friend := ""
			if role in ["reserve", "support"] and not fleeing.is_empty() and not bool(army["returning"]):
				if army.has("tactical"):
					fleeing.sort_custom(func(a, b): return Tactical.distance(army, a) < Tactical.distance(army, b))
					for friend in fleeing:
						if not covered_retreats.has(friend["id"]) and Tactical.distance(army, friend) <= 3:
							covered_friend = friend["id"]
							covered_retreats[covered_friend] = true
							role = "rear_guard"
							break
				else:
					role = "rear_guard"
					covered_friend = fleeing[0]["id"]
			if army.get("tactical", {}).get("role", "") == "reserve":
				var frontline: Array = group.filter(func(friend): return friend.get("tactical", {}).get("role", "") == "main_attack" and not friend["returning"])
				if frontline.size() < 2: role = "main_attack"
			operation["role"] = "withdraw" if bool(army["returning"]) else role
			operation["role_label"] = Tactical.ROLES.get(operation["role"], "自主行动")
			operation["commander"] = group[0]["id"]
			operation["support_id"] = group[0]["id"] if index > 0 else ""
			if army.has("tactical") and role == "support": operation["support_id"] = army["tactical"]["support_id"]
			if role == "rear_guard": operation["support_id"] = covered_friend
			operation["objective"] = graph.name_of(str(army["target"]))
			# JSON saves reorder dictionary keys. Target assignment must depend on
			# current sightings and explicit tie-breaks, never their insertion order.
			var enemies: Array = army["intel"]["enemies"].values().filter(func(sight): return int(sight.get("observed_at",-1)) == int(state["tick"]))
			enemies.sort_custom(func(a,b): return str(a["id"]) < str(b["id"]))
			if army.has("tactical"):
				enemies.sort_custom(func(a, b):
					var left := Tactical.cell_distance(int(army["tactical"]["cell"]),int(a.get("tactical_cell",-1))) if int(a.get("tactical_cell",-1)) >= 0 else 10000
					var right := Tactical.cell_distance(int(army["tactical"]["cell"]),int(b.get("tactical_cell",-1))) if int(b.get("tactical_cell",-1)) >= 0 else 10000
					return left < right if left != right else str(a["id"]) < str(b["id"]))
				var previous_target: String = str(operation.get("suggested_target", ""))
				if not enemies.any(func(sight): return sight["id"] == previous_target): operation["suggested_target"] = enemies[0]["id"] if not enemies.is_empty() else ""
			else: operation["suggested_target"] = enemies[index % enemies.size()]["id"] if not enemies.is_empty() else ""
			operation["plan_until"] = operation.get("plan_until", 0)
			operation["change_reason"] = operation.get("change_reason", "主帅按部队能力安排作战职责")
			if previous_role != "" and previous_role != operation["role"]:
				operation["change_reason"] = "战线发生变化，职责调整为" + operation["role_label"]
				operation["plan_until"] = 0
			army["operation"] = operation

func _near_battle(a: Dictionary, b: Dictionary) -> bool:
	var edge_a := str(a.get("edge", ""))
	var edge_b := str(b.get("edge", ""))
	if edge_a != "" and edge_a == edge_b:
		return absf(_edge_coordinate(a) - _edge_coordinate(b)) <= 0.3
	if edge_a == "" and edge_b == "": return a["node"] == b["node"]
	if edge_a == "": return _near_battle(b, a)
	if edge_b != "": return false
	return (b["node"] == a.get("from", "") and float(a.get("progress", 0)) <= 0.3) or (b["node"] == a.get("to", "") and float(a.get("progress", 0)) >= 0.7)

func _support_context(army: Dictionary) -> Dictionary:
	var allies: Array = []
	var ready := Combat.strength(army)
	var nearby: Array = graph.visible_nodes(str(army["location"]["node"]), 1)
	for friend in active_armies(str(army["faction"])):
		if friend["id"] == army["id"]: continue
		var local := _near_battle(army["location"], friend["location"])
		if army.has("tactical") and friend.has("tactical"): local = Tactical.distance(army, friend) <= 5
		if not local and not nearby.has(friend["location"]["node"]): continue
		var available := not bool(friend["returning"]) and float(friend["morale"]) >= 30 and float(friend["organization"]) >= 25 and (not supply_enabled() or float(friend["grain"]) > 0) and bool(orders_for(friend)["engage"])
		if friend.get("operation", {}).get("role", "") == "reserve" and friend["action"]["type"] == "hold": available = false
		var strength := Combat.strength(friend)
		if local and available: ready += strength
		allies.append({"id": friend["id"], "name": friend["name"], "strength": strength, "location": friend["location"].duplicate(true), "morale": friend["morale"], "organization": friend["organization"], "returning": friend["returning"], "last_action": friend["action"].duplicate(true), "target": graph.name_of(str(friend["target"])), "near_battle": local, "can_support": local and available, "reinforcement_possible": not local and available, "role": friend.get("operation", {}).get("role", ""), "tactical_cell": int(friend.get("tactical", {}).get("cell", -1))})
	var enemy_total := 0
	var uncertainty := 0
	for enemy in army["intel"]["enemies"].values():
		if army.has("tactical") and int(enemy.get("tactical_cell", -1)) >= 0:
			var cell: int = int(army["tactical"]["cell"])
			var enemy_cell: int = int(enemy["tactical_cell"])
			if Tactical.cell_distance(cell, enemy_cell) > 5: continue
		if not bool(enemy.get("routing", false)) and _near_battle(army["location"], enemy["location"]):
			enemy_total += int(enemy["strength_estimate"])
			uncertainty += int(enemy.get("uncertainty", 0))
	return {"allies": allies, "battlefield": {"friendly_ready_strength": ready, "enemy_estimated_strength": enemy_total, "enemy_strength_min": maxi(0, enemy_total - uncertainty), "enemy_strength_max": enemy_total + uncertainty, "enemy_to_friendly_ratio": float(enemy_total) / maxf(ready, 1), "note": "友军计划为上一轮行动；可支援表示邻近且状态允许，不保证本轮行动。远处援军与撤退、低士气、低组织、断粮友军不计入可用兵力。敌军兵力为实时信息。"}}

func _observed_contact(army: Dictionary) -> Dictionary:
	var cell := int(army.get("tactical", {}).get("cell", -1))
	if cell < 0: return {"adjacent_enemies": 0, "engaged_by": [], "flanked": false, "attackers": 0, "required_preparation": 0}
	var engaged: Array = []
	var adjacent := 0
	var attackers := 0
	var cover := 0
	var flanked := false
	var observed: Dictionary = army.get("intel", {}).get("enemies", {})
	for record in observed.values():
		# Old sightings remain intelligence, but cannot pin a formation in
		# immediate melee after the opponent has left or ceased reporting.
		if int(record.get("observed_at",-100)) < int(state["tick"])-1: continue
		var enemy_cell := int(record.get("tactical_cell", -1))
		if enemy_cell >= 0 and enemy_cell == cell: continue
		if enemy_cell < 0: continue
		var separation := Tactical.cell_distance(cell, enemy_cell)
		if separation <= 1: adjacent += 1
		if separation <= 1 and not bool(record.get("routing", false)):
			engaged.append(str(record.get("id", "")))
			attackers += 1
		if separation <= 2 and not bool(record.get("routing", false)): flanked = true
	# Observed friendly rear guards count as cover, matching contact_state's intent.
	for other in active_armies(str(army["faction"])):
		if other["id"] == army["id"] or not other.has("tactical"): continue
		if bool(other["returning"]) or str(other.get("operation", {}).get("role", "")) != "rear_guard": continue
		if Tactical.cell_distance(cell, int(other["tactical"]["cell"])) <= 1: cover += 1
	# context_for hands required_preparation to the forecast for withdraw candidates, so
	# the key has to stay present or disengagement would look free.
	var preparation := maxi(1, 1 + maxi(0, attackers - cover))
	return {"adjacent_enemies": adjacent, "engaged_by": engaged, "flanked": flanked, "attackers": attackers, "covered_by": cover, "required_preparation": preparation}


func context_for(army: Dictionary) -> Dictionary:
	var target: String = str(army["home"] if bool(army["returning"]) else army["target"])
	var location: Dictionary = army["location"]
	var own: Dictionary = {"strength": Combat.strength(army), "initial_strength": int(army.get("initial_strength", 0)), "units": army["units"].duplicate(true), "morale": army["morale"], "organization": army["organization"], "fatigue": army["fatigue"], "grain_days": food_days(army), "location": location.duplicate(true), "training": army["training"], "equipment": army["equipment"]}
	if army.has("tactical"):
		own["cell"] = int(army["tactical"]["cell"])
		own["blocked"] = army["tactical"]["blocked"]
		own["blocked_days"] = int(army["tactical"].get("blocked_days", 0))
		own["phase"] = army["tactical"]["phase"]
		# Observed contact only. contact_state() counts adjacent enemies by true
		# distance, and this drives model-call gating and escape readiness, so
		# feeding it unobserved truth let the harness spend calls on hidden threats.
		own["contact"] = _observed_contact(army)
		own["withdraw_preparation"] = army["tactical"].get("withdraw_preparation", 0)
	var candidates: Array = []
	var support := _support_context(army)
	var operation: Dictionary = army.get("operation", {})
	if army.has("tactical"):
		_add_candidate(candidates, "hold", {"type": "hold"}, "保持战线或预备位置，等待战局变化。")
		var partner: String = str(operation.get("support_id", ""))
		if partner != "" and operation.get("role", "") in ["support", "rear_guard"]:
			var partner_army: Dictionary = state["armies"].get(partner, {})
			var relation_name := Dissent.relation(roster.officers.get(str(army["officer_id"]), {}), roster.officers.get(str(partner_army.get("officer_id", "")), {}))
			_add_candidate(candidates, "support:" + partner, {"type": "support", "ally": partner}, "跟随指定友军提供远程支援。", {"relation": relation_name})
	if str(location.get("edge", "")) != "":
		_add_candidate(candidates, "continue", {"type": "continue"}, "按既定计划继续行军。")
	else:
		_add_candidate(candidates, "hold", {"type": "hold"}, "驻守当前位置，整顿组织并恢复疲劳。")
		var current: String = str(location["node"])
		var current_path: Dictionary = route(str(army["faction"]), current, target)
		for link in graph.neighbors(current):
			var node: String = str(link["node"])
			if node != target and not can_cross(str(army["faction"]), node): continue
			var alternative: Dictionary = route(str(army["faction"]), node, target)
			if not alternative["found"]: continue
			_add_candidate(candidates, "march:" + node, {"type": "march", "target": node, "edge": link["edge"]}, "向%s行军，按局势选择通路。" % graph.name_of(node), {"progress_gain": float(current_path.get("cost", 0)) - float(alternative.get("cost", 999))})
		var city: Dictionary = store.city_state(current)
		if str(city.get("faction", "")) == str(army["faction"]) and int(city.get("grain", 0)) > 0:
			_add_candidate(candidates, "resupply", {"type": "resupply"}, "在友城补充携粮。")
		if current == str(army["target"]) and str(army["mission_type"]) == "capture" and hostile(str(city.get("faction", "")), str(army["faction"])):
			var intel: Dictionary = army["intel"]["cities"].get(current, {})
			_add_candidate(candidates, "besiege", {"type": "besiege"}, "继续围城，寻找攻城机会。", {"defender_ratio": float(intel.get("strength_estimate", 0)) / maxf(Combat.strength(army), 1)})
	for enemy in army["intel"]["enemies"].values():
		var observed: Dictionary = enemy["location"]
		if str(observed.get("node", "")) == str(location["node"]) or str(location.get("edge", "")) != "" and str(observed.get("edge", "")) == str(location["edge"]):
			_add_candidate(candidates, "engage:" + str(enemy["id"]), {"type": "engage", "enemy": enemy["id"]}, "与已发现的敌军交战。")
			if army.has("tactical") and operation.get("role", "") == "flank":
				_add_candidate(candidates, "flank:" + str(enemy["id"]), {"type": "flank", "enemy": enemy["id"]}, "绕向敌军侧翼，通路被阻挡时重新判断。")
			if bool(enemy.get("routing", false)):
				_add_candidate(candidates, "pursue:" + str(enemy["id"]), {"type": "pursue", "enemy": enemy["id"]}, "追击已发现的败退敌军。")
	var orders: Dictionary = orders_for(army)
	candidates = candidates.filter(func(candidate):
		var type: String = candidate["action"]["type"]
		if type in ["engage", "flank", "support"] and not bool(orders["engage"]): return false
		if army.has("tactical") and operation.get("role", "") == "flank" and type == "engage":
			# Use the observed cell, not the authoritative one: an unscouted enemy
			# silently removing the option hides it from the officer and the model alike.
			var seen: Dictionary = army.get("intel", {}).get("enemies", {}).get(str(candidate["action"].get("enemy", "")), {})
			var seen_cell := int(seen.get("tactical_cell", -1))
			var own_cell := int(army["tactical"]["cell"])
			if seen_cell >= 0 and own_cell >= 0 and Tactical.cell_distance(own_cell, seen_cell) > 1: return false
		if army.has("tactical") and operation.get("role", "") == "reserve" and type not in ["hold", "scout", "resupply", "request_support"]: return false
		if army.has("tactical") and operation.get("role", "") == "rear_guard" and type not in ["hold", "support", "resupply", "request_support"]: return false
		return type != "pursue" or bool(orders["pursue"])
	)
	candidates = filter_candidates(candidates, orders)
	if bool(orders["retreat"]):
		_add_candidate(candidates, "withdraw", {"type": "withdraw"}, "保存兵力，撤往安全的本方城池。")
	if int(army["last_support"]) < int(state["tick"]) - 7:
		_add_candidate(candidates, "request_support", {"type": "request_support"}, "等待支援并向后方报告军情。")
	candidates.sort_custom(func(a, b): return str(a["id"]) < str(b["id"]))
	var forecast_terrain: String = Tactical.terrain_class(int(own.get("cell", 0))) if own.has("cell") else _terrain(str(location["node"]))
	candidates = candidates.filter(func(c): return supply_enabled() or c["action"]["type"] != "resupply")
	Forecast.annotate(self, army, candidates, {"terrain": forecast_terrain, "enemies": army["intel"]["enemies"], "required_preparation": int(own.get("contact", {}).get("required_preparation", 0))})
	# Snapshot arrays are sorted so decision records replay identically after a save round-trip.
	var known_cities: Array = army["intel"]["cities"].values().duplicate(true)
	known_cities.sort_custom(func(a, b): return str(a["node"]) < str(b["node"]))
	var known_enemies: Array = army["intel"]["enemies"].values().duplicate(true)
	known_enemies.sort_custom(func(a, b): return str(a["id"]) < str(b["id"]))
	var local_map: Dictionary = Tactical.board_for(self, army).duplicate()
	# Decision snapshots need geometry, not the growing authoritative battle ledger.
	local_map.erase("log")
	local_map.erase("pending_events")
	return {"request_id": "%s:%d" % [army["id"], int(state["tick"])], "army_id": army["id"], "observation_revision": state["tick"], "date": store.date_text(), "officer": roster.officers.get(str(army["officer_id"]), {"id": str(army["officer_id"]), "name": str(army.get("name", "")), "skills": army.get("skills", {}), "personality": {}, "trait_ids": army.get("trait_ids", [])}).duplicate(true), "army": own, "mission_type": army["mission_type"], "objective": graph.name_of(target), "at_objective": str(location["node"]) == target and str(location.get("edge", "")) == "", "supply_enabled": supply_enabled(), "returning": army["returning"], "target_known": army["intel"]["cities"].has(target), "cities": known_cities, "enemies": known_enemies, "allies": support["allies"], "battlefield": support["battlefield"], "operation": operation.duplicate(true), "orders": orders.duplicate(true), "local_map": local_map.duplicate(true), "current_action": army["action"].duplicate(true), "memory": army["memory"].duplicate(true), "experience": Experience.summary(army), "candidates": candidates}


func _add_candidate(list: Array, id: String, action: Dictionary, description: String, extra: Dictionary = {}) -> void:
	var candidate: Dictionary = {"id": id, "action": action, "description": description}
	candidate.merge(extra)
	list.append(candidate)


func validate_decision(context: Dictionary, result: Dictionary) -> Dictionary:
	var army: Dictionary = state["armies"].get(context.get("army_id", ""), {})
	if army.is_empty() or str(army["status"]) == "ended" or int(context.get("observation_revision", -1)) != int(state["tick"]) or int(army["last_decision"]) == int(state["tick"]):
		return {"ok": false, "message": "行动请求过期或已经执行。"}
	var choice: Variant = result.get("candidate_id", null)
	if not choice is String:
		return {"ok": false, "message": "未返回有效选择。"}
	for candidate in context.get("candidates", []):
		if str(candidate["id"]) == choice:
			return {"ok": true, "action": candidate["action"].duplicate(true)}
	return {"ok": false, "message": "选择了授权范围之外的行动。"}


func _execute(army: Dictionary, action: Dictionary) -> void:
	if not supply_enabled() and action.get("type", "") == "resupply": return
	# 换了命令才有整理与展开的延迟；同一命令延续不重复扣。
	if str(action.get("type", "")) != str(army.get("action", {}).get("type", "")):
		Process.issue_order(army, {"terrain": _terrain(str(army["location"]["node"])), "action": str(action.get("type", ""))})
	army["action"] = action.duplicate(true)
	var location: Dictionary = army["location"]
	match str(action["type"]):
		"march":
			var destination := str(action["target"])
			if destination != str(army["target"]) and not can_cross(str(army["faction"]), destination): army["action"] = {"type": "hold"}; return
			location["from"] = location["node"]
			location["to"] = action["target"]
			location["edge"] = action["edge"]
			location["progress"] = 0.0
		"scout": army["scouted_at"] = int(state["tick"])
		"withdraw":
			army["returning"] = true
			if str(army["outcome"]) == "":
				army["outcome"] = "撤退"
			state["missions"][army["id"]]["status"] = "returning"
			_start_return(army)
		"resupply":
			var city: Dictionary = store.city_state(str(location["node"]))
			var need: int = maxi(0, int(ceil(daily_food(army) * float(rules["carry_days"]) - float(army["grain"]))))
			var take: int = mini(need, mini(int(city.get("grain", 0)), int(ceil(daily_food(army) * 10))))
			city["grain"] -= take
			army["grain"] += take
			store.city_changed.emit(str(location["node"]))
		"request_support":
			army["last_support"] = int(state["tick"])
			_report(army, "求援", "%s请求增援，目前兵力%d。" % [army["name"], Combat.strength(army)], true)


func _start_return(army: Dictionary) -> void:
	if army.has("tactical"): return
	var location: Dictionary = army["location"]
	if str(location.get("edge", "")) != "":
		if not bool(location.get("reversed", false)):
			var old_from: String = str(location["from"])
			location["from"] = location["to"]
			location["node"] = location["to"]
			location["to"] = old_from
			location["progress"] = 1.0 - float(location["progress"])
			location["reversed"] = true
		return
	var best: Dictionary = {}
	var best_cost: float = INF
	var destination: String = ""
	# Equal-cost retreat cities need the same tie-break before and after JSON load.
	var friendly_ids: Array = store.scenario.get("places", {}).keys()
	friendly_ids.sort()
	for id in friendly_ids:
		var city: Dictionary = store.city_state(str(id))
		if not city.has("garrison") or str(city.get("faction", "")) != str(army["faction"]):
			continue
		var path: Dictionary = route(str(army["faction"]), str(location["node"]), str(id))
		if bool(path["found"]) and float(path["cost"]) < best_cost:
			best = path
			best_cost = float(path["cost"])
			destination = str(id)
	if destination == "":
		# 无可达友城时不能无限期滞留：逐日散亡、逐日衰退，逾期按溃散收束，
		# 否则 returning 永远为真，月度推进被 active_armies 非空永久拒绝。
		var since := int(army.get("return_stalled_since", state["tick"]))
		army["return_stalled_since"] = since
		var stalled := int(state["tick"]) - since
		if stalled == 0:
			_report(army, "退路受阻", "%s没有可达的友城，暂时驻守并请求支援。" % army["name"], true)
		Combat.apply_loss(army, maxi(1, int(ceil(Combat.strength(army) * 0.05))))
		army["morale"] = maxf(0.0, float(army["morale"]) - 6.0)
		army["last_reason"] = "退路断绝，部众正在散亡（%d/%d日）" % [stalled, int(rules.get("return_stall_days", 10))]
		if stalled >= int(rules.get("return_stall_days", 10)) or Combat.strength(army) <= 0:
			_finish(army, "退路断绝，部众散亡")
		return
	army.erase("return_stalled_since")
	army["return_destination"] = destination
	if best["nodes"].size() == 1:
		_finish(army, str(army.get("outcome", "撤退")))
	else:
		location["from"] = location["node"]
		location["to"] = best["nodes"][1]
		location["edge"] = best["edges"][0]
		location["progress"] = 0.0
		location["reversed"] = false


func _move_all() -> Dictionary:
	if state.has("battlefield"): return Tactical.move(self)
	var motions: Dictionary = Battlefields.run(self, "move")
	for army in active_armies():
		if army.has("tactical"): continue
		if not ready(army): continue
		var location: Dictionary = army["location"]
		var before: Dictionary = location.duplicate(true)
		if str(location.get("edge", "")) != "" and str(army["action"]["type"]) in ["march", "continue", "withdraw"]:
			var edge: Dictionary = graph.edges.get(location["edge"], {})
			if graph.blocked.has(location["to"]) or graph.blocked.has(location["from"]):
				army["action"] = {"type": "hold"}
				_report(army, "通路受阻", "%s行军通路受阻，正在重新判断。" % army["name"], true)
			else:
				var leader: Dictionary = army
				if army.has("corps_id"): leader = state["armies"][state["corps"][army["corps_id"]]["root_id"]]
				var speed: float = Process.march_speed(leader, _terrain(str(location["node"])))
				location["progress"] = minf(1.0, float(location["progress"]) + speed / maxf(float(edge.get("cost", 1)) * float(rules["route_days_per_cost"]), 1))
				army["fatigue"] = minf(100, float(army["fatigue"]) + Process.fatigue_cost(army, 3.0))
				if float(location["progress"]) >= 1.0:
					location["node"] = location["to"]
					location["edge"] = ""
					location["progress"] = 0.0
		motions[army["id"]] = {"before": before, "after": location.duplicate(true)}
	return motions


func _edge_coordinate(location: Dictionary) -> float:
	var edge: Dictionary = graph.edges.get(location.get("edge", ""), {})
	return float(location.get("progress", 0)) if str(location.get("from", "")) == str(edge.get("from", "")) else 1.0 - float(location.get("progress", 0))


func _contact(a: Dictionary, b: Dictionary, motions: Dictionary) -> bool:
	var la: Dictionary = a["location"]
	var lb: Dictionary = b["location"]
	if str(la.get("edge", "")) == "" and str(lb.get("edge", "")) == "":
		return str(la["node"]) == str(lb["node"])
	var ma: Dictionary = motions.get(a["id"], {"before": la, "after": la})
	var mb: Dictionary = motions.get(b["id"], {"before": lb, "after": lb})
	var ea: String = str(ma["before"].get("edge", ""))
	var eb: String = str(mb["before"].get("edge", ""))
	if ea == "": ea = str(la.get("edge", ""))
	if eb == "": eb = str(lb.get("edge", ""))
	if ea == "" or ea != eb:
		return false
	var aa: Dictionary = ma["before"] if str(ma["before"].get("edge", "")) != "" else la
	var bb: Dictionary = mb["before"] if str(mb["before"].get("edge", "")) != "" else lb
	var old_delta: float = _edge_coordinate(aa) - _edge_coordinate(bb)
	var a_end: float = _edge_coordinate(la) if str(la.get("edge", "")) != "" else (1.0 if str(la["node"]) == str(graph.edges[ea]["to"]) else 0.0)
	var b_end: float = _edge_coordinate(lb) if str(lb.get("edge", "")) != "" else (1.0 if str(lb["node"]) == str(graph.edges[ea]["to"]) else 0.0)
	return absf(a_end - b_end) < 0.13 or old_delta * (a_end - b_end) <= 0


func _resolve_contacts(motions: Dictionary) -> void:
	if state.has("battlefield"):
		Tactical.resolve(self)
		return
	Battlefields.prepare(self)
	Battlefields.roads(self, motions)
	Battlefields.run(self, "resolve")
	var armies: Array = active_armies().filter(func(army): return not army.has("tactical") and ready(army))
	var engaged: Dictionary = {}
	for i in range(armies.size()):
		for j in range(i + 1, armies.size()):
			var a: Dictionary = armies[i]
			var b: Dictionary = armies[j]
			if not hostile(str(a["faction"]), str(b["faction"])) or engaged.has(a["id"]) or engaged.has(b["id"]) or not _contact(a, b, motions):
				continue
			if not bool(orders_for(a)["engage"]) or not bool(orders_for(b)["engage"]):
				var initiated := false
				for side in [a, b]:
					var type: String = side["action"]["type"]
					initiated = initiated or (type == "engage" and bool(orders_for(side)["engage"])) or (type == "pursue" and bool(orders_for(side)["pursue"]))
				if not initiated: continue
			engaged[a["id"]] = true
			engaged[b["id"]] = true
			if bool(a["returning"]) or bool(b["returning"]):
				var fleeing: Dictionary = a if bool(a["returning"]) else b
				var pursuer: Dictionary = b if bool(a["returning"]) else a
				if bool(orders_for(pursuer)["pursue"]) and str(pursuer["action"]["type"]) in ["pursue", "engage"]:
					pursuer["combat_tick"] = int(state["tick"])
					var chased: int = Combat.apply_loss(fleeing, mini(Combat.strength(fleeing), int(Combat.strength(pursuer) * Process.pursuit_rate(pursuer, fleeing))), true)
					_report(fleeing, "遭遇追击", Explain.signed(fleeing, "withdraw撤离", "%s撤退途中被追击，%d人被俘。" % [fleeing["name"], chased]), true)
					_report(pursuer, "追击", Explain.signed(pursuer, "pursuit追击", "追击%s，俘获%d人。" % [fleeing["name"], chased]), false)
					_remember_loss(fleeing, "遭遇追击")
					pursuer["fatigue"] = minf(100, float(pursuer["fatigue"]) + Process.fatigue_cost(pursuer, 8, true))
				continue
			# Freeze road movement at the contact point for the next day's battle.
			var edge_id: String = str(a["location"].get("edge", ""))
			if edge_id != "" and str(b["location"].get("edge", "")) == edge_id:
				var coordinate: float = (_edge_coordinate(a["location"]) + _edge_coordinate(b["location"])) * 0.5
				for combatant in [a, b]:
					combatant["location"]["progress"] = coordinate if str(combatant["location"]["from"]) == str(graph.edges[edge_id]["from"]) else 1.0 - coordinate
			var side_a: Array = [a]
			var side_b: Array = [b]
			for support in armies:
				if engaged.has(support["id"]) or bool(support["returning"]): continue
				if str(support["faction"]) == str(a["faction"]) and _contact(support, b, motions):
					side_a.append(support)
					engaged[support["id"]] = true
				elif str(support["faction"]) == str(b["faction"]) and _contact(support, a, motions):
					side_b.append(support)
					engaged[support["id"]] = true
			var terrain: String = _terrain(str(a["location"]["node"]))
			for attacker in side_a:
				for defender in side_b: _battle_contact(attacker, defender)
			for attacker in side_b:
				for defender in side_a: _battle_contact(attacker, defender)
			if not side_a.is_empty() and not side_b.is_empty(): Duel.challenge(self, side_a[0], side_b[0])
			var combined_a: Dictionary = Combat.aggregate(side_a)
			var combined_b: Dictionary = Combat.aggregate(side_b)
			var hit_a := Combat.losses_detail(combined_b, combined_a, rules, terrain, rng.randf_range(0.9, 1.1))
			var loss_a: int = int(hit_a["loss"])
			var hit_b := Combat.losses_detail(combined_a, combined_b, rules, terrain, rng.randf_range(0.9, 1.1))
			var loss_b: int = int(hit_b["loss"])
			var report_losses := {}
			var credit_a := {}
			var credit_b := {}
			var commanders := {}
			for member in side_a + side_b: commanders[member["id"]] = member["officer_id"]
			for member in side_a: credit_a[member["id"]] = Combat.strength(member)
			for member in side_b: credit_b[member["id"]] = Combat.strength(member)
			var personal_a := Fate.personal_weights(side_a, credit_a, float(hit_b.get("personal_fraction", 0)), rules)
			var personal_b := Fate.personal_weights(side_b, credit_b, float(hit_a.get("personal_fraction", 0)), rules)
			var sides := [[side_a, loss_a, loss_b, Combat.strength(combined_b)], [side_b, loss_b, loss_a, Combat.strength(combined_a)]]
			for side_index in sides.size():
				var side: Array = sides[side_index]
				var members: Array = side[0]
				# Index, not members == side_a: Array equality is a deep value compare.
				var enemy_members: Array = sides[1 - side_index][0]
				var total_strength: int = Combat.strength(Combat.aggregate(members))
				var remaining: int = int(side[1])
				for member in members:
					member["battle_factors"] = Feedback.factors(enemy_members[0], member, rules, terrain)
					member["combat_tick"] = int(state["tick"])
					var loss: int = mini(remaining, int(ceil(float(side[1]) * Combat.strength(member) / maxf(total_strength, 1))))
					var before_strength := Combat.strength(member)
					var dead_before := int(member["dead"])
					loss = Combat.apply_loss(member, loss, false, 0.0, 0.0, 0.5, rules)
					Fate.credit(self, credit_b if side_index == 0 else credit_a, int(member["dead"]) - dead_before, commanders, personal_b if side_index == 0 else personal_a)
					report_losses[member["id"]] = loss
					Feedback.loss(self, member, loss)
					Combat.battle_morale(member, loss, float(side[2]) * before_strength / maxf(total_strength, 1), before_strength, float(side[3]), total_strength, float(side[3]), false, 0.0, 0.5, rules)
					remaining -= loss
					member["fatigue"] = minf(100, float(member["fatigue"]) + Process.fatigue_cost(member, 5, true))
					_check_rout(member)
					if member["returning"] or member["status"] == "ended":
						for winner in enemy_members: _battle_victory(winner)

			for member in side_a + side_b:
				var loss: int = int(report_losses.get(member["id"], 0))
				_report(member, "交战", "%s与敌军交战，本日损失%d人，士气%d。" % [member["name"], loss, int(member["morale"])], true)


func _terrain(node: String) -> String:
	var place: Dictionary = graph.places.get(node, {})
	if str(place.get("type", "")) == "pass":
		return "mountains"
	return str(rules["terrain_regions"].get(str(place.get("region_id", "")), "plains"))


func _resolve_sieges() -> void:
	Siege.resolve(self)
	for node in state["sieges"]:
		var siege: Dictionary = state["sieges"][node]
		if float(siege.get("wall", 1)) > 0 and float(siege.get("gate", 1)) > 0: continue
		for id in siege.get("participants", []):
			var army: Dictionary = state["armies"].get(id, {})
			if army.is_empty() or army["faction"] != state["player_faction"]: continue
			_report(army, "破城", graph.name_of(str(node)) + "防线已出现破口，部队可进入城内作战。", true, "siege:%s:%s" % [node, siege.get("started", 0)])
			break


func _capture_city(army: Dictionary, besiegers: Array, node: String, city: Dictionary) -> void:
	var old_faction := str(city.get("faction", ""))
	var guard := str(state["garrison_commanders"].get(node, {}).get("officer_id", ""))
	for id in state["officer_states"]:
		var officer: Dictionary = state["officer_states"][id]
		if id == guard or officer.get("status", "") not in ["available", "recovering"] or officer.get("city", "") != node or roster.officers.get(id, {}).get("faction", "") != old_faction: continue
		state["officer_fates"][id] = {"officer_id": id, "name": roster.officers[id]["name"], "faction": old_faction, "status": "captured", "tick": int(state["tick"]), "cause": "城池失守", "captor_id": army["officer_id"], "captor_faction": army["faction"], "city": node}
	Fate.restore(self)
	city["prisoners"] = int(city.get("prisoners", 0)) + int(city["garrison"]) + int(city.get("wounded", 0))
	city["wounded"] = 0
	city["wounded_units"] = {"infantry": 0, "archers": 0, "cavalry": 0}
	city["garrison"] = 0
	city["units"] = {"infantry": 0, "archers": 0, "cavalry": 0}
	city["faction"] = army["faction"]
	roster.ensure_factions(store.scenario)
	for id in roster.officers:
		if roster.officers[id].get("generated", false): state["generated_officers"][id] = roster.officers[id].duplicate(true)
	city["last_volley_tick"] = -10
	city["governor_id"] = ""
	city["occupied_at"] = int(state["tick"])
	var left := 0
	for unit in besiegers:
		var remaining := mini(Combat.strength(unit), maxi(1, int(Combat.strength(unit) * 0.15)))
		var deposited := remaining
		for type in Combat.TYPES:
			var take := mini(remaining, int(unit["units"][type]))
			unit["units"][type] -= take
			city["units"][type] += take
			remaining -= take
		unit["deposited"] += deposited
		left += deposited
	city["garrison"] = left
	if city.has("population"):
		for officer in available_officers(str(army["faction"])):
			city["governor_id"] = officer["id"]
			break
	var winners := {}
	for victor in besiegers:
		_battle_victory(victor)
		winners[victor["id"]] = victor
		var corps: Dictionary = state["corps"].get(victor.get("corps_id", ""), {})
		for id in corps.get("units", []): winners[id] = state["armies"][id]
	for unit in winners.values():
		if unit["status"] == "ended": continue
		unit["objective_complete"] = true
		unit["outcome"] = "攻取成功"
		if _has_independent_action(unit): continue
		if orders_for(unit)["after_battle"] == "withdraw": _execute(unit, {"type": "withdraw"})
		else: unit["action"] = {"type": "hold"}
	_report(army, "占领", "%s攻取%s，留下%d人驻防。" % [army["name"], graph.name_of(node), left], true)
	if state.get("battlefield", {}).get("objectives", {}).has(node):
		state["battlefield"]["winner"] = army["faction"]
		state["battlefield"]["ended_at"] = state["tick"]


func _fate_enemy(army: Dictionary) -> Dictionary:
	var recent: Dictionary = state["armies"].get(army.get("last_enemy_id", ""), {})
	if int(army.get("last_enemy_tick", -1)) == int(state["tick"]) and not recent.is_empty() and recent["faction"] != army["faction"]: return recent
	for enemy in active_armies():
		if not hostile(str(enemy["faction"]), str(army["faction"])) or enemy["returning"]: continue
		if army.has("tactical") and enemy.has("tactical"):
			if Tactical.distance(army, enemy) <= 1: return enemy
		elif _contact(army, enemy, {}): return enemy
	var guard: Dictionary = state["garrison_commanders"].get(army["target"], {})
	if not guard.is_empty() and guard["faction"] != army["faction"] and Siege.at_city(self, army, army["target"]):
		var defender := guard.duplicate(true)
		defender["units"] = store.city_state(army["target"]).get("units", {})
		return defender
	return {}

func _check_rout(army: Dictionary) -> void:
	if army["status"] == "ended": return
	if Combat.strength(army) <= 0:
		Fate.encounter(self, army, _fate_enemy(army), "destroyed", 1.0)
		state["battle_victories"].erase(str(army["officer_id"]))
		army["victory_chain"] = false
		_finish(army, "军队覆没")
		return
	if army["returning"]: return
	var morale := float(army["morale"])
	var organization := float(army["organization"])
	var aura_shift := float(army.get("aura", 0.0)) * float(rules.get("officer", {}).get("aura_rout_shift", 20))
	if morale >= 25.0 - aura_shift and organization >= 20:
		army.erase("rout_crisis_since")
		return
	if not army.has("rout_crisis_since"): army["rout_crisis_since"] = int(state["tick"])
	# A disordered but supplied force can rally behind nearby healthy allies.
	# Hard panic still routs; manpower alone never makes a shattered army invincible.
	var supported := false
	if army.has("tactical"):
		for friend in active_armies(str(army["faction"])):
			if friend["id"] != army["id"] and not friend["returning"] and friend.has("tactical") and float(friend["morale"]) >= 35 and float(friend["organization"]) >= 30 and Tactical.distance(army, friend) <= 3:
				supported = true
				break
	var substantial := Combat.strength(army) >= maxf(500, float(army.get("initial_strength", 0)) * 0.4)
	var corps: Dictionary = state["corps"].get(army.get("corps_id", ""), {})
	var can_regroup: bool = not corps.is_empty() and army["id"] != corps["root_id"]
	var rally_window := int(state["tick"]) - int(army["rout_crisis_since"]) < 6
	if supported and substantial and can_regroup and rally_window and morale > 10 and organization > 8 and (not supply_enabled() or float(army.get("grain", 0)) >= daily_food(army)):
		var reason := "友军掩护，主帅令本队归建整阵，仍留在战场"
		var regroup_result := Corps.issue(self, corps, {"type": "assign_task", "unit": army["id"], "task": "regroup"}, reason)
		if regroup_result.get("ok", false):
			army["last_reason"] = reason
			army["rally_requested"] = int(state["tick"])
			return
	if supported and morale > 10 and organization > 8 and int(state["tick"]) == int(army["rout_crisis_since"]):
		army["last_reason"] = "友军接应稳住阵线，等待主帅接替"
		return
	army["returning"] = true
	army["outcome"] = "溃败撤退"
	Fate.encounter(self, army, _fate_enemy(army), "rout", 1.0)
	army["retreat_reason"] = "军心崩溃（士气%d）" % int(morale) if morale < 25 else "阵形崩溃（组织%d）" % int(organization)
	army["last_reason"] = army["retreat_reason"]
	state["battle_victories"].erase(str(army["officer_id"]))
	army["victory_chain"] = false
	_report(army, "溃败", "%s所部%s，剩余%d人，正在有序脱离。" % [army["name"], army["retreat_reason"], Combat.strength(army)], true)
	_remember_loss(army, "军心崩溃")
	_start_return(army)


func _check_leader_lost() -> void:
	var section: Dictionary = rules.get("officer", {})
	for corps in state["corps"].values():
		if corps.get("ended", false): continue
		var root: Dictionary = state["armies"].get(str(corps.get("root_id", "")), {})
		if root.is_empty(): continue
		if not (str(root.get("status", "")) == "ended" or bool(root.get("returning", false))): continue
		if str(corps.get("leader_lost_for", "")) == str(corps.get("commander_id", "")): continue
		corps["leader_lost_for"] = str(corps.get("commander_id", ""))
		corps["leader_lost"] = true
		var sample := {}
		for id in corps.get("units", []):
			var unit: Dictionary = state["armies"].get(str(id), {})
			if unit.is_empty() or str(unit["status"]) == "ended" or unit["id"] == root["id"]: continue
			unit["morale"] = maxf(0.0, float(unit["morale"]) - float(section.get("leader_loss_morale", 8)))
			unit["organization"] = maxf(0.0, float(unit["organization"]) - float(section.get("leader_loss_org", 4)))
			if sample.is_empty(): sample = unit
		if not sample.is_empty():
			_report(sample, "主帅失位", "主帅失位：%s所部军心动摇，全军士气下降。" % str(corps.get("name", "")), true)


func daily_food(army: Dictionary) -> float:
	return (Combat.strength(army) + int(army.get("wounded", 0))) * float(rules["grain_per_soldier_day"])


func _upkeep() -> void:
	for army in active_armies():
		Process.end_day(army)
		if army.has("tactical"):
			var terrain := Tactical.terrain_class(army["tactical"]["cell"])
			army["fatigue"] = minf(100, float(army["fatigue"])+float(Terrain.settings(terrain,rules).get("daily_fatigue",0)))
		var needed: float = 0
		var provided: float = 0
		if supply_enabled():
			needed = daily_food(army)
			provided = minf(float(army["grain"]), needed)
			army["grain"] = maxf(0, float(army["grain"]) - provided)
			if provided + 0.001 < needed:
				army["morale"] = maxf(0, float(army["morale"]) - 8)
				army["organization"] = maxf(0, float(army["organization"]) - 5)
				Combat.apply_loss(army, int(ceil(Combat.strength(army) * 0.005)))
				_report(army, "缺粮", "%s所部携粮耗尽，士气与组织持续下降。" % army["name"], true)
		var resting: bool = int(army.get("combat_tick", -1)) != int(state["tick"]) and (str(army["action"]["type"]) in ["hold", "scout", "resupply", "request_support"] or (army.has("tactical") and int(army["tactical"].get("moved_tick", -1)) != int(state["tick"])))
		if resting:
			var recovery := Process.recovery(army)
			army["fatigue"] = maxf(0, float(army["fatigue"]) - float(recovery["fatigue"]))
			if provided >= needed:
				army["organization"] = minf(100, float(army["organization"]) + float(recovery["organization"]))
				army["morale"] = minf(100, float(army["morale"]) + float(recovery["morale"]))
		if int(state["tick"]) >= int(army["deadline"]):
			army["returning"] = true
			if str(army["outcome"]) == "": army["outcome"] = "任务期限已到"
		if str(army["mission_type"]) == "capture" and not _has_independent_action(army) and str(store.city_state(str(army["target"])).get("faction", "")) == str(army["faction"]) and not bool(army["returning"]) and orders_for(army)["after_battle"] == "withdraw":
			army["returning"] = true
			army["outcome"] = "目标已由本方控制"
		if str(army["location"].get("edge", "")) == "" and str(army["location"]["node"]) == str(army["target"]) and not army.has("arrived_at"):
			army["arrived_at"] = int(state["tick"])
		if str(army["mission_type"]) == "defend" and army.has("arrived_at") and int(state["tick"]) >= int(army["arrived_at"]) + 15 and army["intel"]["enemies"].is_empty():
			army["returning"] = true
			army["outcome"] = "守援完成"
		if bool(army["returning"]) and str(army["location"].get("edge", "")) == "":
			_start_return(army)
		_check_rout(army)



func _finish(army: Dictionary, outcome: String) -> void:
	if str(army["status"]) == "ended":
		return
	var node: String = str(army["location"]["node"])
	var city: Dictionary = store.city_state(node)
	var strength: int = Combat.strength(army)
	if outcome == "失去指挥溃散":
		army["grain"] = 0.0
	elif city.has("garrison") and str(city.get("faction", "")) == str(army["faction"]):
		_sync_inventory(city)
		for type in Combat.TYPES:
			city["units"][type] += int(army["units"][type])
		city["garrison"] += strength
		city["wounded"] = int(city.get("wounded", 0)) + int(army["wounded"])
		var wounded_units: Dictionary = army.get("wounded_units", {"infantry": int(army["wounded"]), "archers": 0, "cavalry": 0})
		for type in Combat.TYPES: city["wounded_units"][type] += int(wounded_units.get(type, 0))
		if city.has("grain"): city["grain"] += int(floor(float(army["grain"])))
		army["returned_strength"] = strength
		army["returned_wounded"] = army["wounded"]
		army["returned_grain"] = int(floor(float(army["grain"])))
		army["deposited"] += strength
		army["units"] = {"infantry": 0, "archers": 0, "cavalry": 0}
		army["grain"] = 0.0
		store.city_changed.emit(node)
	elif outcome == "军队覆没" and int(army["wounded"]) > 0:
		army["captured"] += int(army["wounded"])
		army["wounded"] = 0
	elif strength > 0:
		# 在非本方节点收束（家乡易手、退路断绝、守援/期限到期）：存活兵员既不能
		# 进城也不该凭空消失，按被俘入账，否则 initial ≠ dead+wounded+captured+现存。
		Combat.apply_loss(army, strength, true)
		army["surrendered_at"] = node
		_report(army, "部众被收容", "%s在%s收束，%d人解甲被俘。" % [army["name"], graph.name_of(node), strength], true)
	army.erase("return_stalled_since")
	army["status"] = "ended"
	army["outcome"] = outcome
	state["missions"][army["id"]]["status"] = "ended"
	state["missions"][army["id"]]["result"] = outcome
	state["officer_states"][army["officer_id"]] = {"status": "available" if outcome != "军队覆没" and not army.get("duel_wounded", false) else "recovering", "city": node, "available_after": int(state["tick"]) + (int(rules["duel"]["recover_days"]) if army.get("duel_wounded", false) else 10)}
	if army.get("duel_wounded", false): state["officer_states"][army["officer_id"]]["duel_wounded"] = true
	army.erase("pending_request")
	army.erase("approved_action")
	army["trust"] = float(army.get("trust", 0.0)) * 0.5
	army["resentment"] = float(army.get("resentment", 0.0)) * 0.5
	Corps.on_finish(self, army)
	Fate.restore(self)
	_report(army, "任务结束", "%s：%s。归队%d，伤兵%d，阵亡%d，被俘%d，留驻%d，溃散%d。" % [army["name"], outcome, int(army.get("returned_strength", 0)), int(army["wounded"]), int(army["dead"]), int(army["captured"]), int(army["deposited"]) - int(army.get("returned_strength", 0)), int(army.get("dispersed", 0))], true)


func _report(army: Dictionary, kind: String, message: String, urgent: bool, event_key: String = "") -> void:
	if ReportPolicy.eligible(kind) or kind in ["武将战死", "武将被俘", "斩获", "主将接替", "单挑", "溃败", "变阵", "粮道截断", "占领", "主帅分兵", "专长", "主帅失位", "违令", "违令请示"]: Feedback.event(self, kind, message, army["faction"])
	if kind in ["交战", "战线交战", "围城"]:
		var factors: Array = army.get("battle_factors", [])
		if not factors.is_empty(): message += " " + "；".join(factors)
	# Keep tactical memory even when the event produces no notification.
	army["memory"].append({"tick": state["tick"], "kind": kind, "event": message})
	while army["memory"].size() > 8: army["memory"].pop_front()
	if str(army["faction"]) != str(state["player_faction"]): return
	if not ReportPolicy.allow(state, army, kind, event_key): return
	var reports: Array = state["reports"]
	var id: String = "report-%d-%d" % [int(state["tick"]), int(state["next_id"])]
	state["next_id"] += 1
	reports.append({"id": id, "army_id": army["id"], "faction": army["faction"], "kind": kind, "message": message, "sent_tick": int(state["tick"]), "sent_date": store.date_text(), "delivery_tick": int(state["tick"]) + (0 if kind in ["战役总结", "战役终结"] else int(rules["report_delay_days"])), "received": false, "urgent": urgent, "snapshot": {"commander": roster.officers.get(army["officer_id"], {}).get("name", army["name"]), "enemy_killed": int(army.get("enemy_killed", 0)), "commander_killed": int(state["officer_personal_kills"].get(army["officer_id"], 0)), "troop_killed": int(army.get("enemy_killed", 0)) - int(army.get("personal_soldier_kills", 0)), "commander_fate": army.get("commander_fate", {}).duplicate(true), "location": army["location"].duplicate(true), "strength": Combat.strength(army), "morale": army["morale"], "grain_days": int(food_days(army)), "battle_factors": army.get("battle_factors", []).duplicate() if kind in ["交战", "战线交战", "围城"] else [], "wounded": int(army["wounded"]), "organization": float(army["organization"]), "fatigue": float(army["fatigue"]), "daily_loss": int(army.get("daily_loss", 0)) if int(army.get("daily_loss_tick", -1)) == int(state["tick"]) else 0, "terrain": Tactical.terrain_class(army["tactical"]["cell"]) if army.has("tactical") else "", "reason": str(army["last_reason"]), "ended": str(army["status"]) == "ended", "cities": army["intel"]["cities"].duplicate(true)}})
	while reports.size() > 200:
		reports.pop_front()


func _deliver_reports() -> void:
	Duel.recover(self)
	for report in state["reports"]:
		if not bool(report["received"]) and int(report["delivery_tick"]) <= int(state["tick"]):
			report["received"] = true
			report["received_date"] = store.date_text()
			var army: Dictionary = state["armies"].get(report["army_id"], {})
			if not army.is_empty(): army["last_report"] = report.duplicate(true)
			if bool(report["urgent"]): urgent_event = true
	for id in state["officer_states"]:
		var officer: Dictionary = state["officer_states"][id]
		if str(officer.get("status", "")) == "recovering" and int(officer.get("available_after", 0)) <= int(state["tick"]):
			var corps: Dictionary = state["corps"].get(officer.get("corps_id", ""), {})
			officer["status"] = "deployed" if not corps.is_empty() and not corps.get("ended", false) else "available"
			officer.erase("duel_wounded")


func visible_reports() -> Array:
	var result: Array = []
	for report in state["reports"]:
		if bool(report["received"]): result.push_front(report)
	return result


func has_pending_urgent_report() -> bool:
	for report in state["reports"]:
		if not bool(report["received"]) and bool(report["urgent"]): return true
	return false


func player_markers() -> Array:
	var result: Array = []
	for army in state["armies"].values():
		if str(army["faction"]) != str(state["player_faction"]): continue
		var observation: Dictionary = army.get("last_observation", {})
		if not observation.is_empty() and not bool(observation.get("ended", false)):
			result.append({"id": army["id"], "name": army["name"], "location": observation["location"], "date": observation["date"], "strength": observation["strength"]})
	return result


func player_city_intel(node: String) -> Dictionary:
	return city_intel(node)

func player_has_city_access(node: String) -> bool:
	return not store.city_state(node).is_empty() and str(store.city_state(node).get("faction", "")) == str(state["player_faction"])


func _battle_contact(attacker: Dictionary, defender: Dictionary, melee: bool = true) -> void:
	if melee and not attacker.has("first_melee_tick"): attacker["first_melee_tick"] = state["tick"]
	if melee and not defender.has("first_melee_tick"): defender["first_melee_tick"] = state["tick"]
	if melee and Signature.opening(attacker, defender):
		_report(attacker, "小霸王连胜", "%s小霸王：连续主动出战，首次接敌士气冲击提高8%%。" % attacker["name"], false)
	if Signature.first_contact(attacker, defender, melee):
		attacker["first_contact_effect_tick"] = state["tick"]
		defender["first_contact_effect_tick"] = state["tick"]
		_report(defender, "武圣威压", "%s武圣：与%s首次正面交锋，%s士气下降8。" % [attacker["name"], defender["name"], defender["name"]], true)


func _battle_victory(army: Dictionary) -> void:
	_remember_win(army, "交战取胜")
	if not Traits.mechanism(army, "victory_chain").is_empty() and army.get("mission_type", "") == "capture" and not army.get("returning", false) and army.get("status", "") != "ended":
		state["battle_victories"][str(army["officer_id"])] = int(state["tick"])


func _remember_win(army: Dictionary, cause: String) -> void:
	if int(army.get("experience_tick", -1)) == int(state["tick"]): return
	army["experience_tick"] = int(state["tick"])
	Experience.record_win(self, army, _nearest_enemy_id(army), cause)


func _remember_loss(army: Dictionary, cause: String) -> void:
	if int(army.get("experience_tick", -1)) == int(state["tick"]): return
	army["experience_tick"] = int(state["tick"])
	Experience.record_loss(self, army, _nearest_enemy_id(army), cause)


func _nearest_enemy_id(army: Dictionary) -> String:
	var best := ""
	var closest := 1 << 30
	for other in active_armies():
		if not hostile(str(other.get("faction", "")), str(army.get("faction", ""))): continue
		var distance := 1
		if army.has("tactical") and other.has("tactical"): distance = Tactical.distance(army, other)
		elif str(army.get("location", {}).get("node", "")) == str(other.get("location", {}).get("node", "")): distance = 0
		if distance < closest: closest = distance; best = str(other.get("id", ""))
	return best


func supply_enabled() -> bool:
	return bool(rules.get("supply_enabled", false))

# 兵员账本：出征兵力必须等于 现存 + 留驻 + 阵亡 + 伤兵 + 被俘 + 溃散。
# 任何一条收束路径漏记都会在这里暴露为非零 missing。
func ledger(army: Dictionary) -> Dictionary:
	var accounted: int = Combat.strength(army) + int(army.get("deposited", 0)) + int(army.get("dead", 0)) + int(army.get("wounded", 0)) + int(army.get("captured", 0)) + int(army.get("dispersed", 0))
	var initial := int(army.get("initial_strength", 0))
	return {"initial": initial, "accounted": accounted, "missing": initial - accounted}

func food_days(army: Dictionary) -> float:
	return float(army.get("grain", 0)) / maxf(daily_food(army), 0.001) if supply_enabled() else 999.0


func request_battle_summary(army_id: String = "") -> Dictionary:
	# Player requests are immediate reads and do not consume notification dedup keys.
	if army_id.is_empty(): return Feedback.summary(self)
	var army: Dictionary = state["armies"].get(army_id, {})
	if army.is_empty() or army.get("faction", "") != state["player_faction"]: return {}
	return {"army": army.duplicate(true), "decisions": army.get("decision_history", []).duplicate(true), "orders": state["corps"].get(army.get("corps_id", ""), {}).get("orders", []).duplicate(true)}

func _summarize_finished_battles() -> void:
	var boards: Array = state.get("battlefields", {}).values().duplicate()
	if state.has("battlefield") and not state["battlefield"] in boards: boards.append(state["battlefield"])
	var covered := {}
	for board in boards:
		if not board.has("ended_at"): continue
		var board_id := str(board.get("battle_id", "field:" + str(board.get("anchor", ""))))
		var members: Array = state["armies"].values().filter(func(army): return army.get("battlefield_id", "") == board_id or army.get("last_battlefield_id", "") == board_id)
		var sample: Dictionary = {}
		for army in members:
			covered[ReportPolicy.scope(army)] = true
			if army["faction"] == state["player_faction"] and sample.is_empty(): sample = army
		if sample.is_empty(): continue
		var starting_strength := 0
		for army in members: starting_strength += int(army.get("initial_strength", 0))
		var key_objective: bool = bool(board.get("key_objective", false)) or not board.get("control_point", {}).is_empty() or not board.get("objectives", {}).is_empty()
		if starting_strength < int(rules.get("report_policy", {}).get("major_strength", 10000)) and not board.get("major_battle", false) and not key_objective: continue
		var message := "会战结束：%s。%s" % [str(board.get("victory_reason", board.get("winner", "双方已脱离战场"))), _casualty_summary(members)]
		_report(sample, "战役总结", message, true, "battle:" + board_id)
	for corps in state["corps"].values():
		if covered.has(str(corps.get("id", ""))): continue
		var members: Array = []
		for id in corps.get("units", []):
			if state["armies"].has(id): members.append(state["armies"][id])
		if members.is_empty() or members.any(func(army): return army["status"] != "ended"): continue
		var strength := 0
		for army in members: strength += int(army.get("initial_strength", 0))
		if strength < int(rules.get("report_policy", {}).get("major_strength", 10000)) and not corps.get("major_battle", false): continue
		var fought: bool = members.any(func(army): return int(army.get("combat_tick", -1)) >= int(army.get("started", 0)) or int(army.get("enemy_killed", 0)) > 0 or int(army.get("dead", 0)) + int(army.get("wounded", 0)) > 0)
		if not fought and not corps.get("major_battle", false): continue
		var sample: Dictionary = members[0]
		if sample["faction"] != state["player_faction"]: continue
		_report(sample, "战役总结", str(corps.get("name", "军团")) + "行动结束。" + _casualty_summary(members), true, "corps:" + str(corps.get("id", sample.get("corps_id", ""))))
	var result: Dictionary = state.get("campaign_result", {})
	if not result.is_empty():
		for army in state["armies"].values():
			if army["faction"] != state["player_faction"]: continue
			_report(army, "战役终结", str(result.get("message", "战役结束")) + _casualty_summary(state["armies"].values()), true, "campaign:" + str(result.get("tick", "")))
			break

func _casualty_summary(members: Array) -> String:
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


func _has_independent_action(army: Dictionary) -> bool:
	var autonomy: Dictionary = army.get("autonomy", {})
	if str(autonomy.get("stance", "obey")) != "obey" and int(autonomy.get("until", 0)) > int(state["tick"]): return true
	var corps: Dictionary = state["corps"].get(army.get("corps_id", ""), {})
	return not corps.is_empty() and bool(Autonomy.blocks_override(self, corps, str(army["officer_id"])).get("blocked", false))
