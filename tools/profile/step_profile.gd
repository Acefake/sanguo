extends SceneTree
## 战役 step() 分段剖析（只用于测量，不进游戏代码路径）。
##
##   godot --headless --path . --script res://tools/profile/step_profile.gd -- [--days=30] [--rounds=3] [--modes=rules,mock]
##       [--scenario=res://data/war/perf_scenarios/contact_demo.json]
##
## 每一轮、每种模式各开两局演示剧本：先用原版 CampaignState 跑 DAYS 日记每日哈希和总耗时，再用 ProfiledCampaign
## 跑同样的日数，逐日比对 export_state 的哈希。ProfiledCampaign.step() 是 campaign_state.gd 里 step() 的逐行副本，
## 只在各阶段之间插了计时；哈希只要有一天不同就打印 PROFILE_DRIFT 并以退出码 1 结束，说明副本已和原版脱节，需要重抄。
## 每日一行 `PROFILE {...}`：阶段耗时（微秒，独占、相加等于 step 总耗时）、跨阶段累计（包含式，和阶段有重叠）、
## 当日规模（部队数、军团数、战场、接敌、军报等），以及 step 之外 _save 同款序列化的耗时。tools/profile/summarize.py 汇总。
## mock 模式用与 tests/agents/step_latency_validation.gd 相同的 30 秒替身。
## --scenario 在演示剧本上追加剖析剧本的开局动作（见 scenario_setup.gd），日数默认取剧本的 days；
## PLAIN 行带每日 export_state 哈希，可作该剧本的回归基线。

const Store = preload("res://scripts/core/game_state.gd")
const StateKeys = preload("res://scripts/war/campaign/war_state_keys.gd")
const ScenarioSetup = preload("res://tools/profile/scenario_setup.gd")

var days := 30
var rounds := 3
var modes: Array = ["rules", "mock"]
var drifted := false
var scenario: Dictionary = {}


