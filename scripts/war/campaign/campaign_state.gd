class_name CampaignState
extends RefCounted
## 战役状态：军队、军团、城防、军报等全部存档数据都在 state 里，step() 推进一日。
##
## 各项职责的实现在同目录的协作模块里（CampaignLogistics、CampaignReports、CampaignOrders、
## CampaignDispatch、CampaignContext、CampaignContactResolver、CampaignOutcomes、CampaignActions），
## 它们都是静态函数，第一个参数 war 就是本实例。本文件末尾为每个搬走的函数保留同签名的转发，
## 仓库内外（含只在本地的脚本）原有调用 war.xxx() 一律照常可用；常量同样全部保留，外部会以 war.Combat 等形式访问。

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
const Logistics = preload("res://scripts/war/campaign/campaign_logistics.gd")
const Reports = preload("res://scripts/war/campaign/campaign_reports.gd")
const Orders = preload("res://scripts/war/campaign/campaign_orders.gd")
const Dispatch = preload("res://scripts/war/campaign/campaign_dispatch.gd")
const Context = preload("res://scripts/war/campaign/campaign_context.gd")
const Contacts = preload("res://scripts/war/campaign/campaign_contact_resolver.gd")
const Outcomes = preload("res://scripts/war/campaign/campaign_outcomes.gd")
const Actions = preload("res://scripts/war/campaign/campaign_actions.gd")
const StateKeys = preload("res://scripts/war/campaign/war_state_keys.gd")
var store: Node
var graph = Graph.new()
var routes = preload("res://scripts/war/campaign/route_memo.gd").new()
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
	planner.alive = Context.decision_alive.bind(weakref(self))
	store = owner
	rules = _json("res://data/war/campaign_rules.json")
	graph.setup(_json("res://data/world_map.json"))
	for edge in graph.edges.values():
		if Fortifications.road_path(store, str(edge["from"]), str(edge["to"])).is_empty(): graph.closed_routes.append(edge["id"])
	roster.setup(Repository.cards(), rules.get("faction_mapping", {}))
	state = {StateKeys.VERSION: 2, StateKeys.TICK: 0, StateKeys.NEXT_ID: 1, StateKeys.PLAYER_FACTION: "liu_bei", StateKeys.ARMIES: {}, StateKeys.CORPS: {}, StateKeys.SIEGES: {}, StateKeys.MISSIONS: {}, StateKeys.REPORTS: [], StateKeys.REPORT_POLICY: {"sent": {}}, StateKeys.DECISIONS: [], StateKeys.OFFICER_STATES: {}, StateKeys.OFFICER_FATES: {}, StateKeys.OFFICER_KILLS: {}, StateKeys.OFFICER_PERSONAL_KILLS: {}, StateKeys.OFFICER_PERSONAL_SOLDIERS: {}, StateKeys.GARRISON_COMMANDERS: {}, StateKeys.BATTLE_VICTORIES: {}, StateKeys.DEFENSE_COOLDOWNS: {}, StateKeys.RNG_STATE: "0", StateKeys.DISSENT_SEED: 0, StateKeys.DISSENT_STATE: 0, StateKeys.DUELS: {"pairs": {}, "counts": {}, "records": []}, StateKeys.BATTLE_FEEDBACK: {}, StateKeys.STRATEGY_LOG: []}
	if not saved.is_empty():
		for key in state:
			if saved.has(key) and typeof(state[key]) == TYPE_INT and typeof(saved[key]) in [TYPE_INT, TYPE_FLOAT]:
				state[key] = int(saved[key])
			elif saved.has(key) and typeof(saved[key]) == typeof(state[key]):
				state[key] = saved[key]
	state[StateKeys.VERSION] = 3
	state[StateKeys.BATTLE_AI_VERSION] = 1
	state[StateKeys.BATTLE_ROUND] = int(saved.get(StateKeys.BATTLE_ROUND,state[StateKeys.TICK]))
	for key in [StateKeys.BATTLE_AI_MESSAGES,StateKeys.BATTLE_AI_MODEL_LOG,StateKeys.BATTLE_AI_REPLAY]:
		state[key] = saved.get(key,[]).duplicate(true) if saved.get(key,[]) is Array else []
	state[StateKeys.BATTLE_AI_SHADOW] = []
	state[StateKeys.OFFICER_AGENTS] = saved.get(StateKeys.OFFICER_AGENTS,{}).duplicate(true) if saved.get(StateKeys.OFFICER_AGENTS,{}) is Dictionary else {}
	for key in [StateKeys.FACTION_ACTION_POINTS, StateKeys.FACTION_INTEL, StateKeys.BATTLEFIELDS, StateKeys.GENERATED_OFFICERS, StateKeys.FACTION_STATUS, StateKeys.CITY_POLICIES, StateKeys.CAMPAIGN_RESULT, StateKeys.RELATIONS]:
		state[key] = saved.get(key, {}).duplicate(true) if saved.get(key, {}) is Dictionary else {}
	state[StateKeys.CAMPAIGN_STARTED] = bool(saved.get(StateKeys.CAMPAIGN_STARTED, false))
	if not saved.has(StateKeys.RELATIONS): state[StateKeys.RELATIONS] = store.scenario.get("relations", rules.get("relations", {})).duplicate(true)
	state[StateKeys.CITY_VOLLEYS] = []
	for id in state[StateKeys.GENERATED_OFFICERS]: roster.officers[id] = state[StateKeys.GENERATED_OFFICERS][id].duplicate(true)
	roster.ensure_factions(store.scenario)
	for id in roster.officers:
		if roster.officers[id].get("generated", false): state[StateKeys.GENERATED_OFFICERS][id] = roster.officers[id].duplicate(true)
	if saved.get(StateKeys.BATTLEFIELD) is Dictionary:
		state[StateKeys.BATTLEFIELD] = saved[StateKeys.BATTLEFIELD].duplicate(true)
		if not state[StateKeys.BATTLEFIELD].has("battle_id"): state[StateKeys.BATTLEFIELD]["battle_id"] = "field:" + str(state[StateKeys.BATTLEFIELD].get("anchor",0))
	rng.seed = 1910901
	if int(state.get(StateKeys.RNG_STATE, 0)) != 0:
		rng.state = int(state[StateKeys.RNG_STATE])
	# 违令掷点走独立随机流：种子来自剧本/存档，而不是当日战斗随机流的快照，
	# 否则任何一处战斗消耗的差异都会改写全部违令结果，"同种子可复现"不再成立。
	state[StateKeys.DISSENT_SEED] = int(state.get(StateKeys.DISSENT_SEED, 0))
	for army in state[StateKeys.ARMIES].values():
		# 旧档缺将领档案时先补登记，再回写 officer_id；只补不写会留下悬空引用。
		var previous_id := str(army.get("officer_id", ""))
		army["officer_id"] = roster.adopt_militia(army)
		if army["officer_id"] != previous_id:
			var previous_state: Dictionary = state[StateKeys.OFFICER_STATES].get(previous_id, {})
			if not previous_state.is_empty(): state[StateKeys.OFFICER_STATES].erase(previous_id)
			var entry: Dictionary = state[StateKeys.OFFICER_STATES].get(army["officer_id"], {})
			if entry.is_empty(): entry = previous_state
			entry["status"] = str(entry.get("status", "commanding"))
			entry["army_id"] = army["id"]
			state[StateKeys.OFFICER_STATES][army["officer_id"]] = entry
		var officer: Dictionary = roster.officers.get(str(army.get("officer_id", "")), {})
		if army.get("action", {}).get("type", "") == "scout": army["action"] = {"type": "hold"}
		army["trait_ids"] = officer.get("trait_ids", []).duplicate()
		army.erase("battle_traits")
		army["edge"] = Edges.ensure(army, officer)
		if army.has("tactical") and state.has(StateKeys.BATTLEFIELD) and not army.has("battlefield_id"): army["battlefield_id"] = state[StateKeys.BATTLEFIELD]["battle_id"]
	for corps in state[StateKeys.CORPS].values():
		Corps.migrate(self, corps)
		corps["leader_lost"] = bool(corps.get("leader_lost", false))
		corps["leader_lost_for"] = str(corps.get("leader_lost_for", ""))
		corps.erase("last_requested")
		corps.erase("request_signature")
	if not supply_enabled():
		for army in state[StateKeys.ARMIES].values():
			if army.get("action", {}).get("type", "") == "resupply": army["action"] = {"type": "hold"}
			if army.get("corps_task", {}).get("type", "") == "cut_supply":
				army["corps_task"] = {"type": "flank", "reason": "侧翼协同", "issued_at": state[StateKeys.TICK]}
		for corps in state[StateKeys.CORPS].values():
			corps["known_supplies"] = {}
			corps["siege_mode"] = "assault"
			corps["supply"]["blocked_until"] = 0
	for army in state[StateKeys.ARMIES].values(): Experience.ensure(army)
	for guard in state[StateKeys.GARRISON_COMMANDERS].values():
		var officer_id: String = str(guard["officer_id"])
		if roster.officers.has(officer_id) or not officer_id.begins_with("militia:"): continue
		var resolved := roster.adopt_militia({"officer_id": officer_id, "faction": str(guard["faction"])})
		if resolved != officer_id: guard["officer_id"] = resolved
	preload("res://scripts/war/campaign/legacy_formation_migration.gd").apply(state)
	Fate.restore(self)
	Duel.journal(self)
	for id in state[StateKeys.DUELS].get("stamina", {}):
		Duel.stamina(self, {"officer_id":id})
	Tactical.migrate_positions(self)
	# Old saves may still contain leaderless formations on an orderly return route.
	for army in active_armies():
		if army.get("commander_unavailable", false) and Fate.unavailable(self, str(army["officer_id"])):
			Fate.disperse(self, army)
	if not state.has(StateKeys.BATTLEFIELD):
		for board in state[StateKeys.BATTLEFIELDS].values():
			state[StateKeys.BATTLEFIELD] = board
			Tactical.migrate_positions(self)
			state.erase(StateKeys.BATTLEFIELD)
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
	state[StateKeys.RNG_STATE] = str(rng.state)
	var snapshot := state.duplicate(true)
	snapshot.erase(StateKeys.BATTLE_AI_METRICS)
	snapshot.erase(StateKeys.BATTLE_AI_SHADOW)
	for corps in snapshot[StateKeys.CORPS].values():
		corps.erase("last_requested")
		corps.erase("request_signature")
	return snapshot


