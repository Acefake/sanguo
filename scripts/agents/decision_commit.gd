extends RefCounted

const Plan = preload("res://scripts/agents/tactical_plan.gd")
const Evaluator = preload("res://scripts/agents/tactical_evaluator.gd")

static func apply(war, context: Dictionary, result: Dictionary) -> bool:
	var army: Dictionary = war.state["armies"].get(context["army_id"],{})
	if army.is_empty() or army["status"] == "ended" or army["returning"] or not war.ready(army): return false
	var ai := Plan.ensure(war,army)
	if int(ai.get("submitted_round",-1)) == int(context["battle_round"]): return false
	if int(context["generation"]) != war.generation or int(ai["actor_revision"]) != int(context["actor_revision"]) or int(ai["command_revision"]) != int(context["command_revision"]): return false
	var candidate: Dictionary = {}
	for c in context["candidates"]:
		if c["id"] == result.get("candidate_id",""): candidate = c; break
	if result.has("coordinated_candidate"):
		var coordinated: Dictionary = result["coordinated_candidate"]
		if not candidate.is_empty() and Plan.same(coordinated["canonical_plan"],candidate["canonical_plan"]): candidate = coordinated
	if candidate.is_empty():
		ai["last_error"] = "no_legal_action"
		ai["submitted_round"] = context["battle_round"]
		army["action"] = {"type":"no_legal_action","tactical_contract":true,"goal_cell":context["self"]["cell"],"path":[],"intent":"等待有效军令"}
		ai["history"].append({"tick":war.state["tick"],"army_id":army["id"],"actor_key":context["actor_key"],"source":"rules","reason_summary":"当前没有合法行动，等待状态或军令更新","error":"no_legal_action"})
		while ai["history"].size() > 40: ai["history"].pop_front()
		return false
	var action: Dictionary = candidate["action"]
	if action["type"] == "local_disengage" and (not context["authority"]["local_disengage"] or context["authority"]["must_hold_objective"]): return false
	var previous: Dictionary = ai.get("plan",{})
	ai["plan"] = Plan.adopt(context,candidate,previous)
	if candidate["canonical_plan"]["template"] == "rally":
		ai["local_state"] = "disengaging_local" if action["type"] == "local_disengage" else "recovering" if candidate["next_cell"] == context["self"]["cell"] else "repositioning"
	else: ai["local_state"] = "active"
	ai["submitted_round"] = context["battle_round"]
	if context.get("review_now",true) or context["crisis"]: ai["last_review_round"] = context["battle_round"]
	ai["last_source"] = result.get("source","baseline")
	ai["last_risk"] = candidate.get("forecast",{}).get("risk",0)
	ai["coordination_intent"] = result.get("coordination_intent",{}).duplicate(true)
	ai["known_target"] = candidate.get("target",{}).duplicate(true)
	ai["last_error"] = ""
	war._execute(army,action)
	army["last_decision"] = war.state["tick"]
	army["last_reason"] = str(result.get("reason_summary",Evaluator.reason(context,candidate))).left(160)
	var record := {"tick":war.state["tick"],"battle_round":context["battle_round"],"actor_key":context["actor_key"],"army_id":army["id"],"request_id":context["request_id"],"candidate_id":candidate["id"],"canonical_plan":ai["plan"].duplicate(true),"action":action.duplicate(true),"reason_summary":army["last_reason"],"source":result.get("source","baseline"),"score_breakdown":result.get("score_breakdown",{}),"forecast":candidate.get("forecast",{}).duplicate(true),"coordination_reason":result.get("coordination_reason",""),"fallback_reason":result.get("fallback_reason",""),"actor_revision":ai["actor_revision"],"command_revision":ai["command_revision"],"rules_version":war.rules["version"],"policy_version":war.Policy.version(),"prompt_version":6}
	ai["history"].append(record)
	while ai["history"].size() > 40: ai["history"].pop_front()
	army["decision_history"] = ai["history"]
	var officer_agent := preload("res://scripts/agents/officer_brain.gd").ensure(war,str(army["officer_id"]))
	officer_agent["facets"]["tactical"] = {"round":context["battle_round"],"army_id":army["id"],"plan":ai["plan"].duplicate(true),"reason":army["last_reason"],"source":ai["last_source"]}
	officer_agent["history"].append({"round":context["battle_round"],"facet":"tactical","army_id":army["id"],"template":ai["plan"]["template"],"reason":army["last_reason"],"source":ai["last_source"]})
	while officer_agent["history"].size() > 20: officer_agent["history"].pop_front()
	war.state["decisions"].append(record)
	if result.has("model_proposal"):
		war.state["battle_ai_model_log"].append({"actor_key":context["actor_key"],"adopted_round":context["battle_round"],"proposal":result["model_proposal"].duplicate(true)})
		while war.state["battle_ai_model_log"].size() > 80: war.state["battle_ai_model_log"].pop_front()
	var changed := not Plan.same(previous,ai["plan"])
	if changed and (ai["local_state"] != "active" or candidate["canonical_plan"]["template"] == "reserve_reinforce"):
		if int(context["battle_round"])-int(ai.get("last_report_round",-10)) >= 3:
			war._report(army,"临机调整",army["name"] + "：" + army["last_reason"],false)
			ai["last_report_round"] = context["battle_round"]
	if context["crisis"] and int(context["battle_round"])-int(ai.get("last_support_round",-10)) >= 4:
		war._report(army,"求援",army["name"] + "承压，请求接应；继续执行" + ai["plan"]["label"],false)
		ai["last_support_round"] = context["battle_round"]
		army["last_support"] = war.state["tick"]
	return true
