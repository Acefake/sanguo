extends RefCounted

const Plan = preload("res://scripts/agents/tactical_plan.gd")
const Tactical = preload("res://scripts/war/battle/tactical_battlefield.gd")

# One persistent identity per officer. Commander, physical leader and adviser are
# authority facets of that identity; advisers never submit movement or casualties.
static func initialize(war) -> void:
	for id in war.roster.officers: ensure(war,str(id))
	sync(war)

static func ensure(war, id: String) -> Dictionary:
	if not war.state.get("officer_agents",{}) is Dictionary: war.state["officer_agents"] = {}
	if not war.state["officer_agents"].get(id) is Dictionary:
		war.state["officer_agents"][id] = {"version":1,"actor_key":"officer:"+id,"officer_id":id,"revision":1,"role":"resident","facets":{},"history":[],"memory":[],"last_round":-1}
	var agent: Dictionary = war.state["officer_agents"][id]
	for key in ["facets","history","memory"]:
		if not agent.get(key) is Dictionary and key == "facets": agent[key] = {}
		elif key != "facets" and not agent.get(key) is Array: agent[key] = []
	agent["actor_key"] = "officer:"+id
	agent["officer_id"] = id
	agent["revision"] = maxi(1,int(agent.get("revision",1)))
	agent["last_round"] = int(agent.get("last_round",-1))
	while agent["history"].size() > 20: agent["history"].pop_front()
	while agent["memory"].size() > 6: agent["memory"].pop_front()
	return agent

static func sync(war) -> void:
	var roles := {}
	for army in war.active_armies():
		roles[str(army["officer_id"])] = {"role":"unit","army_id":army["id"],"corps_id":army.get("corps_id","")}
	for corps in war.state["corps"].values():
		var root: Dictionary = war.state["armies"][corps["root_id"]]
		if root["status"] == "ended": continue
		for id in corps["members"]:
			var status: Dictionary = war.state["officer_states"].get(id,{})
			if status.get("lost",false) or status.get("status","") in ["dead","captured"]: continue
			if id == corps["commander_id"]: roles[id] = {"role":"commander","army_id":corps["root_id"],"corps_id":corps["id"]}
			elif not roles.has(id) and status.get("status","") == "deployed" and status.get("corps_id","") == corps["id"]: roles[id] = {"role":"adviser","army_id":"","corps_id":corps["id"]}
	for id in war.roster.officers:
		var agent := ensure(war,str(id))
		var binding: Dictionary = roles.get(id,{"role":"resident","army_id":"","corps_id":""})
		var status: Dictionary = war.state["officer_states"].get(id,{})
		if status.get("lost",false) or status.get("status","") in ["dead","captured"]: binding = {"role":"inactive","army_id":"","corps_id":""}
		if agent.get("binding",binding) != binding:
			agent["revision"] = int(agent["revision"])+1
			war.planner.invalidate(agent["actor_key"])
			agent["facets"] = {}
		agent["binding"] = binding
		agent["role"] = binding["role"]
		if binding["role"] == "commander":
			var orders: Array = war.state["corps"][binding["corps_id"]].get("orders",[])
			if not orders.is_empty(): agent["facets"]["command"] = orders[-1].duplicate(true)

static func context(war, agent: Dictionary) -> Dictionary:
	var corps: Dictionary = war.state["corps"][agent["binding"]["corps_id"]]
	var root: Dictionary = war.state["armies"][corps["root_id"]]
	var enemies: Array = root["intel"]["enemies"].values().duplicate(true)
	var allies: Array = []
	for unit_id in corps["units"]:
		var unit: Dictionary = war.state["armies"][unit_id]
		if unit["status"] == "ended": continue
		allies.append({"id":unit_id,"strength":war.Combat.strength(unit),"organization":unit["organization"],"morale":unit["morale"],"returning":unit["returning"],"role":unit["corps_task"]["type"]})
	var weak: Array = allies.filter(func(a): return a["organization"] < 45 or a["morale"] < 40 or a["returning"])
	var candidates: Array = []
	for kind in ["observe","support","flank","rally","assault"]:
		if kind == "support" and weak.is_empty(): continue
		if kind in ["flank","assault"] and enemies.is_empty(): continue
		candidates.append({"id":kind,"action":{"type":"advise","kind":kind,"unit_id":weak[0]["id"] if kind == "support" else ""},"description":{"observe":"保持部署并核实敌情","support":"接应承压分队","flank":"建议侧翼配合","rally":"建议轮换整顿","assault":"建议协同推进"}[kind]})
	return {"schema_version":1,"level":"adviser","actor_key":agent["actor_key"],"officer_id":agent["officer_id"],"request_id":"%s:%d" % [agent["actor_key"],war.state["battle_round"]],"battle_round":war.state["battle_round"],"generation":war.generation,"actor_revision":agent["revision"],"command_revision":corps["commander_id"],"officer":war.roster.officers[agent["officer_id"]].duplicate(true),"task":{"role":corps["appointments"].get(agent["officer_id"],"随军辅佐"),"corps_id":corps["id"]},"authority":{"advice_only":true,"may_execute":false},"knowledge":{"enemies":enemies,"allies":allies},"weak_count":weak.size(),"crisis":not weak.is_empty(),"current_plan":agent["facets"].get("adviser",{}),"experience":agent["memory"].duplicate(true),"candidates":candidates,"supply_enabled":war.supply_enabled()}

