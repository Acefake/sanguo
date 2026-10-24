extends RefCounted

const Tactical = preload("res://scripts/war/tactical_battlefield.gd")
const VERSION := 1
static var _templates: Dictionary = {}

static func templates() -> Dictionary:
	if _templates.is_empty():
		_templates = JSON.parse_string(FileAccess.get_file_as_string("res://data/agents/tactical_templates.json"))["templates"]
	return _templates

static func ensure(war, army: Dictionary) -> Dictionary:
	if not army.get("battle_ai") is Dictionary:
		army["battle_ai"] = {"version": VERSION, "actor_revision": 1, "command_revision": 1, "plan": {}, "local_state": "active", "history": [], "memory": [], "reports": {}, "wait_rounds": 0}
	var ai: Dictionary = army["battle_ai"]
	var defaults := {"version":VERSION,"actor_revision":1,"command_revision":1,"plan":{},"local_state":"active","history":[],"memory":[],"reports":{},"wait_rounds":0}
	for key in defaults:
		if not ai.has(key) or (typeof(defaults[key]) not in [TYPE_INT,TYPE_FLOAT] and typeof(ai[key]) != typeof(defaults[key])): ai[key] = defaults[key]
	for key in ["version","actor_revision","command_revision","wait_rounds"]: ai[key] = maxi(0,int(ai[key]))
	if not ai["plan"].is_empty() and (not templates().has(ai["plan"].get("template","")) or int(ai["plan"].get("goal_cell",-1)) < 0): ai["plan"] = {}
	if army.get("status","") == "ended" or army.get("returning",false): ai["plan"] = {}; ai["local_state"] = "active"
	while ai["history"].size() > 40: ai["history"].pop_front()
	while ai["memory"].size() > 10: ai["memory"].pop_front()
	var binding := str(army.get("officer_id", "")) + ":" + str(army.get("status", ""))
	if ai.has("binding") and ai["binding"] != binding:
		ai["actor_revision"] = int(ai.get("actor_revision", 0)) + 1
		ai["plan"] = {}
		ai["memory"] = []
		war.planner.invalidate("unit:" + str(army["id"]))
	ai["binding"] = binding
	var corps: Dictionary = war.state["corps"].get(army.get("corps_id", ""), {})
	var command := JSON.stringify(normalized([corps.get("commander_id", ""), army.get("corps_task", {}), war.orders_for(army)]))
	if ai.has("command_binding") and ai["command_binding"] != command:
		ai["command_revision"] = int(ai.get("command_revision", 0)) + 1
		ai["plan"] = {}
		ai["duty_cell"] = int(army.get("tactical",{}).get("cell",ai.get("duty_cell",-1)))
		war.planner.invalidate("unit:" + str(army["id"]))
	ai["command_binding"] = command
	return ai

# JSON reads numbers as floats. Authority signatures must survive that round-trip.
static func normalized(value: Variant) -> Variant:
	if typeof(value) in [TYPE_INT,TYPE_FLOAT]: return float(value)
	if value is Array: return value.map(func(item): return normalized(item))
	if value is Dictionary:
		var result := {}
		for key in value: result[key] = normalized(value[key])
		return result
	return value

static func authority(war, army: Dictionary) -> Dictionary:
	var orders: Dictionary = war.orders_for(army)
	var task: Dictionary = army.get("corps_task", {})
	var anchor := Tactical.authority_duty_cell(war,army,orders)
	return {"engage": orders["engage"], "pursue": orders["pursue"], "local_disengage": bool(orders.get("local_disengage", orders["retreat"])) and bool(orders["retreat"]), "risk_allowance": orders["risk_allowance"], "must_hold_objective": bool(orders.get("must_hold_objective", false)) or bool(task.get("must_hold_objective", false)), "duty_cell": anchor, "region_radius": int(task.get("region_radius", 16)), "local_retreat_cells": int(orders.get("local_retreat_cells", 3)), "pursuit_limit_cells": int(orders.get("pursuit_limit_cells", 3)), "reserve_reinforce": bool(task.get("reserve_reinforce", true)), "change_role_requires_request": true}

static func same(a: Dictionary, b: Dictionary) -> bool:
	for key in ["template", "target_id", "goal_cell", "ally_id"]:
		if a.get(key) != b.get(key): return false
	return true