## 分阶段计时的 CampaignState。step() 与原版逐行一致，只多了 _lap()。
class ProfiledCampaign extends "res://scripts/war/campaign/campaign_state.gd":
	## 本次 step 的独占阶段耗时（微秒），按首次出现排序。
	var phases := {}
	## 本次 step 内被包住的函数累计耗时（微秒，包含式）与调用次数。
	var inclusive := {}
	var calls := {}
	## 本次 step 里 route() 的不同（势力，起点，终点）组合，衡量同日重复寻路有多少。
	var route_keys := {}
	var _mark := 0
	var _depth := {}

	func _lap(phase: String) -> void:
		var now := Time.get_ticks_usec()
		phases[phase] = int(phases.get(phase, 0)) + now - _mark
		_mark = now

	func _enter(name: String) -> int:
		_depth[name] = int(_depth.get(name, 0)) + 1
		return Time.get_ticks_usec()

	func _leave(name: String, started: int) -> void:
		_depth[name] -= 1
		calls[name] = int(calls.get(name, 0)) + 1
		if int(_depth[name]) == 0: inclusive[name] = int(inclusive.get(name, 0)) + Time.get_ticks_usec() - started

	func context_for(army: Dictionary) -> Dictionary:
		var t := _enter("context_for")
		var result := super.context_for(army)
		_leave("context_for", t)
		return result

	func _decision_key(context: Dictionary) -> String:
		var t := _enter("_decision_key")
		var result := super._decision_key(context)
		_leave("_decision_key", t)
		return result

	func _deliver_reports() -> void:
		var t := _enter("_deliver_reports")
		super._deliver_reports()
		_leave("_deliver_reports", t)

	func _observe_all() -> void:
		var t := _enter("_observe_all")
		super._observe_all()
		_leave("_observe_all", t)

	func _report(army: Dictionary, kind: String, message: String, urgent: bool, event_key: String = "") -> void:
		var t := _enter("_report")
		super._report(army, kind, message, urgent, event_key)
		_leave("_report", t)

	func _battle_contact(attacker: Dictionary, defender: Dictionary, melee: bool = true) -> void:
		var t := _enter("_battle_contact")
		super._battle_contact(attacker, defender, melee)
		_leave("_battle_contact", t)

	func validate_decision(context: Dictionary, result: Dictionary) -> Dictionary:
		var t := _enter("validate_decision")
		var out := super.validate_decision(context, result)
		_leave("validate_decision", t)
		return out

	func preview_dispatch(home: String, target: String, officer_id: String, defending: bool = false, troop_count: int = 0) -> Dictionary:
		var t := _enter("preview_dispatch")
		var out := super.preview_dispatch(home, target, officer_id, defending, troop_count)
		_leave("preview_dispatch", t)
		return out

	func dispatch(home: String, target: String, officer_id: String, companions: Array = [], as_corps: bool = false, troop_count: int = 0) -> Dictionary:
		var t := _enter("dispatch")
		var out := super.dispatch(home, target, officer_id, companions, as_corps, troop_count)
		_leave("dispatch", t)
		return out

	func available_officers(faction: String) -> Array:
		var t := _enter("available_officers")
		var out := super.available_officers(faction)
		_leave("available_officers", t)
		return out

	func route(faction: String, start: String, finish: String) -> Dictionary:
		route_keys[faction + ">" + start + ">" + finish] = true
		var t := _enter("route")
		var out := super.route(faction, start, finish)
		_leave("route", t)
		return out

	func active_armies(faction: String = "") -> Array:
		var t := _enter("active_armies")
		var out := super.active_armies(faction)
		_leave("active_armies", t)
		return out

	func step(adapter: Node = null) -> void:
		phases = {}
		inclusive = {}
		calls = {}
		_depth = {}
		route_keys = {}
		_mark = Time.get_ticks_usec()
		var feedback_before := Feedback.snapshot(self)
		_lap("feedback_snapshot")
		urgent_event = false
		state[StateKeys.TICK] += 1
		state[StateKeys.BATTLE_ROUND] = int(state.get(StateKeys.BATTLE_ROUND,state[StateKeys.TICK]-1)) + 1
		planner.begin_round(int(state[StateKeys.BATTLE_ROUND]))
		_lap("scheduler_begin_round")
		_expire_requests()
		Fate.restore(self)
		Tactical.clear_target_cache()
		Edges.day_start(self)
		var epoch: int = generation
		_lap("day_start")
		_deliver_reports()
		_lap("reports_deliver")
		Lifecycle.maintain(self)
		Operations.residence(self)
		if not state.has(StateKeys.BATTLEFIELD): _spawn_defenders()
		_lap("lifecycle_residence_defenders")
		Strategic.plan(self, store)
		_lap("strategic_plan")
		Battlefields.prepare(self)
		_lap("battlefields_prepare")
		_observe_all()
		_lap("observe")
		if rules.get("battle_ai",{}).get("mode","active") == "active":
			UnitBrain.communicate(self)
			OfficerBrain.deliberate(self,adapter)
		_lap("brains_communicate_deliberate")
		if not state[StateKeys.CORPS].is_empty():
			await Corps.plan(self, adapter)
			if generation != epoch: return
		_lap("corps_plan")
		Fate.restore(self)
		_update_operations()
		var ai_mode := str(rules.get("battle_ai",{}).get("mode","active"))
		if ai_mode in ["active","shadow"]: UnitBrain.decide(self,adapter,ai_mode == "shadow")
		_lap("operations_unit_decide")
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
		phases["decision_contexts_n"] = contexts.size()
		_lap("army_contexts")
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
		_lap("army_policy_choose")
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
		_lap("army_commit")
		# Immediate self-defence must run after proposals, so a routine hold decision
		# cannot overwrite the response to the previous day's arrow fire.
		if state.has(StateKeys.BATTLEFIELD) and ai_mode != "active":
			for corps in state[StateKeys.CORPS].values(): preload("res://scripts/war/battle/ranged_pressure.gd").respond(self, corps)
		_lap("ranged_pressure")
		var motions: Dictionary = _move_all()
		_lap("march_move_all")
		_resolve_contacts(motions)
		_lap("contacts_resolve")
		if not state[StateKeys.CORPS].is_empty(): Corps.logistics(self)
		_lap("corps_logistics")
		Fortifications.fire(self)
		_lap("fortifications_fire")
		_resolve_sieges()
		_lap("sieges")
		for army in state[StateKeys.ARMIES].values():
			if army.has("battlefield_id"): army["last_battlefield_id"] = army["battlefield_id"]
		if not store.battle_test: Battlefields.cleanup(self)
		_lap("battlefields_cleanup")
		Lifecycle.maintain(self)
		_lap("lifecycle")
		_upkeep()
		_lap("supply_upkeep")
		if ai_mode == "active":
			for army in active_armies(): TacticalPlan.after_round(self,army)
			for army in active_armies(): Experience.tactical_result(self,army)
		_lap("tactical_after_round_experience")
		_observe_all()
		_lap("observe")
		_deliver_reports()
		_lap("reports_deliver")
		Experience.decay(self)
		Operations.result(self)
		preload("res://scripts/war/battle/battle_objectives.gd").update(self)
		_lap("experience_operations_objectives")
		Feedback.record_day(self, feedback_before)
		_lap("feedback_record")
		ReportPolicy.observe(self)
		_summarize_finished_battles()
		_deliver_reports()
		_lap("reports_policy_summaries")
		state[StateKeys.RNG_STATE] = str(rng.state)
		state[StateKeys.DISSENT_STATE] = int(state.get(StateKeys.DISSENT_STATE, 0))
		_lap("rng_state")