func active_armies(faction: String = "") -> Array:
	var result: Array = []
	for army in state[StateKeys.ARMIES].values():
		if str(army.get("status", "")) != "ended" and (faction == "" or str(army["faction"]) == faction):
			result.append(army)
	result.sort_custom(func(a, b): return str(a["id"]) < str(b["id"]))
	return result


func ready(army: Dictionary) -> bool:
	return int(army.get("departure_at", 0)) <= int(state[StateKeys.TICK])


func is_besieged(city: String) -> bool:
	var siege: Dictionary = state[StateKeys.SIEGES].get(city, {})
	return int(siege.get("active_tick", -100)) >= int(state[StateKeys.TICK]) - 1 and siege.get("phase", "") not in ["occupied", "解围"]


func hostile(first: String, second: String) -> bool:
	if first == second: return false
	return state.get(StateKeys.RELATIONS, {}).get(_relation_key(first, second), "hostile") == "hostile"


func can_cross(faction: String, node: String) -> bool:
	var owner := str(store.city_state(node).get("faction", ""))
	if owner == "" or owner == faction: return true
	return state.get(StateKeys.RELATIONS, {}).get(_relation_key(faction, owner), "hostile") == "allied"


## 两个不同势力的关系键：按字典序排好后用 | 连接，与 relations 表的键一致。
## route() 每次要对全图地点调用 can_cross，这里不再为每次比较新建并排序数组。
static func _relation_key(first: String, second: String) -> String:
	return first + "|" + second if first < second else second + "|" + first


