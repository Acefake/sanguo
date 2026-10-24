extends RefCounted

const Plan = preload("res://scripts/agents/tactical_plan.gd")
const Candidates = preload("res://scripts/agents/tactical_candidates.gd")
const Evaluator = preload("res://scripts/agents/tactical_evaluator.gd")
const Tactical = preload("res://scripts/war/tactical_battlefield.gd")
const Combat = preload("res://scripts/war/combat_system.gd")
const Forecast = preload("res://scripts/agents/forecast.gd")
const Roles = preload("res://scripts/war/troop_roles.gd")
const Coordination = preload("res://scripts/war/corps_coordination.gd")
const Commit = preload("res://scripts/agents/decision_commit.gd")

static var ask_stats: Dictionary = {}

static func friend_view(war, army: Dictionary, contact: Dictionary = {}) -> Dictionary:
	var ai: Dictionary = army.get("battle_ai",{})
	var cell := int(army.get("tactical",{}).get("cell",-1))
	if contact.is_empty(): contact = war._observed_contact(army)
	var role := str(army.get("operation",{}).get("role",""))
	var available: bool = role != "reserve" or ai.get("plan",{}).get("template","") == "reserve_reinforce"
	var recovery_pressure: bool = (float(army["fatigue"]) >= 80 or ai.get("local_state","active") != "active") and int(army.get("last_enemy_tick",-100)) >= int(war.state["tick"])-1
	return {"id":army["id"],"status":army["status"],"cell":cell,"strength":Combat.strength(army),"role":role,"returning":army["returning"],"local_state":ai.get("local_state","active"),"needs_support":float(army["organization"]) < 45 or float(army["morale"]) < 40 or int(contact.get("adjacent_enemies",0)) >= 2 or recovery_pressure,"can_support":available and not army["returning"] and ai.get("local_state","active") == "active" and float(army["organization"]) >= 30 and float(army["morale"]) >= 30 and war.orders_for(army)["engage"] and war.ready(army),"observed_round":war.state["battle_round"],"delivered_round":war.state["battle_round"],"confidence":1.0,"source":"direct_contact","intent":ai.get("plan",{}).duplicate(true)}

# Shared read-only material is filtered separately for every observer.
static func freeze(war) -> Dictionary:
	var frozen := {"armies":war.active_armies(),"friends":{},"contacts":{},"boards":{}}
	for army in frozen["armies"]:
		if not army.has("tactical"): continue
		var contact: Dictionary = war._observed_contact(army)
		frozen["contacts"][army["id"]] = contact
		frozen["friends"][army["id"]] = friend_view(war,army,contact)
	return frozen

static func communicate(war) -> void:
	var round_now := int(war.state["battle_round"])
	var pending: Array = war.state.get("battle_ai_messages",[])
	var remaining: Array = []
	for message in pending:
		var receiver: Dictionary = war.state["armies"].get(message["to"],{})
		if receiver.is_empty() or receiver["status"] == "ended": continue
		if int(message["delivery"]) > round_now: remaining.append(message); continue
		var ai := Plan.ensure(war,receiver)
		var view: Dictionary = message["payload"].duplicate(true)
		view["delivered_round"] = round_now
		view["source"] = "delivered_report"
		ai["reports"][message["from"]] = view
		for sight in message.get("enemies",[]):
			var existing: Dictionary = receiver["intel"]["enemies"].get(sight["id"],{})
			if int(existing.get("observed_at",-1)) < int(sight["observed_at"]):
				var delivered: Dictionary = sight.duplicate(true)
				delivered["delivered_round"] = round_now
				delivered["source"] = "delivered_report"
				receiver["intel"]["enemies"][sight["id"]] = delivered
	var armies: Array = war.active_armies().filter(func(a): return a.has("tactical") and war.ready(a))
	for army in armies:
		var ai := Plan.ensure(war,army)
		for id in ai["reports"].keys():
			if round_now - int(ai["reports"][id]["observed_round"]) > 4: ai["reports"].erase(id)
		for friend in armies:
			if friend["id"] == army["id"] or friend["faction"] != army["faction"] or Tactical.distance(army,friend) >= 10000: continue
			var same_corps: bool = army.has("corps_id") and army.get("corps_id") == friend.get("corps_id")
			var gap := Tactical.distance(army,friend)
			if not same_corps and gap > 7: continue
			if gap <= 3: continue
			if remaining.any(func(m): return m["to"] == army["id"] and m["from"] == friend["id"]): continue
			if remaining.size() >= 2048: break
			var sights: Array = friend["intel"]["enemies"].values().filter(func(e): return int(e.get("observed_at",-1)) == int(war.state["tick"])).duplicate(true)
			remaining.append({"to":army["id"],"from":friend["id"],"delivery":round_now + (1 if same_corps else 2),"payload":friend_view(war,friend),"enemies":sights})
	war.state["battle_ai_messages"] = remaining