## 给决策调度计时（同 tests/agents/step_latency_validation.gd 的 TimedScheduler）。
class TimedScheduler extends "res://scripts/agents/decision_scheduler.gd":
	var usec := 0
	func begin_round(round_now: int) -> void:
		var started := Time.get_ticks_usec()
		super.begin_round(round_now)
		usec += Time.get_ticks_usec() - started
	func submit(contexts: Array, adapter: Node, signatures: Dictionary, defaults: Dictionary = {}) -> bool:
		var started := Time.get_ticks_usec()
		var accepted := super.submit(contexts, adapter, signatures, defaults)
		usec += Time.get_ticks_usec() - started
		return accepted
	func take(key: String, signature: String, tick: int, context_now: Dictionary = {}) -> Dictionary:
		var started := Time.get_ticks_usec()
		var proposal := super.take(key, signature, tick, context_now)
		usec += Time.get_ticks_usec() - started
		return proposal


## 固定延迟 30 秒、从候选里取第 2 名的模型替身（同 step_latency_validation）。
class MockAdapter extends Node:
	var endpoint := "mock://fixed-delay"
	var model := "mock"
	var enabled := true
	var metrics := {"calls": 0, "fallbacks": 0}
	var last_status := ""
	var delay := 30.0
	func supports_background_decisions() -> bool: return true
	func can_request_model(_context: Dictionary) -> bool: return true
	func choose_batch(contexts: Array) -> Dictionary:
		metrics["calls"] += contexts.size()
		await get_tree().create_timer(delay).timeout
		var outputs := {}
		for context in contexts:
			var candidates: Array = context.get("candidates", [])
			if not candidates.is_empty(): outputs[context["request_id"]] = {"candidate_id": candidates[mini(1, candidates.size() - 1)]["id"], "reason_summary": "替身", "source": "model"}
		return outputs


func _initialize() -> void: call_deferred("_run")


func _run() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--days="): days = int(arg.get_slice("=", 1))
		elif arg.begins_with("--rounds="): rounds = int(arg.get_slice("=", 1))
		elif arg.begins_with("--modes="): modes = Array(arg.get_slice("=", 1).split(","))
		elif arg.begins_with("--scenario="):
			scenario = ScenarioSetup.load_spec(arg.get_slice("=", 1))
			if scenario.is_empty(): quit(1); return
			days = int(scenario.get("days", days))
	root.get_node("ModelQueue").set_log_path("user://step_profile_decisions.jsonl")
	for round_index in rounds:
		for mode in modes:
			var adapter: Node = null
			if mode == "mock":
				adapter = MockAdapter.new()
				root.add_child(adapter)
			var hashes := await _plain(adapter, round_index, mode)
			if adapter != null:
				adapter.queue_free()
				adapter = MockAdapter.new()
				root.add_child(adapter)
			await _profiled(adapter, round_index, mode, hashes)
			if adapter != null: adapter.queue_free()
	print("PROFILE_DONE drift=%s" % drifted)
	quit(1 if drifted else 0)