## 势力从起点到终点的通路：不能穿越非友方城池（起终点除外）。按通行状态记忆，见 route_memo.gd。
func route(faction: String, start: String, finish: String) -> Dictionary:
	return routes.route(self, faction, start, finish)


func campaign_finished() -> bool:
	return not state.get(StateKeys.CAMPAIGN_RESULT, {}).is_empty()


func start_campaign() -> void:
	state[StateKeys.CAMPAIGN_STARTED] = true
	Operations.residence(self)


func set_player_faction(faction: String) -> bool:
	if store.busy or state.get(StateKeys.CAMPAIGN_STARTED, false) or not active_armies(str(state[StateKeys.PLAYER_FACTION])).is_empty() or not store.scenario.get("factions", {}).has(faction):
		return false
	var previous := str(state[StateKeys.PLAYER_FACTION])
	state[StateKeys.FACTION_ACTION_POINTS][previous] = store.action_points
	store.action_points = int(state[StateKeys.FACTION_ACTION_POINTS].get(faction, 3))
	state[StateKeys.PLAYER_FACTION] = faction
	store._save()
	return true


func step(adapter: Node = null) -> void:
	var feedback_before := Feedback.snapshot(self)
	urgent_event = false
	state[StateKeys.TICK] += 1
	state[StateKeys.BATTLE_ROUND] = int(state.get(StateKeys.BATTLE_ROUND,state[StateKeys.TICK]-1)) + 1
	planner.begin_round(int(state[StateKeys.BATTLE_ROUND]))
	_expire_requests()
	Fate.restore(self)
	Tactical.clear_target_cache()
	Edges.day_start(self)
	var epoch: int = generation
	_deliver_reports()
	Lifecycle.maintain(self)
	Operations.residence(self)
	if not state.has(StateKeys.BATTLEFIELD): _spawn_defenders()
	Strategic.plan(self, store)
	Battlefields.prepare(self)
	_observe_all()
	if rules.get("battle_ai",{}).get("mode","active") == "active":
		UnitBrain.communicate(self)
		OfficerBrain.deliberate(self,adapter)
	if not state[StateKeys.CORPS].is_empty():
		await Corps.plan(self, adapter)
		if generation != epoch: return
	Fate.restore(self)
	_update_operations()
	var ai_mode := str(rules.get("battle_ai",{}).get("mode","active"))
	if ai_mode in ["active","shadow"]: UnitBrain.decide(self,adapter,ai_mode == "shadow")
	var contexts: Array = []
	for army in active_armies():
		if str(army.get("autonomy", {}).get("stance", "obey")) != "obey" and int(army.get("autonomy", {}).get("until", 0)) > int(state[StateKeys.TICK]): continue
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
			# 模型答案在提交点到达时，即使态势未变也要在今天落地或作废。
			if _should_reconsider(army, context, adapter, key) or planner.ready.has("army:" + str(army["id"])):
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
			var proposal: Dictionary = planner.take(key, signature, int(state[StateKeys.TICK]), context)
			outputs[str(context["request_id"])] = proposal["result"] if not proposal.is_empty() else Policy.choose(context)
			if str(context["officer"]["id"]).begins_with("militia:") or planner.has_pending(key): continue
			requests.append(context)
			signatures[key] = signature
		# 批次槽位被军团占住时 submit 会排队而不是丢弃；此处只兜住真正的失败。
		if not planner.submit(requests, adapter, signatures, outputs):
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
		var army: Dictionary = state[StateKeys.ARMIES].get(context["army_id"], {})
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
			army["operation"]["plan_until"] = int(state[StateKeys.TICK]) + 3
			army["last_decision"] = int(state[StateKeys.TICK])
			# 请求真正落地后才登记 decision_key；否则未发出的请求会被当成已决策。
			army["decision_key"] = str(context.get("decision_key", army.get("decision_key", "")))
			army["decision_role"] = str(army["operation"].get("role", ""))
			army["decision_flanked"] = bool(context["army"].get("contact", {}).get("flanked", false))
			var record: Dictionary = {"request_id": context["request_id"], "tick": state[StateKeys.TICK], "army_id": army["id"], "candidate_id": result.get("candidate_id", ""), "action": validated["action"].duplicate(true), "reason_summary": army["last_reason"], "source": result.get("source", "baseline"), "model": str(adapter.model) if adapter != null else "", "rules_version": rules["version"], "prompt_version": 5, "policy_version": Policy.version(), "weights_version": Policy.weights().get("version", 0), "score_breakdown": result.get("score_breakdown", {}), "vetoed": bool(result.get("vetoed", false)), "fallback_reason": result.get("fallback_reason", ""), "observation": context.duplicate(true)}
			state[StateKeys.DECISIONS].append(record)
			if not army.has("decision_history"): army["decision_history"] = []
			army["decision_history"].append(record)
			_evaluate_dissent(army, context, record)
	while state[StateKeys.DECISIONS].size() > 160:
		state[StateKeys.DECISIONS].pop_front()
	# Immediate self-defence must run after proposals, so a routine hold decision
	# cannot overwrite the response to the previous day's arrow fire.
	if state.has(StateKeys.BATTLEFIELD) and ai_mode != "active":
		for corps in state[StateKeys.CORPS].values(): preload("res://scripts/war/battle/ranged_pressure.gd").respond(self, corps)
	var motions: Dictionary = _move_all()
	_resolve_contacts(motions)
	if not state[StateKeys.CORPS].is_empty(): Corps.logistics(self)
	Fortifications.fire(self)
	_resolve_sieges()
	for army in state[StateKeys.ARMIES].values():
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
	state[StateKeys.RNG_STATE] = str(rng.state)
	state[StateKeys.DISSENT_STATE] = int(state.get(StateKeys.DISSENT_STATE, 0))


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