static func context(war, army: Dictionary, frozen: Dictionary = {}) -> Dictionary:
	var timing_start := Time.get_ticks_usec()
	if frozen.is_empty(): frozen = freeze(war)
	var ai: Dictionary = army.get("battle_ai",{})
	var tactical: Dictionary = army["tactical"]
	var raw_board := Tactical.board_for(war,army)
	var board_key := str(raw_board.get("battle_id",""))+":"+str(army["faction"])
	if not frozen["boards"].has(board_key):
		var movement_board := Tactical.Fort.movement_board(war,raw_board,str(army["faction"]))
		var clean := {}
		for field in ["battle_id","anchor","center_column","center_row","min_column","max_column","min_row","max_row","blocked","objectives","control_point","fortifications","sides","scenario_id"]:
			if movement_board.has(field): clean[field] = movement_board[field]
		frozen["boards"][board_key] = clean.duplicate(true)
	var board: Dictionary = frozen["boards"][board_key]
	var own := {"cell":int(tactical["cell"]),"strength":Combat.strength(army),"units":army["units"].duplicate(true),"initial_strength":army["initial_strength"],"morale":army["morale"],"organization":army["organization"],"fatigue":army["fatigue"],"training":army["training"],"equipment":army["equipment"],"skills":army["skills"].duplicate(true),"battle_traits":army.get("battle_traits",[]).duplicate(),"siege_engines":army.get("siege_engines",0),"withdraw_preparation":tactical.get("withdraw_preparation",0),"blocked_days":tactical.get("blocked_days",0),"movement_credit":tactical.get("movement_credit",0),"contact":frozen["contacts"][army["id"]].duplicate(),"can_act":not army["returning"] and army["status"] != "ended","attack_range":Tactical.attack_range(army),"kind":Roles.kind(army),"mobility":Roles.mobility(army,Tactical.terrain_class(int(tactical["cell"])),war.rules)}
	if war.supply_enabled(): own["grain_days"] = war.food_days(army)
	var recent_attacker: Dictionary = army["intel"]["enemies"].get(army.get("last_enemy_id",""),{})
	own["under_fire"] = int(army.get("last_enemy_tick",-100)) >= int(war.state["tick"])-1 and int(recent_attacker.get("tactical_cell",-1)) >= 0 and Tactical.cell_distance(int(own["cell"]),int(recent_attacker.get("tactical_cell",-1))) == 2
	var allies: Array = []
	for friend in frozen["armies"]:
		if friend["faction"] == army["faction"] and friend["id"] != army["id"] and friend.has("tactical") and Tactical.distance(army,friend) <= 3:
			allies.append(frozen["friends"][friend["id"]].duplicate(true))
	for report in ai.get("reports",{}).values():
		if not allies.any(func(a): return a["id"] == report["id"]): allies.append(report.duplicate(true))
	allies.sort_custom(func(a,b): return str(a["id"]) < str(b["id"]))
	var enemies: Array = []
	var known: Dictionary = army["intel"]["enemies"].duplicate(true)
	for friend in frozen["armies"]:
		if friend["faction"] != army["faction"] or friend["id"] == army["id"] or not friend.has("tactical") or Tactical.distance(army,friend) > 3: continue
		for sight in friend["intel"]["enemies"].values():
			if int(sight.get("observed_at",-1)) == int(war.state["tick"]) and not known.has(sight["id"]):
				known[sight["id"]] = sight.duplicate(true)
				known[sight["id"]]["source"] = "direct_ally_report"
	for sight in known.values():
		var record: Dictionary = sight.duplicate(true)
		record["cell"] = int(record.get("tactical_cell",-1))
		record["observed_round"] = int(record.get("observed_at",0))
		record["delivered_round"] = int(record.get("delivered_round",record["observed_round"]))
		record["confidence"] = 1.0
		record["source"] = record.get("source","local_observation")
		enemies.append(record)
	enemies.sort_custom(func(a,b): return Tactical.cell_distance(int(own["cell"]),int(a.get("cell",-1))) < Tactical.cell_distance(int(own["cell"]),int(b.get("cell",-1))) if Tactical.cell_distance(int(own["cell"]),int(a.get("cell",-1))) != Tactical.cell_distance(int(own["cell"]),int(b.get("cell",-1))) else str(a["id"]) < str(b["id"]))
	var task_source: Dictionary = army.get("corps_task",{})
	var role := str(army.get("operation",{}).get("role",tactical.get("role","main_attack")))
	var anchor := int(task_source.get("cell", -1))
	if role == "raid_rear" and task_source.get("stage","") == "attack": anchor = -1
	var stop := 0
	if anchor < 0 and tactical.has("siege_slot"): anchor = int(tactical["siege_slot"])
	if anchor < 0 and board.has("control_point") and role not in ["reserve","command"]: anchor = int(board["control_point"]["cell"]); stop = 1
	var corps: Dictionary = war.state["corps"].get(army.get("corps_id",""),{})
	if role == "regroup":
		for friend in allies:
			if friend["id"] == corps.get("root_id",""): anchor = int(friend["cell"]); stop = 1
	var auth := Plan.authority(war,army)
	# Attack formations may approach an opened gate/breach; defensive duties stay put.
	if not auth["must_hold_objective"] and role in ["main_attack", "flank", "raid_rear"] and army.get("mission_type", "") == "capture":
		var entry_goal: int = Tactical.siege_entry_goal(war, army, board)
		if entry_goal >= 0:
			anchor = entry_goal
			stop = 0
	if auth["must_hold_objective"]: anchor = int(auth["duty_cell"])
	var contact: Dictionary = own["contact"]
	var crisis: bool = int(own["blocked_days"]) >= 2 or float(own["organization"]) < 35 or float(own["morale"]) < 30 or (own["kind"] == "archers" and int(contact["adjacent_enemies"]) > 0) or int(contact["attackers"]) >= 2
	if ai.get("local_state","") == "recovering" and (own["under_fire"] or int(contact["adjacent_enemies"]) > 0): crisis = true
	if role == "command" and not auth["must_hold_objective"]:
		var fronts: Array = allies.filter(func(a): return a.get("role","") == "main_attack" and not a.get("returning",false) and int(a.get("observed_round",-100)) >= int(war.state["battle_round"])-2)
		if not fronts.is_empty() and fronts.all(func(a): return Tactical.cell_distance(int(own["cell"]),int(a["cell"])) > 6): crisis = true
	if int(army.get("last_enemy_tick",-100)) >= int(war.state["tick"])-1 and role == "command": crisis = true
	var events: Array = []
	if crisis: events.append({"type":"safety_review","source":"own_observation"})
	if int(own["blocked_days"]) >= 2: events.append({"type":"path_blocked","rounds":own["blocked_days"]})
	var settings: Dictionary = war.Policy.weights().get("tactical",{}).duplicate(true)
	var ctx := {"schema_version":1,"level":"unit","actor_key":"unit:"+str(army["id"]),"army_id":army["id"],"officer_id":army["officer_id"],"request_id":"unit:%s:%d:%d" % [army["id"],war.state["battle_round"],int(ai.get("actor_revision",1))],"battle_id":board.get("battle_id",""),"generation":war.generation,"observation_revision":war.state["tick"],"battle_round":war.state["battle_round"],"actor_revision":int(ai.get("actor_revision",1)),"command_revision":int(ai.get("command_revision",1)),"self":own,"officer":war.roster.officers[army["officer_id"]].duplicate(true),"task":{"role":role,"anchor_cell":anchor,"stop_distance":stop,"support_id":army.get("operation",{}).get("support_id",""),"issued_round":int(task_source.get("issued_at",0)),"objective_id":army["target"]},"authority":auth,"orders":war.orders_for(army).duplicate(true),"current_plan":ai.get("plan",{}).duplicate(true),"local_state":ai.get("local_state","active"),"knowledge":{"enemies":enemies,"allies":allies,"terrain":board,"reports":[]},"coordination_view":{"confirmed_intents":allies.filter(func(a): return not a.get("intent",{}).is_empty())},"events":events,"experience":war.Experience.summary(army).duplicate(true),"supply_enabled":war.supply_enabled(),"settings":settings,"crisis":crisis,"side":Tactical.side_for(board,str(army["faction"])),"deployment_pending":corps.get("autonomous_deployment",false) and not corps.get("deployed",false),"reserve_trigger":allies.any(func(a): return a.get("needs_support",false) or (a.get("role","") == "main_attack" and a.get("returning",false))),"exchanges":{},"candidates":[]}
	var exchange_start := Time.get_ticks_usec()
	ctx["corps_id"] = army.get("corps_id",army["id"])
	ctx["faction"] = army["faction"]
	ctx["siege_approach"] = corps.get("siege_approach",false) and tactical.has("siege_slot")
	# The commander knows which physical formations still belong to the corps.
	# This is structural authority, not access to hidden opponents or distant health.
	ctx["last_line"] = role == "command" and not corps.get("units",[]).any(func(id): return id != army["id"] and war.state["armies"][id]["status"] != "ended" and not war.state["armies"][id]["returning"] and war.state["armies"][id].get("corps_task",{}).get("type","") not in ["regroup","reserve","rear_guard"])
	ctx["self"]["stats"] = army.get("stats",[]).duplicate()
	ctx["self"]["officer_id"] = army["officer_id"]
	ctx["self"]["duel_wounded"] = army.get("duel_wounded",false)
	ctx["self"]["battlefield_role"] = army.get("battlefield_role","")
	ctx["experience"]["tactical_memory"] = ai.get("memory",[]).duplicate(true)
	for note in war.state.get("officer_agents",{}).get(str(army["officer_id"]),{}).get("memory",[]):
		if note.has("template") and note.get("army_id","") != army["id"] and int(ctx["battle_round"])-int(note["round"]) <= 20: ctx["experience"]["tactical_memory"].append(note.duplicate(true))
	ctx["review_interval"] = 1 if float(ctx["officer"].get("skills",{}).get("应变",50)) >= 80 else 2 if float(ctx["officer"].get("skills",{}).get("应变",50)) >= 50 else 3
	ctx["review_now"] = int(ctx["battle_round"]) - int(ai.get("last_review_round",-10)) >= int(ctx["review_interval"])
	for enemy in enemies:
		if int(enemy.get("cell",-1)) >= 0 and Tactical.cell_distance(int(own["cell"]),int(enemy["cell"])) <= 6:
			ctx["exchanges"][enemy["id"]] = Forecast.tactical_exchange(own,enemy,war.rules,Tactical.terrain_class(int(own["cell"])))
		else: ctx["exchanges"][enemy["id"]] = {"range":Tactical.attack_range({"units":enemy.get("unit_mix_estimate",{})})}
	var candidate_start := Time.get_ticks_usec()
	ctx["candidates"] = Candidates.generate(ctx)
	ctx["timing"] = {"snapshot_us":exchange_start-timing_start,"exchange_us":candidate_start-exchange_start,"candidate_us":Time.get_ticks_usec()-candidate_start}
	if not Plan.valid(ctx,ctx["current_plan"]): ctx["crisis"] = crisis or not ctx["current_plan"].is_empty()
	if army.get("objective_complete",false) and war.orders_for(army)["after_battle"] == "hold": ctx["candidates"] = ctx["candidates"].filter(func(c): return c["canonical_plan"]["template"] == "hold_line" and c["canonical_plan"]["goal_cell"] == ctx["self"]["cell"])
	return ctx