static func rank(ctx: Dictionary) -> Array:
	var officer: Dictionary = ctx["officer"]
	var p: Dictionary = officer.get("personality",{})
	var ready := 0.0
	for ally in ctx["knowledge"]["allies"]:
		if not ally["returning"]: ready += float(ally["strength"])
	var enemy_total := 0.0
	for enemy in ctx["knowledge"]["enemies"]:
		if int(enemy.get("observed_at",-100)) >= int(ctx["battle_round"])-2: enemy_total += float(enemy["strength_estimate"])
	var ratio := enemy_total/maxf(ready,1)
	var risk := (float(p.get("风险承受",50))-50)/50.0
	var empathy := (float(p.get("同理心",50))-50)/50.0
	var patience := (float(p.get("耐心",50))-50)/50.0
	var ranked: Array = []
	for candidate in ctx["candidates"]:
		var kind: String = candidate["action"]["kind"]
		var score := 20.0
		match kind:
			"observe": score += patience*8 + (8 if enemy_total == 0 else 0)
			"support": score += int(ctx["weak_count"])*10 + empathy*10
			"flank": score += risk*8 + float(officer["skills"].get("奇袭",50))/20.0 - maxf(0,ratio-1)*8
			"rally": score += int(ctx["weak_count"])*8 + maxf(0,ratio-1)*15 - risk*8
			"assault": score += risk*8 + clampf((1-ratio)*10,-15,10) - int(ctx["weak_count"])*6
		if ctx["current_plan"].get("kind","") == kind: score += 4
		ranked.append({"candidate":candidate,"score":score,"breakdown":{"参谋判断":score}})
	ranked.sort_custom(func(a,b): return a["score"] > b["score"] if not is_equal_approx(a["score"],b["score"]) else a["candidate"]["id"] < b["candidate"]["id"])
	return ranked

static func choose(ctx: Dictionary) -> Dictionary:
	var ranked := rank(ctx)
	return {"candidate_id":ranked[0]["candidate"]["id"],"reason_summary":ranked[0]["candidate"]["description"],"source":"adviser-local","score_breakdown":ranked[0]["breakdown"]}