## ── 粮草与兵员：转发到 CampaignLogistics（campaign_logistics.gd）
func supply_enabled() -> bool:
	return Logistics.supply_enabled(self)
func daily_food(army: Dictionary) -> float:
	return Logistics.daily_food(self, army)
func food_days(army: Dictionary) -> float:
	return Logistics.food_days(self, army)
func ledger(army: Dictionary) -> Dictionary:
	return Logistics.ledger(self, army)
func _upkeep() -> void:
	Logistics._upkeep(self)
func _sync_inventory(city: Dictionary) -> void:
	Logistics._sync_inventory(self, city)
func recruit_units(city: Dictionary, count: int) -> void:
	Logistics.recruit_units(self, city, count)


## ── 军报：转发到 CampaignReports（campaign_reports.gd）
func _report(army: Dictionary, kind: String, message: String, urgent: bool, event_key: String = "") -> void:
	Reports._report(self, army, kind, message, urgent, event_key)
func _deliver_reports() -> void:
	Reports._deliver_reports(self)
func visible_reports() -> Array:
	return Reports.visible_reports(self)
func has_pending_urgent_report() -> bool:
	return Reports.has_pending_urgent_report(self)
func player_markers() -> Array:
	return Reports.player_markers(self)
func request_battle_summary(army_id: String = "") -> Dictionary:
	return Reports.request_battle_summary(self, army_id)