static func signature(context: Dictionary, adapter: Node = null) -> String:
	return JSON.stringify([context["actor_key"],context["battle_id"],context["generation"],context["actor_revision"],context["command_revision"],context["crisis"],str(adapter.get("model")) if adapter != null else "",str(adapter.get("endpoint")) if adapter != null else ""])

static func model_verdict(context: Dictionary, proposal: Dictionary) -> Dictionary:
	var requested: Dictionary = proposal.get("context",{})
	var result: Dictionary = proposal.get("result",{})
	if requested.get("generation") != context["generation"] or requested.get("actor_revision") != context["actor_revision"] or requested.get("command_revision") != context["command_revision"]: return {"ok":false,"reason":"指挥或实体版本改变"}
	var old: Dictionary = {}
	for c in requested.get("candidates",[]):
		if c["id"] == result.get("candidate_id",""): old = c; break
	if old.is_empty(): return {"ok":false,"reason":"候选不属于原请求"}
	for c in context["candidates"]:
		if Plan.same(c["canonical_plan"],old["canonical_plan"]):
			var f: Dictionary = c.get("forecast",{})
			var ceiling := float({"保守":0.55,"常规":0.85,"放手":1.0}.get(context["authority"]["risk_allowance"],0.85))
			if float(f.get("risk",1.0)) > ceiling and c["canonical_plan"]["template"] != "rally": return {"ok":false,"reason":"计划超过当前风险授权"}
			return {"ok":true,"candidate_id":c["id"]}
	return {"ok":false,"reason":"目标、位置或计划前提已经失效"}