func _sandbox(war) -> Node:
	var sandbox := Store.new()
	sandbox.persist_enabled = false
	if war != null: sandbox.war = war
	sandbox._load_demo()
	if not scenario.is_empty() and not ScenarioSetup.apply(sandbox, scenario): drifted = true
	return sandbox


func _timed_planner(war) -> TimedScheduler:
	var timed := TimedScheduler.new()
	timed.alive = war.planner.alive
	war.planner = timed
	return timed


## 原版 CampaignState：每日哈希与 step 总耗时（用来核对副本，也用来估计计时本身的开销）。
func _plain(adapter: Node, round_index: int, mode: String) -> Array:
	var sandbox := _sandbox(null)
	var war = sandbox.war
	var timed := _timed_planner(war)
	var hashes: Array = []
	for day in days:
		var started := Time.get_ticks_usec()
		await war.step(adapter)
		var elapsed := Time.get_ticks_usec() - started
		hashes.append(JSON.stringify(war.export_state()).sha256_text())
		print("PLAIN ", JSON.stringify({"round": round_index, "mode": mode, "day": day + 1, "step_us": elapsed, "hash": hashes[-1]}))
	timed.clear()
	sandbox.free()
	return hashes


func _profiled(adapter: Node, round_index: int, mode: String, hashes: Array) -> void:
	var war := ProfiledCampaign.new()
	var sandbox := _sandbox(war)
	var timed := _timed_planner(war)
	for day in days:
		var reports_before: int = war.state[StateKeys.REPORTS].size()
		var decisions_before: int = war.state[StateKeys.DECISIONS].size()
		var scheduler_before := timed.usec
		var frame := Engine.get_process_frames()
		var started := Time.get_ticks_usec()
		await war.step(adapter)
		var elapsed := Time.get_ticks_usec() - started
		var suspended := Engine.get_process_frames() != frame
		var t0 := Time.get_ticks_usec()
		var exported: Dictionary = war.export_state()
		var t1 := Time.get_ticks_usec()
		var payload := {"version": 3, "year": sandbox.year, "month": sandbox.month, "day": sandbox.day, "action_points": sandbox.action_points, "places": sandbox.scenario.get("places", {}), "chronicles": sandbox.chronicles, "war": exported}
		var text := JSON.stringify(payload, "\t")
		var t2 := Time.get_ticks_usec()
		var digest := JSON.stringify(exported).sha256_text()
		if digest != hashes[day]:
			drifted = true
			print("PROFILE_DRIFT round=%d mode=%s day=%d" % [round_index, mode, day + 1])
		var tactical := 0
		var engaged := 0
		for army in war.active_armies():
			if army.has("tactical"): tactical += 1
			if not army.get("contact", {}).is_empty(): engaged += 1
		var phases: Dictionary = war.phases.duplicate()
		var contexts_n: int = phases.get("decision_contexts_n", 0)
		phases.erase("decision_contexts_n")
		print("PROFILE ", JSON.stringify({
			"round": round_index, "mode": mode, "day": day + 1, "step_us": elapsed, "suspended": suspended,
			"phases": phases, "inclusive": war.inclusive, "calls": war.calls, "scheduler_us": timed.usec - scheduler_before, "route_unique": war.route_keys.size(),
			"save_export_us": t1 - t0, "save_stringify_us": t2 - t1, "save_bytes": text.length(),
			"armies": war.active_armies().size(), "corps": war.state[StateKeys.CORPS].size(), "tactical": tactical, "engaged": engaged,
			"battlefield": war.state.has(StateKeys.BATTLEFIELD), "battlefields": war.state.get(StateKeys.BATTLEFIELDS, {}).size(),
			"sieges": war.state[StateKeys.SIEGES].size(), "decision_contexts": contexts_n,
			"reports_new": war.state[StateKeys.REPORTS].size() - reports_before, "decisions_new": war.state[StateKeys.DECISIONS].size() - decisions_before,
		}))
	timed.clear()
	sandbox.free()