func _summarize_finished_battles() -> void:
	Reports._summarize_finished_battles(self)
func _casualty_summary(members: Array) -> String:
	return Reports._casualty_summary(self, members)


## ── 军令与违令：转发到 CampaignOrders（campaign_orders.gd）
func orders_for(army: Dictionary) -> Dictionary:
	return Orders.orders_for(self, army)
func filter_candidates(candidates: Array, orders: Dictionary) -> Array:
	return Orders.filter_candidates(self, candidates, orders)
func filter_commander_candidates(candidates: Array, orders: Dictionary) -> Array:
	return Orders.filter_commander_candidates(self, candidates, orders)
func command_army(id: String, changes: Dictionary = {}, withdraw: bool = false) -> Dictionary:
	return Orders.command_army(self, id, changes, withdraw)
func resolve_request(army_id: String, approve: bool) -> Dictionary:
	return Orders.resolve_request(self, army_id, approve)
func _record_approved(army: Dictionary, request: Dictionary, action: Dictionary) -> void:
	Orders._record_approved(self, army, request, action)
func _expire_requests() -> void:
	Orders._expire_requests(self)
func _evaluate_dissent(army: Dictionary, context: Dictionary, record: Dictionary) -> void:
	Orders._evaluate_dissent(self, army, context, record)
func _append_dissent(army: Dictionary, entry: Dictionary) -> void:
	Orders._append_dissent(self, army, entry)
func _has_independent_action(army: Dictionary) -> bool:
	return Orders._has_independent_action(self, army)


## ── 出征与动员：转发到 CampaignDispatch（campaign_dispatch.gd）
func available_officers(faction: String) -> Array:
	return Dispatch.available_officers(self, faction)
func preview_dispatch(home: String, target: String, officer_id: String, defending: bool = false, troop_count: int = 0) -> Dictionary:
	return Dispatch.preview_dispatch(self, home, target, officer_id, defending, troop_count)