static func decide(war, adapter: Node = null, shadow: bool = false) -> void:
	var started := Time.get_ticks_usec()
	var contexts: Array = []
	var frozen := freeze(war)
	for army in war.active_armies():
		var independent: Dictionary = army.get("autonomy", {})
		if independent.get("stance", "obey") != "obey" and int(independent.get("until", -1)) > int(war.state["tick"]): continue
		if not army.has("tactical") or not war.ready(army) or army["returning"] or Combat.strength(army) <= 0 or army.get("commander_unavailable",false): continue
		if not shadow:
			var ai := Plan.ensure(war,army)
			if not ai.has("duty_cell"): ai["duty_cell"] = army["tactical"]["cell"]
		contexts.append(context(war,army,frozen))
	var proposals := {}
	var context_done := Time.get_ticks_usec()
	var requests: Array = []
	var signatures := {}
	for ctx in contexts:
		var local := Evaluator.choose(ctx)
		var key := str(ctx["actor_key"])
		var ai: Dictionary = war.state["armies"][ctx["army_id"]].get("battle_ai",{})
		if not shadow:
			var proposal: Dictionary = war.planner.take(key,signature(ctx,adapter),int(ctx["battle_round"]))
			# Replay uses recorded proposals and their exact adoption boundary.
			for recorded in war.state.get("battle_ai_replay",[]):
				if recorded["actor_key"] == key and int(recorded["adopted_round"]) == int(ctx["battle_round"]):
					proposal = recorded["proposal"].duplicate(true)
					proposal["context"]["generation"] = ctx["generation"]
			if not proposal.is_empty() and proposal.get("result",{}).get("source","") == "model":
				var verdict := model_verdict(ctx,proposal)
				if verdict["ok"]:
					local = proposal["result"].duplicate(true)
					local["candidate_id"] = verdict["candidate_id"]
					local["model_proposal"] = proposal
				else: local["fallback_reason"] = verdict["reason"]
			var interval := 1 if float(ctx["officer"].get("skills",{}).get("应变",50)) >= 80 else 2 if float(ctx["officer"].get("skills",{}).get("应变",50)) >= 50 else 3
			if not proposal.is_empty() and not str(proposal.get("result",{}).get("fallback_reason","")).is_empty():
				ai["model_failures"] = mini(4,int(ai.get("model_failures",0))+1)
				ai["model_backoff_until"] = int(ctx["battle_round"]) + int(ai["model_failures"]) * 2
			if adapter != null and adapter.has_method("supports_background_decisions") and war.state.get("battle_ai_replay",[]).is_empty():
				ask_stats["eligible"] = int(ask_stats.get("eligible",0)) + 1
				if int(ctx["battle_round"]) < int(ai.get("model_backoff_until",0)):
					ask_stats["backoff"] = int(ask_stats.get("backoff",0)) + 1
				elif not ctx["crisis"] and int(ctx["battle_round"]) - int(ai.get("last_model_request",-10)) < interval:
					ask_stats["interval"] = int(ask_stats.get("interval",0)) + 1
				elif war.planner.has_pending(key):
					ask_stats["pending"] = int(ask_stats.get("pending",0)) + 1
				elif not war.Policy.should_ask_model(ctx):
					ask_stats["gate"] = int(ask_stats.get("gate",0)) + 1
				elif adapter.has_method("can_request_model") and not adapter.can_request_model(ctx):
					ask_stats["mode"] = int(ask_stats.get("mode",0)) + 1
				else:
					ask_stats["asked"] = int(ask_stats.get("asked",0)) + 1
					requests.append(ctx)
					signatures[key] = signature(ctx,adapter)
					ai["last_model_request"] = ctx["battle_round"]
		proposals[key] = local
	var evaluate_done := Time.get_ticks_usec()
	var selected := Coordination.resolve(contexts,proposals)
	var coordination_done := Time.get_ticks_usec()
	for ctx in contexts:
		var result: Dictionary = selected.get(ctx["actor_key"],proposals[ctx["actor_key"]])
		if shadow:
			war.state["battle_ai_shadow"].append({"round":ctx["battle_round"],"actor_key":ctx["actor_key"],"proposal":result})
		else: Commit.apply(war,ctx,result)
	while war.state.get("battle_ai_shadow",[]).size() > 160: war.state["battle_ai_shadow"].pop_front()
	if not shadow and adapter != null: war.planner.submit(requests,adapter,signatures)
	war.state["battle_ai_metrics"] = {"actors":contexts.size(),"decision_ms":(Time.get_ticks_usec()-started)/1000.0,"round":war.state["battle_round"]}
	war.state["battle_ai_metrics"]["stages_ms"] = {"context":(context_done-started)/1000.0,"evaluation":(evaluate_done-context_done)/1000.0,"coordination":(coordination_done-evaluate_done)/1000.0,"commit":(Time.get_ticks_usec()-coordination_done)/1000.0}
	var totals := {"snapshot_us":0,"exchange_us":0,"candidate_us":0}
	for ctx in contexts:
		for key in totals: totals[key] += ctx["timing"][key]
	war.state["battle_ai_metrics"]["context_us"] = totals