static func deliberate(war, adapter: Node = null) -> void:
	sync(war)
	var requests: Array = []
	var signatures := {}
	for agent in war.state["officer_agents"].values():
		if agent["role"] != "adviser" or int(agent["last_round"]) == int(war.state["battle_round"]): continue
		var corps: Dictionary = war.state["corps"][agent["binding"]["corps_id"]]
		var root: Dictionary = war.state["armies"][corps["root_id"]]
		var status: Dictionary = war.state["officer_states"].get(agent["officer_id"],{})
		if root["returning"] or not war.ready(root) or status.get("duel_wounded",false): continue
		var ctx := context(war,agent)
		var signature := JSON.stringify([ctx["generation"],ctx["actor_revision"],ctx["command_revision"],ctx["crisis"],str(adapter.get("model")) if adapter != null else "",str(adapter.get("endpoint")) if adapter != null else ""])
		var proposal: Dictionary = war.planner.take(agent["actor_key"],signature,int(ctx["battle_round"]))
		for recorded in war.state.get("battle_ai_replay",[]):
			if recorded["actor_key"] == agent["actor_key"] and int(recorded["adopted_round"]) == int(ctx["battle_round"]):
				proposal = recorded["proposal"].duplicate(true)
				proposal["context"]["generation"] = ctx["generation"]
		var result := choose(ctx)
		var requested: Dictionary = proposal.get("context",{})
		if proposal.get("result",{}).get("source","") == "model" and requested.get("generation") == ctx["generation"] and requested.get("actor_revision") == ctx["actor_revision"] and requested.get("command_revision") == ctx["command_revision"]:
			for candidate in ctx["candidates"]:
				for original in proposal["context"]["candidates"]:
					if original["id"] == proposal["result"].get("candidate_id","") and Plan.normalized(candidate["action"]) == Plan.normalized(original["action"]): result = proposal["result"]
		var advice := {}
		for candidate in ctx["candidates"]:
			if candidate["id"] == result["candidate_id"]: advice = candidate["action"].duplicate(true)
		advice.merge({"round":ctx["battle_round"],"officer_id":agent["officer_id"],"name":ctx["officer"]["name"],"reason":str(result["reason_summary"]).left(120),"source":result["source"],"expires_round":int(ctx["battle_round"])+2,"planning":ctx["officer"]["skills"].get("智计",50)})
		agent["facets"]["adviser"] = advice
		agent["last_round"] = ctx["battle_round"]
		agent["history"].append(advice)
		if result.get("source","") == "model":
			war.state["battle_ai_model_log"].append({"actor_key":agent["actor_key"],"adopted_round":ctx["battle_round"],"proposal":proposal.duplicate(true)})
			while war.state["battle_ai_model_log"].size() > 80: war.state["battle_ai_model_log"].pop_front()
		while agent["history"].size() > 20: agent["history"].pop_front()
		if ctx["crisis"]:
			agent["memory"].append({"round":ctx["battle_round"],"event":"known_allied_pressure","source":"corps_report"})
		while agent["memory"].size() > 6: agent["memory"].pop_front()
		if not str(proposal.get("result",{}).get("fallback_reason","")).is_empty():
			agent["model_failures"] = mini(4,int(agent.get("model_failures",0))+1)
			agent["model_backoff_until"] = int(ctx["battle_round"])+int(agent["model_failures"])*2
		elif result.get("source","") == "model": agent["model_failures"] = 0
		if adapter != null and war.state.get("battle_ai_replay",[]).is_empty() and adapter.has_method("supports_background_decisions") and adapter.has_method("can_request_model") and adapter.can_request_model(ctx) and not war.planner.has_pending(agent["actor_key"]) and int(ctx["battle_round"])-int(agent.get("last_model_round",-10)) >= 3 and int(ctx["battle_round"]) >= int(agent.get("model_backoff_until",0)):
			requests.append(ctx)
			signatures[agent["actor_key"]] = signature
			agent["last_model_round"] = ctx["battle_round"]
	if adapter != null: war.planner.submit(requests,adapter,signatures)

static func advice(war, corps: Dictionary) -> Array:
	var result: Array = []
	if war.rules.get("battle_ai",{}).get("mode","active") != "active": return result
	var autonomy = preload("res://scripts/agents/officer_autonomy.gd")
	for id in corps["members"]:
		var agent: Dictionary = war.state.get("officer_agents",{}).get(id,{})
		if agent.get("role","") != "adviser" or war.state["officer_states"].get(id,{}).get("duel_wounded",false): continue
		var known: Dictionary = agent.get("facets",{}).get("adviser",{})
		if not known.is_empty() and int(known["expires_round"]) >= int(war.state["battle_round"]):
			var entry: Dictionary = known.duplicate(true)
			var stance: Dictionary = autonomy.stance_of(corps, str(id))
			if not stance.is_empty():
				entry["stance"] = str(stance.get("stance","obey"))
				entry["stance_reason"] = str(stance.get("reason",""))
			result.append(entry)
	return result

static func record_command(war, corps: Dictionary, order: Dictionary) -> void:
	var agent := ensure(war,str(corps["commander_id"]))
	agent["facets"]["command"] = order.duplicate(true)
	agent["history"].append({"round":war.state["battle_round"],"facet":"command","corps_id":corps["id"],"action":order["action"].duplicate(true),"reason":order.get("reason","")})
	while agent["history"].size() > 20: agent["history"].pop_front()