func dispatch(home: String, target: String, officer_id: String, companions: Array = [], as_corps: bool = false, troop_count: int = 0) -> Dictionary:
	return Dispatch.dispatch(self, home, target, officer_id, companions, as_corps, troop_count)
func _mobilize(preview: Dictionary) -> Dictionary:
	return Dispatch._mobilize(self, preview)
func _spawn_defenders() -> void:
	Dispatch._spawn_defenders(self)


## ── 观察与决策上下文：转发到 CampaignContext（campaign_context.gd）
func city_intel(node: String) -> Dictionary:
	return Context.city_intel(self, node)
func enemy_intel(enemy: Dictionary) -> Dictionary:
	return Context.enemy_intel(self, enemy)
func player_city_intel(node: String) -> Dictionary:
	return Context.player_city_intel(self, node)
func player_has_city_access(node: String) -> bool:
	return Context.player_has_city_access(self, node)
func _observe_all() -> void:
	Context._observe_all(self)
func _update_operations() -> void:
	Context._update_operations(self)
func _near_battle(a: Dictionary, b: Dictionary) -> bool:
	return Context._near_battle(self, a, b)
func _support_context(army: Dictionary) -> Dictionary:
	return Context._support_context(self, army)
func _observed_contact(army: Dictionary) -> Dictionary:
	return Context._observed_contact(self, army)
func context_for(army: Dictionary) -> Dictionary:
	return Context.context_for(self, army)
func _add_candidate(list: Array, id: String, action: Dictionary, description: String, extra: Dictionary = {}) -> void:
	Context._add_candidate(self, list, id, action, description, extra)
func validate_decision(context: Dictionary, result: Dictionary) -> Dictionary:
	return Context.validate_decision(self, context, result)
func _should_reconsider(army: Dictionary, context: Dictionary, adapter, key: String) -> bool:
	return Context._should_reconsider(self, army, context, adapter, key)
func _decision_key(context: Dictionary) -> String:
	return Context._decision_key(self, context)


## ── 行军与接敌结算：转发到 CampaignContactResolver（campaign_contact_resolver.gd）
func _terrain(node: String) -> String:
	return Contacts._terrain(self, node)
func _move_all() -> Dictionary:
	return Contacts._move_all(self)
func _edge_coordinate(location: Dictionary) -> float:
	return Contacts._edge_coordinate(self, location)
func _contact(a: Dictionary, b: Dictionary, motions: Dictionary) -> bool:
	return Contacts._contact(self, a, b, motions)
func _resolve_contacts(motions: Dictionary) -> void:
	Contacts._resolve_contacts(self, motions)
func _battle_contact(attacker: Dictionary, defender: Dictionary, melee: bool = true) -> void:
	Contacts._battle_contact(self, attacker, defender, melee)


## ── 战果：转发到 CampaignOutcomes（campaign_outcomes.gd）
func _resolve_sieges() -> void:
	Outcomes._resolve_sieges(self)
func _capture_city(army: Dictionary, besiegers: Array, node: String, city: Dictionary) -> void:
	Outcomes._capture_city(self, army, besiegers, node, city)
func _fate_enemy(army: Dictionary) -> Dictionary:
	return Outcomes._fate_enemy(self, army)
func _check_rout(army: Dictionary) -> void:
	Outcomes._check_rout(self, army)
func _check_leader_lost() -> void:
	Outcomes._check_leader_lost(self)
func _battle_victory(army: Dictionary) -> void:
	Outcomes._battle_victory(self, army)
func _remember_win(army: Dictionary, cause: String) -> void:
	Outcomes._remember_win(self, army, cause)
func _remember_loss(army: Dictionary, cause: String) -> void:
	Outcomes._remember_loss(self, army, cause)
func _nearest_enemy_id(army: Dictionary) -> String:
	return Outcomes._nearest_enemy_id(self, army)


## ── 行动执行与收束：转发到 CampaignActions（campaign_actions.gd）
func _execute(army: Dictionary, action: Dictionary) -> void:
	Actions._execute(self, army, action)
func _start_return(army: Dictionary) -> void:
	Actions._start_return(self, army)
func _finish(army: Dictionary, outcome: String) -> void:
	Actions._finish(self, army, outcome)