static func valid(context: Dictionary, plan: Dictionary) -> bool:
	if plan.is_empty() or not templates().has(plan.get("template", "")): return false
	if int(plan.get("command_revision", context["command_revision"])) != int(context["command_revision"]): return false
	if not str(plan.get("target_id", "")).is_empty():
		if not context["knowledge"]["enemies"].any(func(e): return e["id"] == plan["target_id"] and int(e["observed_round"]) >= int(context["battle_round"]) - 1): return false
	if not str(plan.get("ally_id", "")).is_empty():
		if not context["knowledge"]["allies"].any(func(a): return a["id"] == plan["ally_id"] and int(a["delivered_round"]) >= int(context["battle_round"]) - 2): return false
	return context["candidates"].any(func(c): return same(c["canonical_plan"], plan))

static func adopt(context: Dictionary, candidate: Dictionary, old: Dictionary) -> Dictionary:
	var plan: Dictionary = candidate["canonical_plan"].duplicate(true)
	plan["started_round"] = old.get("started_round", context["battle_round"]) if same(plan, old) else context["battle_round"]
	plan["command_revision"] = context["command_revision"]
	plan["stage"] = candidate.get("stage", "approach")
	plan["position_goal"] = candidate["action"].get("position_goal",candidate["next_cell"])
	plan["label"] = templates()[plan["template"]]["label"]
	plan["next"] = templates()[plan["template"]]["next"]
	plan["stop_condition"] = "军令变化、目标失效、通路连续受阻或已知威胁恶化时重新判断"
	if plan["template"] == "cover_ally": plan["stop_condition"] = "友军脱险后归位；军令变化、通路受阻或威胁恶化时改判"
	elif plan["template"] == "rally": plan["stop_condition"] = "组织60、士气55、疲劳50以内时重新投入；休整点受威胁时换位"
	elif plan["template"] == "scout": plan["stop_condition"] = "获得可靠敌情后恢复职责；通路受阻或威胁加重时改判"
	return plan

static func after_round(war, army: Dictionary) -> void:
	if not army.has("battle_ai") or not army.has("tactical"): return
	var ai: Dictionary = army["battle_ai"]
	var plan: Dictionary = ai.get("plan", {})
	if army["status"] == "ended" or army["returning"]:
		ai["plan"] = {}
		ai["local_state"] = "active"
		return
	if plan.get("template", "") != "rally": return
	var contact: Dictionary = war._observed_contact(army)
	var cell := int(army["tactical"]["cell"])
	var at_goal := Tactical.cell_distance(cell,int(plan["goal_cell"])) == 0
	var hit_today: bool = int(army.get("daily_loss_tick",-1)) == int(war.state["tick"]) and int(army.get("daily_loss",0)) > 0
	var safe_here: bool = int(contact["adjacent_enemies"]) == 0 and not hit_today
	if safe_here:
		for sight in army["intel"]["enemies"].values():
			var enemy_cell := int(sight.get("tactical_cell",-1))
			if enemy_cell < 0 or int(sight.get("observed_at",-100)) < int(war.state["tick"])-1: continue
			var radius := Tactical.attack_range({"units":sight.get("unit_mix_estimate",{})})
			if Tactical.cell_distance(cell,enemy_cell) <= radius and Tactical.Fort.line_of_sight(Tactical.board_for(war,army),cell,enemy_cell): safe_here = false; break
	# Recovery has a safety objective. Reaching a safe intermediate tile completes
	# repositioning; an arbitrary farther waypoint must not keep the unit marching.
	if not at_goal and safe_here:
		plan["goal_cell"] = cell
		plan["position_goal"] = cell
		at_goal = true
	if int(contact["adjacent_enemies"]) > 0: ai["local_state"] = "disengaging_local"
	elif not at_goal: ai["local_state"] = "repositioning"
	elif float(army["organization"]) >= 60 and float(army["morale"]) >= 55 and float(army["fatigue"]) <= 50:
		ai["local_state"] = "ready_to_rejoin"
	else: ai["local_state"] = "recovering"
	plan["stage"] = {"disengaging_local": "disengage", "repositioning": "reposition", "recovering": "recover", "ready_to_rejoin": "rejoin"}.get(ai["local_state"], "recover")
