class_name ProvingGroundSim
extends RefCounted
## 检验战场的逐刻推演（默认 6 小时一刻）。
##
## 每支部队的主将在“决策点”上自己看态势（OfficerAwareness）、自己选姿态（OfficerIntent），参军可以进言；
## 姿态只决定往哪走、打谁、守不守，伤亡与士气全部走 combat_system，属性与特性只经 OfficerProcess/OfficerConduct 进入：
##   命令整理+展开（姿态改变时）→ 当刻可用时间；行军 march_time_factor；工事 engineering_rate；
##   隐蔽 conceal_exposure、识破 ambush_read；追击 pursuit_rate 与 pursuit_limit；脱离线 disengage_line；
##   协同就位 commit_readiness（急躁/好谋少决）；士气光环 aura_strength。
## 侧击/伏击的突然性用 campaign_rules.combat.flank.flank_attack，不放在人物侧。
## 同一种子下只换人：战斗与每支部队的感知各用独立随机流（种子由战场、试验无关的部队 id 派生）。

const Combat = preload("res://scripts/war/battle/combat_system.gd")
const Process = preload("res://scripts/officers/officer_process.gd")
const Conduct = preload("res://scripts/officers/officer_conduct.gd")
const Awareness = preload("res://scripts/officers/officer_awareness.gd")
const Intent = preload("res://scripts/officers/officer_intent.gd")
const Leadership = preload("res://scripts/officers/officer_leadership.gd")
const Data = preload("res://scripts/war/proving/battlefield_data.gd")
const Explain = preload("res://scripts/officers/officer_explain.gd")
const RULES_PATH := "res://data/war/campaign_rules.json"
const CONCEALED_POSTURES := ["flank", "raid"]
const RETREATING := ["withdraw", "lure"]

var field: Dictionary
var rules: Dictionary
var tick_hours := 6.0
var tick := 0
var zones: Dictionary = {}
var links: Dictionary = {}
var sides: Dictionary = {}
var units: Array = []
var decisions: Array = []
var events: Array = []
var rng: RandomNumberGenerator
var seed_value := 0
var outcome: Dictionary = {}


static func rules_config() -> Dictionary:
	return JSON.parse_string(FileAccess.get_file_as_string(RULES_PATH))


## 跑完一场，返回 {outcome, decisions, events, units}。
static func run(battlefield: Dictionary, seed: int, config: Dictionary = {}) -> Dictionary:
	var sim := new()
	sim.setup(battlefield, seed, config)
	while not sim.finished(): sim.step()
	return sim.result()


func setup(battlefield: Dictionary, seed: int, config: Dictionary = {}) -> void:
	field = battlefield
	rules = config if not config.is_empty() else rules_config()
	tick_hours = float(field.get("tick_hours", 6))
	seed_value = seed
	rng = RandomNumberGenerator.new()
	rng.seed = hash([field["id"], seed, "combat"])
	for zone in field["zones"]:
		var copy: Dictionary = zone.duplicate(true)
		copy["fort"] = float(zone.get("fort", 0.0))
		zones[str(zone["id"])] = copy
		links[str(zone["id"])] = {}
	for link in field["links"]:
		links[str(link[0])][str(link[1])] = float(link[2])
		links[str(link[1])][str(link[0])] = float(link[2])
	for side in field["sides"]:
		var spec: Dictionary = field["sides"][side]
		sides[side] = {"id": side, "name": str(spec.get("name", side)), "supply_days": float(spec.get("supply_days", 30)), "depot_burnt": false, "alerted": false, "bait_zone": "", "baggage_dropped": false, "initial": 0, "spec": spec}
		for unit_spec in spec["units"]:
			var unit := _make_unit(side, unit_spec)
			unit["order"] = units.size()
			units.append(unit)
			sides[side]["initial"] += Combat.strength(unit["army"])
	_update_holders()
	tick = 0


func finished() -> bool:
	return tick >= int(field["ticks"]) or not outcome.is_empty()


func step() -> void:
	# 先手不固定：偶数刻按数据顺序，奇数刻倒序，避免哪一方总是先动、先接敌。
	units.reverse()
	for unit in units: unit["ambushed_now"] = false
	_decide_all()
	_move_all()
	_fight_all()
	_upkeep()
	_update_holders()
	tick += 1
	_check_end()


## 区域归属：只有一方的在场部队时归这一方；工事只护归属方。
func _update_holders() -> void:
	for id in zones:
		var present := {}
		for u in units:
			if active(u) and u["zone"] == id: present[u["side"]] = true
		if present.size() == 1: zones[id]["holder"] = present.keys()[0]


func result() -> Dictionary:
	if outcome.is_empty(): outcome = _judge()
	var summary: Array = []
	var ordered := units.duplicate()
	ordered.sort_custom(func(a, b): return int(a["order"]) < int(b["order"]))
	for unit in ordered:
		var army: Dictionary = unit["army"]
		summary.append({"id": unit["id"], "side": unit["side"], "officer": unit["officer"]["name"], "officer_id": unit["officer"]["id"], "adviser": unit["adviser"].get("name", ""), "start": unit["start_strength"], "end": Combat.strength(army), "loss": unit["start_strength"] - Combat.strength(army), "morale": float(army["morale"]), "organization": float(army["organization"]), "routed": unit["routed"], "escaped": unit["escaped"], "posture": unit["posture"], "postures": unit["posture_ticks"], "ambushed": unit["was_ambushed"], "pursuit_steps": unit["pursuit_max"], "zone": unit["zone"]})
	return {"outcome": outcome, "decisions": decisions, "events": events, "units": summary}


# ---------------------------------------------------------------- 部队

func _make_unit(side: String, spec: Dictionary) -> Dictionary:
	var officer: Dictionary = Data.officer(str(spec["officer"]))
	var adviser: Dictionary = Data.officer(str(spec.get("adviser", ""))) if not str(spec.get("adviser", "")).is_empty() else {}
	var troops: Dictionary = spec["troops"]
	var army := {"id": str(spec["id"]), "officer_id": str(officer["id"]), "name": str(officer["name"]), "units": {"infantry": int(troops.get("infantry", 0)), "archers": int(troops.get("archers", 0)), "cavalry": int(troops.get("cavalry", 0))}, "skills": officer["skills"].duplicate(), "trait_ids": officer.get("trait_ids", []).duplicate(), "personality": officer.get("personality", {}).duplicate(), "morale": float(spec.get("morale", 90)), "organization": float(spec.get("organization", 90)), "fatigue": float(spec.get("fatigue", 0)), "training": int(spec.get("training", 70)), "equipment": int(spec.get("equipment", 60)), "action": {"type": "hold"}}
	var mind := RandomNumberGenerator.new()
	mind.seed = hash([field["id"], seed_value, str(spec.get("mind_key", spec["id"])), "mind"])
	return {"id": str(spec["id"]), "side": side, "role": str(spec.get("role", "main")), "officer": officer, "adviser": adviser, "army": army, "zone": str(spec["zone"]), "path": [], "progress": 0.0, "posture": "", "target": "", "pending": 0.0, "routed": false, "escaped": false, "hidden": bool(spec.get("hidden", false)), "ambusher": bool(spec.get("hidden", false)), "open_march": bool(spec.get("open_march", false)), "exposed": not bool(spec.get("hidden", false)), "mind": mind, "key": "", "pressure": 0.0, "plan_invalid": false, "pursuit_steps": 0, "pursuit_max": 0, "flank_mult_ticks": 0, "flank_share": 1.0, "commit_share": -1.0, "flank_progress": 0.0, "flank_total": 0.0, "siege_prep": 0.0, "was_ambushed": false, "ambushed_now": false, "start_strength": Combat.strength(army), "posture_ticks": {}, "contact_ticks": 0, "looted": false, "decisions": 0, "objectives": spec.get("objectives", [])}


func active(unit: Dictionary) -> bool:
	return not unit["routed"] and not unit["escaped"] and Combat.strength(unit["army"]) > 0


func enemies_of(unit: Dictionary) -> Array:
	return units.filter(func(u): return u["side"] != unit["side"] and active(u))


func friends_of(unit: Dictionary) -> Array:
	return units.filter(func(u): return u["side"] == unit["side"] and u != unit and active(u))


func by_id(id: String) -> Dictionary:
	for unit in units:
		if unit["id"] == id: return unit
	return {}


func other_side(side: String) -> String:
	for key in sides:
		if key != side: return key
	return side


## 敌方能看见的部队：未隐蔽，或隐蔽但已暴露。
func visible_to(viewer: Dictionary, unit: Dictionary) -> bool:
	return not unit["hidden"] or unit["exposed"] or bool(viewer["army"].get("threat_rolls", {}).get(unit["id"], {}).get("known", false))


func in_contact(unit: Dictionary) -> bool:
	return enemies_of(unit).any(func(e): return e["zone"] == unit["zone"] and not (e["hidden"] and not e["exposed"]))


# ---------------------------------------------------------------- 决策

func _decide_all() -> void:
	# 决策按数据顺序：主将先定，侧翼看得到主将这一刻要打谁。
	var ordered := units.duplicate()
	ordered.sort_custom(func(a, b): return int(a["order"]) < int(b["order"]))
	for unit in ordered:
		if not active(unit): continue
		var truth := _truth(unit)
		var ctx := _ctx(unit, unit["posture"] if not unit["posture"].is_empty() else "hold")
		var adviser_view := _adviser_view(unit)
		var picture := Awareness.perceive(unit["army"], truth, ctx, unit["mind"], adviser_view)
		var key := _situation_key(unit, picture, truth)
		var review := int(field.get("review_ticks", 4))
		if key == unit["key"] and not unit["plan_invalid"] and tick % review != 0: continue
		var trigger := "开局" if unit["key"].is_empty() else ("原方案失效" if unit["plan_invalid"] else ("态势变化" if key != unit["key"] else "例行复核"))
		unit["key"] = key
		var decision := Intent.decide(unit["army"], picture, ctx)
		if not adviser_view.is_empty():
			var advice := Intent.decide(adviser_view, Awareness.perceive(adviser_view, truth, ctx, unit["adviser_mind"]), ctx)
			decision = Intent.consult(unit["army"], decision, adviser_view, advice, unit["mind"], ctx)
		decision = Intent.pressure_slip(unit["army"], decision, unit["posture"], float(unit["pressure"]), unit["mind"], ctx)
		_apply_decision(unit, decision, picture, truth, trigger)


## 参军的视角：同一支部队换上参军的子属性、特性、人格；判断记忆（estimates、threat_rolls）跨决策点保留，
## 随机流与主将分开，所以有没有参军不会改变主将自己看到的东西。
func _adviser_view(unit: Dictionary) -> Dictionary:
	if unit["adviser"].is_empty(): return {}
	var view: Dictionary = unit.get("adviser_view", {})
	if view.is_empty():
		view = {"name": unit["adviser"]["name"], "skills": unit["adviser"]["skills"], "trait_ids": unit["adviser"].get("trait_ids", []), "personality": unit["adviser"].get("personality", {})}
		unit["adviser_view"] = view
		var mind := RandomNumberGenerator.new()
		mind.seed = hash([field["id"], seed_value, str(unit["id"]), "adviser"])
		unit["adviser_mind"] = mind
	for key in ["units", "morale", "organization", "fatigue", "training", "equipment", "action"]: view[key] = unit["army"][key]
	return view


func _apply_decision(unit: Dictionary, decision: Dictionary, picture: Dictionary, truth: Dictionary, trigger: String) -> void:
	var posture := str(decision["posture"])
	var ctx := _ctx(unit, posture)
	var delay := 0.0
	var changed: bool = posture != unit["posture"]
	if changed:
		delay = Process.order_delay_hours(unit["army"], ctx, unit["plan_invalid"])
		unit["pending"] = float(unit["pending"]) + delay
		unit["posture"] = posture
		unit["army"]["action"] = {"type": Intent.ACTION[posture]}
		unit["target"] = _pick_target(unit, posture)
		unit["path"] = []
		if posture in CONCEALED_POSTURES and not unit["open_march"] and not in_contact(unit):
			unit["hidden"] = true
			unit["exposed"] = false
		elif unit["hidden"] and not (unit["ambusher"] and posture == "hold"):
			_expose(unit, "现出行踪")
		if posture == "flank": _start_flank(unit)
		if posture == "lure": _drop_bait(unit)
		if posture != "pursue": unit["pursuit_steps"] = 0
	unit["plan_invalid"] = false
	unit["decisions"] += 1
	var seen: Dictionary = picture["seen"]
	var scores := {}
	for p in decision["scores"]: scores[p] = snappedf(float(decision["scores"][p]), 0.001)
	var buffs := Leadership.notable(unit["army"], ctx)
	decisions.append({"tick": tick, "hour": tick * tick_hours, "unit": unit["id"], "side": unit["side"], "officer": unit["officer"]["name"], "officer_id": unit["officer"]["id"], "adviser": unit["adviser"].get("name", ""), "trigger": trigger, "posture": posture, "name": decision["name"], "changed": changed, "delay_hours": snappedf(delay, 0.01), "scores": scores, "reasons": decision["reasons"], "advice": decision.get("advice", {}), "slip": decision.get("slip", {}), "seen": {"ratio": snappedf(float(seen["ratio"]), 0.01), "enemy_est": roundi(float(seen["enemy_est"])), "enemy_true": roundi(float(seen["enemy_true"])), "engage_ratio": snappedf(float(seen["engage_ratio"]), 0.01), "disengage_line": snappedf(float(seen["disengage_line"]), 0.1), "enemy_morale_est": roundi(float(seen["enemy_morale_est"])), "enemy_risk_read": roundi(float(seen["enemy_risk_read"])), "threat_known": seen["threat_known"], "organization": roundi(float(seen["organization"])), "morale": roundi(float(seen["morale"])), "supply_days": snappedf(float(seen["supply_days"]), 0.1), "in_contact": bool(truth.get("in_contact", false))}, "buffs": buffs.map(func(r): return {"label": r["label"], "value": snappedf(float(r["value"]), 0.0001), "attribute": snappedf(float(r["attribute"]["value"]), 0.0001), "levels": r["attribute"]["levels"], "trait": snappedf(float(r["trait"]["value"]), 0.0001), "sources": r["trait"]["sources"], "caps": r["trait"]["caps"]}), "audit": Leadership.audit(unit["army"], ctx)})


## 粗粒度态势签名：签名变了才算新的决策点（另有例行复核与原方案失效）。
func _situation_key(unit: Dictionary, picture: Dictionary, truth: Dictionary) -> String:
	var f: Dictionary = picture["features"]
	return "%d%d%d%d%d%d%d%d" % [int(truth.get("in_contact", false)), int(f["enemy_retreating"] > 0.0), int(f["threat_known"] > 0.0), int(f["ally_danger"] >= 0.5), int(f["org_low"] >= 0.5), int(f["supply_low"] >= 0.5), int(f["bait"] > 0.0), int(unit["path"].is_empty())]


## 这支部队所处的战场真值（感知前）。
func _truth(unit: Dictionary) -> Dictionary:
	var side: Dictionary = sides[unit["side"]]
	var spec: Dictionary = side["spec"]
	var enemy_side: Dictionary = sides[other_side(unit["side"])]
	var visible: Array = enemies_of(unit).filter(func(e): return visible_to(unit, e))
	var near: Array = visible.filter(func(e): return e["zone"] == unit["zone"])
	var contact := not near.is_empty()
	if near.is_empty(): near = visible.filter(func(e): return _hops(unit["zone"], e["zone"]) <= 1)
	if near.is_empty() and not visible.is_empty():
		var best: Dictionary = visible[0]
		for e in visible:
			if _hops(unit["zone"], e["zone"]) < _hops(unit["zone"], best["zone"]): best = e
		near = visible.filter(func(e): return e["zone"] == best["zone"])
	# 两程内、还没接战的可见敌军（援军、预备队）：要不要算进对面，由各人自己权衡（见 OfficerAwareness）。
	# 刚才还看得见、现在去向不明的敌军（转入隐蔽行军），记忆保留 memory_ticks 刻，也算在内。
	var nearby := 0
	var memory: Dictionary = unit.get("last_seen", {})
	for e in visible:
		memory[e["id"]] = {"tick": tick, "zone": e["zone"]}
		if not e in near and _hops(unit["zone"], e["zone"]) <= 2: nearby += Combat.strength(e["army"])
	for e in enemies_of(unit):
		if e in visible or not memory.has(e["id"]): continue
		if tick - int(memory[e["id"]]["tick"]) <= int(field.get("memory_ticks", 6)) and _hops(unit["zone"], str(memory[e["id"]]["zone"])) <= 2: nearby += Combat.strength(e["army"])
	unit["last_seen"] = memory
	var enemy_strength := 0
	var morale := 0.0
	var lead: Dictionary = {}
	for e in near:
		enemy_strength += Combat.strength(e["army"])
		morale += float(e["army"]["morale"]) * Combat.strength(e["army"])
		if lead.is_empty() or Combat.strength(e["army"]) > Combat.strength(lead["army"]): lead = e
	# 友军：同区的，加上正与这股敌军交战的（侧翼、援军据此判断“合力够不够”）。
	var allies := 0
	var foe_zones := near.map(func(e): return e["zone"])
	for f in friends_of(unit):
		if (f["zone"] == unit["zone"] or f["zone"] in foe_zones) and not (f["hidden"] and not f["exposed"]): allies += Combat.strength(f["army"])
	var zone: Dictionary = zones[unit["zone"]]
	var objectives: Array = _objectives(unit).map(func(o): return str(o["type"]))
	var truth := {"nearby_strength": nearby, "enemy_key": str(lead.get("id", "none")), "own_strength": Combat.strength(unit["army"]), "ally_strength": allies, "enemy_strength": enemy_strength, "enemy_morale": morale / maxf(enemy_strength, 1.0) if enemy_strength > 0 else 100.0, "enemy_risk": float(lead.get("army", {}).get("personality", {}).get("风险承受", 50)) if not lead.is_empty() else 50.0, "in_contact": contact, "defense": clampf((_fort_for(unit["side"], unit["zone"]) + float(Combat.Terrain.settings(str(zone["terrain"]), rules).get("defense", 1)) - 1.0) / 0.5, 0.0, 1.0), "objectives": objectives, "supply_days": float(side["supply_days"]), "ambushed": unit["was_ambushed"] and contact}
	if not lead.is_empty() and lead["zone"] != unit["zone"]: truth["target_cover"] = float(zones[lead["zone"]].get("cover", 0.0))
	if not lead.is_empty() and str(lead["posture"]) == "hold": truth["target_fort"] = clampf(_fort_for(lead["side"], lead["zone"]) / 0.5, 0.0, 1.0)
	var withdrawing := visible.any(func(e): return e["posture"] in RETREATING and _hops(unit["zone"], e["zone"]) <= 1)
	var broken := units.any(func(e): return e["side"] != unit["side"] and e["routed"] and not e["escaped"] and Combat.strength(e["army"]) > 0 and _hops(unit["zone"], e["zone"]) <= 1)
	truth["enemy_retreating"] = withdrawing or broken
	truth["ambush_ready"] = unit["hidden"] and not unit["exposed"] and unit["posture"] in ["", "hold"]
	var bait_zone := str(enemy_side["bait_zone"])
	truth["bait"] = not bait_zone.is_empty() and _hops(unit["zone"], bait_zone) <= 2 and not unit["looted"]
	truth["own_bait"] = spec.has("baggage") and not side["baggage_dropped"]
	# 诱敌之地：身后伏兵已就位记 1，只有可退的林地记 0.3。
	var lure_zone := str(spec.get("lure_zone", ""))
	var ambush_set := friends_of(unit).any(func(f): return f["zone"] == lure_zone and f["hidden"] and not f["exposed"])
	truth["lure_ground"] = 0.0 if lure_zone.is_empty() or unit["zone"] == lure_zone or unit["hidden"] else (1.0 if ambush_set else 0.3)
	var engaged: Array = visible.filter(func(e): return friends_of(unit).any(func(f): return (f["zone"] == e["zone"] and not f["hidden"]) or (f["posture"] == "assault" and str(f["target"]) == str(e["id"]))))
	truth["flank_route"] = engaged.any(func(e): return _alt_route(unit, e["zone"])) or (not visible.is_empty() and _alt_route(unit, visible[0]["zone"]))
	truth["flank_open"] = not engaged.is_empty() and engaged.any(func(e): return e["zone"] != unit["zone"] and _alt_route(unit, e["zone"]))
	if enemy_side["spec"].has("depot") and not enemy_side["depot_burnt"]:
		var depot_zone := str(enemy_side["spec"]["depot"]["zone"])
		var guard := 0
		for e in enemies_of(unit):
			if e["zone"] == depot_zone: guard += Combat.strength(e["army"])
		truth["depot"] = {"zone": depot_zone, "guard": guard, "cover": _route_cover(unit["zone"], depot_zone)}
	var hidden := _nearest_hidden(unit)
	if not hidden.is_empty(): truth["hidden"] = {"id": hidden["id"], "army": hidden["army"], "cover": float(zones[hidden["zone"]].get("cover", 0.3)), "plan_type": Intent.PLAN_TYPE.get(str(hidden["posture"]), "ambush"), "feint_executed": _feint(other_side(unit["side"]))}
	var danger := 0.0
	for f in friends_of(unit):
		var foes := enemies_of(f).filter(func(e): return e["zone"] == f["zone"])
		if foes.is_empty(): continue
		var foe_strength := 0
		for e in foes: foe_strength += Combat.strength(e["army"])
		danger = maxf(danger, clampf((float(foe_strength) / maxf(Combat.strength(f["army"]), 1.0) - 0.8) / 1.2, 0.0, 1.0) + (0.3 if float(f["army"]["organization"]) < 45.0 else 0.0))
	if spec.has("depot") and side["alerted"] and not side["depot_burnt"]: danger = maxf(danger, 0.8)
	truth["ally_danger"] = clampf(danger, 0.0, 1.0)
	truth["relief_target"] = not _relief_zone(unit).is_empty() and (danger >= 0.3 or "relieve" in objectives)
	for objective in _objectives(unit):
		if objective.has("deadline"):
			truth["deadline_ticks"] = int(objective["deadline"])
			truth["ticks_left"] = maxi(0, int(objective["deadline"]) - tick)
	return truth


## 特性条件用的情境：地形、计划类型、情报来源、是否有分统、佯动是否已执行等。
func _ctx(unit: Dictionary, posture: String) -> Dictionary:
	var spec: Dictionary = sides[unit["side"]]["spec"]
	var zone: Dictionary = zones[unit["zone"]]
	var intel: Dictionary = spec.get("intel", {})
	var flags: Dictionary = spec.get("flags", {})
	var ctx := {"terrain": str(zone["terrain"]), "plan_type": Intent.PLAN_TYPE.get(posture, ""), "action": Intent.ACTION.get(posture, "hold"), "communication": true, "subcommanders_assigned": not unit["adviser"].is_empty() or int(Combat.strength(unit["army"])) >= 8000, "independent_groups": int(intel.get("independent_groups", 1)), "cross_checked": bool(intel.get("cross_checked", false)), "route_surveyed": bool(flags.get("route_surveyed", false)), "enemy_pattern_received": bool(flags.get("enemy_pattern_received", false)), "attack_point_surveyed": bool(flags.get("attack_point_surveyed", false)), "feint_executed": _feint(unit["side"]), "visibility_cover": float(zone.get("cover", 0.3)), "plan_invalid_known": unit["plan_invalid"], "route_alternatives": _route_alternatives(unit["zone"]), "in_contact": in_contact(unit), "pressure": float(unit["pressure"]), "urgency": 0.8 if posture == "relieve" else 0.3, "supply_ratio": clampf(float(sides[unit["side"]]["supply_days"]) / 10.0, 0.0, 1.0), "rotation_path": true, "rally_route": true}
	if posture == "hold" and float(zone.get("fortifiable", 0.0)) > 0.0: ctx["engineering_type"] = "fortification"
	if posture == "assault": ctx["engineering_type"] = "assault_ladder"
	return ctx


func _fort_for(side: String, zone_id: String) -> float:
	return float(zones[zone_id]["fort"]) if str(zones[zone_id].get("holder", "")) == side else 0.0


func _feint(side: String) -> bool:
	return units.any(func(u): return u["side"] == side and u["open_march"] and active(u) and u["posture"] in ["raid", "flank", "assault"])


# ---------------------------------------------------------------- 目标与路线

func _pick_target(unit: Dictionary, posture: String) -> String:
	var visible: Array = enemies_of(unit).filter(func(e): return visible_to(unit, e))
	match posture:
		"assault", "flank":
			var goal := _goal_zone(unit)
			var engaged: Array = visible.filter(func(e): return friends_of(unit).any(func(f): return (f["zone"] == e["zone"] and not f["hidden"]) or (f["posture"] == "assault" and str(f["target"]) == str(e["id"]))))
			var pool: Array = engaged if posture == "flank" and not engaged.is_empty() else visible
			var at_goal: Array = pool.filter(func(e): return e["zone"] == goal)
			if not at_goal.is_empty(): pool = at_goal
			return _nearest(unit, pool)
		"pursue":
			var fleeing: Array = units.filter(func(e): return e["side"] != unit["side"] and not e["escaped"] and Combat.strength(e["army"]) > 0 and (e["routed"] or e["posture"] in RETREATING) and visible_to(unit, e))
			return _nearest(unit, fleeing)
	return ""


func _nearest(unit: Dictionary, pool: Array) -> String:
	var best: Dictionary = {}
	for e in pool:
		if best.is_empty() or _hops(unit["zone"], e["zone"]) < _hops(unit["zone"], best["zone"]) or (_hops(unit["zone"], e["zone"]) == _hops(unit["zone"], best["zone"]) and Combat.strength(e["army"]) > Combat.strength(best["army"])): best = e
	return "" if best.is_empty() else str(best["id"])


## 这一刻往哪个区域走（空字符串=原地）。
func _destination(unit: Dictionary) -> String:
	var spec: Dictionary = sides[unit["side"]]["spec"]
	if unit["routed"]: return str(spec.get("retreat", unit["zone"]))
	match str(unit["posture"]):
		"assault", "flank", "pursue":
			var target := by_id(str(unit["target"]))
			if target.is_empty() or not (active(target) or (unit["posture"] == "pursue" and target["routed"] and not target["escaped"])):
				unit["target"] = _pick_target(unit, str(unit["posture"]))
				target = by_id(str(unit["target"]))
			if target.is_empty(): return _goal_zone(unit) if unit["posture"] == "assault" else ""
			return str(target["zone"])
		"lure":
			for objective in _objectives(unit):
				if str(objective["type"]) == "feint": return str(objective["zone"])
			return str(spec.get("lure_zone", spec.get("retreat", unit["zone"])))
		"withdraw": return str(spec.get("retreat", unit["zone"]))
		"raid":
			var enemy_spec: Dictionary = sides[other_side(unit["side"])]["spec"]
			return str(enemy_spec["depot"]["zone"]) if enemy_spec.has("depot") and not sides[other_side(unit["side"])]["depot_burnt"] else ""
		"relieve": return _relief_zone(unit)
	return ""


## 这支部队的任务：部队自己的 objectives（如佯动）优先，否则用本方的。胜负只按本方的判定。
func _objectives(unit: Dictionary) -> Array:
	return unit["objectives"] if not unit["objectives"].is_empty() else sides[unit["side"]]["spec"].get("objectives", [])


func _goal_zone(unit: Dictionary) -> String:
	for objective in _objectives(unit):
		if str(objective["type"]) in ["take", "relieve"]: return str(objective["zone"])
	return ""


func _relief_zone(unit: Dictionary) -> String:
	var spec: Dictionary = sides[unit["side"]]["spec"]
	for objective in _objectives(unit):
		if str(objective["type"]) == "relieve": return str(objective["zone"])
	if spec.has("depot") and sides[unit["side"]]["alerted"] and not sides[unit["side"]]["depot_burnt"]: return str(spec["depot"]["zone"])
	var worst: Dictionary = {}
	for f in friends_of(unit):
		if enemies_of(f).any(func(e): return e["zone"] == f["zone"]) and (worst.is_empty() or float(f["army"]["organization"]) < float(worst["army"]["organization"])): worst = f
	return "" if worst.is_empty() else str(worst["zone"])


## Dijkstra；mode=flank 绕开有敌军的区域，flank/raid 都偏好有遮蔽的区域（隐蔽行军）。
func _route(from: String, to: String, mode: String, viewer: Dictionary) -> Array:
	if from == to: return []
	var dist := {from: 0.0}
	var prev := {}
	var open := [from]
	var done := {}
	while not open.is_empty():
		var current: String = open[0]
		for z in open:
			if float(dist[z]) < float(dist[current]): current = z
		open.erase(current)
		if current == to: break
		done[current] = true
		for next in links[current]:
			if done.has(next): continue
			var cost := float(links[current][next])
			if mode == "flank" and next != to and enemies_of(viewer).any(func(e): return e["zone"] == next and visible_to(viewer, e)): cost *= 10.0
			if mode in ["raid", "flank"]: cost *= 1.0 + 2.0 * (1.0 - float(zones[next].get("cover", 0.3)))
			var total := float(dist[current]) + cost
			if not dist.has(next) or total < float(dist[next]):
				dist[next] = total
				prev[next] = current
				if not next in open: open.append(next)
	if not prev.has(to): return []
	var path: Array = [to]
	while prev[path[0]] != from: path.push_front(prev[path[0]])
	return path


func _hops(a: String, b: String) -> int:
	if a == b: return 0
	var frontier := [a]
	var seen := {a: 0}
	while not frontier.is_empty():
		var current: String = frontier.pop_front()
		for next in links[current]:
			if seen.has(next): continue
			seen[next] = int(seen[current]) + 1
			if next == b: return int(seen[next])
			frontier.append(next)
	return 99


## 去目标区域除了直路之外是否还有一条不经过敌占区域、长度不超过直路两倍的路。
func _alt_route(unit: Dictionary, target_zone: String) -> bool:
	var direct := _length(_route(unit["zone"], target_zone, "", unit), unit["zone"])
	var around := _route(unit["zone"], target_zone, "flank", unit)
	if around.is_empty(): return false
	var length := _length(around, unit["zone"])
	var blocked := around.slice(0, around.size() - 1).any(func(z): return enemies_of(unit).any(func(e): return e["zone"] == z))
	return not blocked and length <= direct * 2.0 + 0.01 and (around.size() >= 2 or _hops(unit["zone"], target_zone) == 1)


func _length(path: Array, from: String) -> float:
	var total := 0.0
	var current := from
	for z in path:
		total += float(links[current][z])
		current = z
	return total


func _route_cover(from: String, to: String) -> float:
	var path := _route(from, to, "raid", {"side": "", "zone": from})
	if path.is_empty(): return float(zones[from].get("cover", 0.3))
	var total := 0.0
	for z in path: total += float(zones[z].get("cover", 0.3))
	return total / path.size()


func _route_alternatives(zone: String) -> int:
	return links[zone].size()


func _nearest_hidden(unit: Dictionary) -> Dictionary:
	var best: Dictionary = {}
	for e in enemies_of(unit):
		if not (e["hidden"] and not e["exposed"]): continue
		var hops := _hops(unit["zone"], e["zone"])
		var on_path: bool = e["zone"] in unit["path"]
		if hops > 1 and not on_path: continue
		if best.is_empty() or hops < _hops(unit["zone"], best["zone"]): best = e
	return best


func _start_flank(unit: Dictionary) -> void:
	var target := by_id(str(unit["target"]))
	if target.is_empty(): return
	unit["flank_total"] = _length(_route(unit["zone"], target["zone"], "flank", unit), unit["zone"])
	unit["flank_progress"] = 0.0
	unit["commit_share"] = -1.0


func _drop_bait(unit: Dictionary) -> void:
	var side: Dictionary = sides[unit["side"]]
	if side["spec"].has("baggage") and not side["baggage_dropped"]:
		side["baggage_dropped"] = true
		side["bait_zone"] = str(side["spec"]["baggage"])
		events.append({"tick": tick, "text": "%s弃辎重于%s诱敌" % [unit["officer"]["name"], zones[side["bait_zone"]]["name"]]})


# ---------------------------------------------------------------- 行军

func _move_all() -> void:
	for unit in units:
		if not active(unit) and not (unit["routed"] and not unit["escaped"]): continue
		var available := maxf(0.0, tick_hours - float(unit["pending"]))
		unit["pending"] = maxf(0.0, float(unit["pending"]) - tick_hours)
		unit["avail"] = available / tick_hours
		var posture := str(unit["posture"])
		unit["posture_ticks"][posture] = int(unit["posture_ticks"].get(posture, 0)) + 1
		if unit["routed"]: available = tick_hours
		if available <= 0.0: continue
		if _waits_for_flank(unit): continue
		var destination := _destination(unit)
		if destination.is_empty() or destination == unit["zone"]:
			unit["path"] = []
			continue
		var mode := "flank" if posture == "flank" else ("raid" if posture == "raid" else "")
		if unit["path"].is_empty() or unit["path"][-1] != destination: unit["path"] = _route(unit["zone"], destination, mode, unit)
		if unit["path"].is_empty(): continue
		# 离开有敌军的区域：脱离接触时挨一次追击。
		var pinned := enemies_of(unit).filter(func(e): return e["zone"] == unit["zone"] and visible_to(e, unit) and e["posture"] in ["assault", "pursue", "hold", "flank"])
		if not pinned.is_empty() and (unit["routed"] or posture in ["withdraw", "lure", "raid", "relieve", "flank"]):
			for e in pinned:
				var hit := int(Combat.strength(e["army"]) * Process.pursuit_rate(e["army"], unit["army"]) * (2.0 if unit["routed"] else 1.0) * tick_hours / 24.0)
				Combat.apply_loss(unit["army"], hit, true)
		var budget := available
		while budget > 0.0 and not unit["path"].is_empty():
			var next: String = unit["path"][0]
			var ctx := {"terrain": str(zones[next]["terrain"]), "task": "march_start"}
			var need := float(links[unit["zone"]][next]) * Process.march_time_factor(unit["army"], ctx) - float(unit["progress"])
			if posture == "flank": unit["flank_progress"] = float(unit["flank_progress"]) + minf(budget, need) / maxf(Process.march_time_factor(unit["army"], ctx), 0.1)
			if budget < need:
				unit["progress"] = float(unit["progress"]) + budget
				budget = 0.0
				break
			budget -= need
			unit["progress"] = 0.0
			unit["path"].pop_front()
			_enter(unit, next)
			if not active(unit) and not unit["routed"]: break
			if in_contact(unit) and not unit["routed"] and posture not in ["withdraw", "lure"]: break


## 主力等侧翼：友军正在侧击同一目标且就位比例未达本人 commit_readiness 时原地不动（急躁者门槛低，早投入）。
func _waits_for_flank(unit: Dictionary) -> bool:
	if unit["posture"] != "assault": return false
	var target := by_id(str(unit["target"]))
	if target.is_empty(): return false
	for f in friends_of(unit):
		if f["posture"] != "flank" or str(f["target"]) != str(target["id"]) or float(f["flank_total"]) <= 0.0: continue
		var share := clampf(float(f["flank_progress"]) / float(f["flank_total"]), 0.0, 1.0)
		if f["zone"] == target["zone"]: share = 1.0
		var gate := Conduct.commit_readiness(unit["army"], _ctx(unit, "assault"))
		if share < gate: return true
		if float(f["commit_share"]) < 0.0:
			f["commit_share"] = share
			var credit := Explain.credit(unit["army"], "commit投入")
			events.append({"tick": tick, "unit": unit["id"], "commit_share": snappedf(share, 0.01), "gate": snappedf(gate, 0.01), "text": "%s投入主力：侧翼就位 %d%%（本人门槛 %d%%%s）" % [unit["officer"]["name"], roundi(share * 100.0), roundi(gate * 100.0), "，" + credit if not credit.is_empty() else ""]})
	return false


func _enter(unit: Dictionary, zone_id: String) -> void:
	unit["zone"] = zone_id
	var side: Dictionary = sides[unit["side"]]
	if unit["routed"] or unit["posture"] == "withdraw":
		if zone_id == str(side["spec"].get("retreat", "")) and not enemies_of(unit).any(func(e): return e["zone"] == zone_id):
			unit["escaped"] = true
			events.append({"tick": tick, "text": "%s退至%s" % [unit["officer"]["name"], zones[zone_id]["name"]]})
			return
	# 隐蔽行军每进一个区域抽一次暴露；暴露后敌方全军知晓（粮囤一方进入警戒）。
	# 进入有敌军的区域不再抽暴露：是否被识破已在敌方感知里抽过，这里交给 _check_surprise 结算。
	var contact_zone := units.any(func(u): return u["side"] != unit["side"] and active(u) and u["zone"] == zone_id)
	if unit["posture"] in CONCEALED_POSTURES and not unit["open_march"] and not contact_zone:
		if unit["hidden"] and not unit["exposed"]:
			var cover := float(zones[zone_id].get("cover", 0.3))
			var ctx := _ctx(unit, str(unit["posture"]))
			ctx["task"] = "concealed_approach"
			if rng.randf() < Process.conceal_exposure(unit["army"], 1.0 - cover, ctx):
				_expose(unit, "行至%s被发现" % zones[zone_id]["name"])
	# 敌遗辎重：进入者当刻忙于收拢辎重，组织受损。
	var enemy_side: Dictionary = sides[other_side(unit["side"])]
	if zone_id == str(enemy_side["bait_zone"]) and not unit["looted"] and unit["posture"] in ["pursue", "assault"]:
		unit["looted"] = true
		unit["pending"] = float(unit["pending"]) + tick_hours
		unit["army"]["organization"] = maxf(0.0, float(unit["army"]["organization"]) - float(field.get("loot_org", 8)))
		events.append({"tick": tick, "text": "%s所部争抢辎重，阵形散乱" % unit["officer"]["name"]})
	_check_surprise(unit)


## 隐蔽部队与敌军同处一区：未被识破的一方遭突袭（组织损失、原方案失效、压力），突袭方首刻按侧击加成。
func _check_surprise(mover: Dictionary) -> void:
	for other in units:
		if other["side"] == mover["side"] or not active(other) or other["zone"] != mover["zone"]: continue
		for pair in [[mover, other], [other, mover]]:
			var hider: Dictionary = pair[0]
			var victim: Dictionary = pair[1]
			if not (hider["hidden"] and not hider["exposed"]): continue
			var known := bool(victim["army"].get("threat_rolls", {}).get(hider["id"], {}).get("known", false))
			_expose(hider, "伏兵发动" if hider == other else "突至")
			if known:
				events.append({"tick": tick, "text": "%s早有防备，%s未能得手" % [victim["officer"]["name"], hider["officer"]["name"]]})
				continue
			# 侧击时主力已提前投入（急躁）：敌军已转向，突然性只剩一部分。
			var share := 1.0
			if hider["posture"] == "flank" and float(hider["commit_share"]) >= 0.0 and float(hider["commit_share"]) < 0.8: share = float(hider["commit_share"]) / 0.8 * 0.5
			victim["army"]["organization"] = maxf(0.0, float(victim["army"]["organization"]) - float(field.get("ambush_org", 15)) * share)
			victim["plan_invalid"] = true
			victim["was_ambushed"] = true
			victim["ambushed_now"] = true
			victim["pressure"] = maxf(float(victim["pressure"]), float(Awareness.profile()["awareness"]["pressure_ambushed"]))
			hider["flank_mult_ticks"] = 1
			hider["flank_share"] = share
			events.append({"tick": tick, "text": "%s遭%s突袭" % [victim["officer"]["name"], hider["officer"]["name"]]})


func _expose(unit: Dictionary, why: String) -> void:
	if unit["exposed"]: return
	unit["exposed"] = true
	unit["hidden"] = false
	events.append({"tick": tick, "text": "%s%s" % [unit["officer"]["name"], why]})
	if unit["posture"] == "raid": sides[other_side(unit["side"])]["alerted"] = true


# ---------------------------------------------------------------- 交战

func _fight_all() -> void:
	var hits := {}
	var flanked := {}
	var before := {}
	for unit in units: before[unit["id"]] = Combat.strength(unit["army"])
	for unit in units:
		if not active(unit) or unit["hidden"] and not unit["exposed"]: continue
		var foes: Array = units.filter(func(e): return e["side"] != unit["side"] and e["zone"] == unit["zone"] and Combat.strength(e["army"]) > 0 and not e["escaped"] and not (e["hidden"] and not e["exposed"]))
		if foes.is_empty():
			unit["contact_ticks"] = 0
			continue
		unit["contact_ticks"] += 1
		# 对手全在溃逃或后撤（撤退、诱敌）时，这一刻是追击而不是对阵。
		var standing: Array = foes.filter(func(e): return not e["routed"] and not e["posture"] in RETREATING)
		if unit["routed"] or unit["posture"] in RETREATING: continue
		if standing.is_empty():
			_pursue(unit, foes)
			continue
		if unit["posture"] == "pursue": unit["pursuit_steps"] = 0
		var target: Dictionary = standing[0]
		for e in standing:
			if e["id"] == unit["target"]: target = e
		var zone: Dictionary = zones[unit["zone"]]
		var fort := 1.0
		if target["posture"] == "hold" and _fort_for(target["side"], unit["zone"]) > 0.0: fort = 1.0 + float(zone["fort"]) * (1.0 - clampf(float(unit["siege_prep"]), 0.0, 1.0))
		var mult := 1.0
		if int(unit["flank_mult_ticks"]) > 0:
			mult = 1.0 + (float(rules["combat"]["flank"]["flank_attack"]) - 1.0) * float(unit["flank_share"])
			flanked[target["id"]] = true
		var raw := float(Combat.losses_detail(unit["army"], target["army"], rules, str(zone["terrain"]), rng.randf_range(0.9, 1.1), fort)["raw"])
		hits[target["id"]] = float(hits.get(target["id"], 0.0)) + raw * float(field.get("intensity", 1.0)) * tick_hours / 24.0 * float(unit.get("avail", 1.0)) * mult
		if fort > 1.0:
			unit["siege_prep"] = float(unit["siege_prep"]) + tick_hours / 24.0 * 0.15 * Process.engineering_rate(unit["army"], _ctx(unit, "assault"))
	for unit in units:
		if int(unit["flank_mult_ticks"]) > 0: unit["flank_mult_ticks"] -= 1
	for id in hits:
		var unit := by_id(id)
		var amount := Combat.apply_loss(unit["army"], int(hits[id]), false, 0.0, Process.aura_strength(unit["army"], rules), 0.5, rules)
		var dealt := 0.0
		var enemy_before := 0.0
		for e in units:
			if e["side"] != unit["side"] and e["zone"] == unit["zone"]:
				dealt += float(hits.get(e["id"], 0.0))
				enemy_before += float(before[e["id"]])
		Combat.battle_morale(unit["army"], amount, dealt, int(before[id]), enemy_before, float(before[id]), enemy_before, flanked.has(id), Process.aura_strength(unit["army"], rules), 0.5, rules)
		var pressure := float(amount) / maxf(float(before[id]), 1.0) * float(Awareness.profile()["awareness"]["pressure_loss_scale"])
		unit["pressure"] = clampf(pressure + (float(Awareness.profile()["awareness"]["pressure_ambushed"]) if unit["ambushed_now"] else 0.0), 0.0, 1.0)
	for unit in units:
		if not active(unit): continue
		var army: Dictionary = unit["army"]
		var rout: Dictionary = field.get("rout", {"morale": 25, "organization": 15})
		if float(army["morale"]) < float(rout["morale"]) or float(army["organization"]) < float(rout["organization"]):
			unit["routed"] = true
			unit["posture"] = "withdraw"
			events.append({"tick": tick, "text": "%s所部溃散" % unit["officer"]["name"]})
		elif not hits.has(unit["id"]) and not in_contact(unit):
			unit["pressure"] = 0.0


## 追击：同区只剩溃兵/退兵时，每刻按 pursuit_rate 造成损失；超过安全深度后有反扑风险，超过本人追击上限即止步。
func _pursue(unit: Dictionary, foes: Array) -> void:
	if unit["posture"] not in ["pursue", "assault", "flank"]: return
	var limit := Conduct.pursuit_limit(unit["army"], _ctx(unit, "pursue"))
	if int(unit["pursuit_steps"]) >= limit:
		unit["posture"] = "hold"
		unit["plan_invalid"] = true
		events.append({"tick": tick, "text": "%s追至第 %d 步止步" % [unit["officer"]["name"], unit["pursuit_steps"]]})
		return
	for e in foes:
		Combat.apply_loss(e["army"], int(Combat.strength(unit["army"]) * Process.pursuit_rate(unit["army"], e["army"]) * tick_hours / 24.0 * 2.0), true)
	unit["pursuit_steps"] += 1
	unit["pursuit_max"] = maxi(int(unit["pursuit_max"]), int(unit["pursuit_steps"]))
	var safe := int(Process.profile()["conduct"]["pursuit_max_steps"])
	if int(unit["pursuit_steps"]) > safe and rng.randf() < float(field.get("counter_risk", 0.3)):
		Combat.apply_loss(unit["army"], int(Combat.strength(unit["army"]) * float(field.get("counter_loss", 0.06))), false, 1.0)
		unit["army"]["organization"] = maxf(0.0, float(unit["army"]["organization"]) - float(field.get("counter_org", 12)))
		unit["plan_invalid"] = true
		events.append({"tick": tick, "text": "%s追击过深，遭敌反扑" % unit["officer"]["name"]})


# ---------------------------------------------------------------- 日常

func _upkeep() -> void:
	for key in sides:
		var side: Dictionary = sides[key]
		if side["spec"].has("depot") and not side["alerted"] and not side["depot_burnt"]:
			var depot := str(side["spec"]["depot"]["zone"])
			for u in units:
				if u["side"] != key and active(u) and not (u["hidden"] and not u["exposed"]) and _hops(u["zone"], depot) <= 1:
					side["alerted"] = true
					events.append({"tick": tick, "text": "%s兵临%s附近，%s粮囤告急" % [u["officer"]["name"], zones[u["zone"]]["name"], side["name"]]})
					break
		side["supply_days"] = maxf(0.0, float(side["supply_days"]) - tick_hours / 24.0)
	for unit in units:
		if not active(unit): continue
		var army: Dictionary = unit["army"]
		var fighting := in_contact(unit)
		army["fatigue"] = minf(100.0, float(army["fatigue"]) + Process.fatigue_cost(army, float(field.get("daily_fatigue", 8)) * tick_hours / 24.0, fighting))
		if not fighting and unit["path"].is_empty():
			var recovery := Process.recovery(army)
			army["organization"] = minf(100.0, float(army["organization"]) + float(recovery["organization"]) * tick_hours / 24.0)
			army["fatigue"] = maxf(0.0, float(army["fatigue"]) - float(recovery["fatigue"]) * tick_hours / 24.0)
			army["morale"] = minf(100.0, float(army["morale"]) + float(recovery["morale"]) * tick_hours / 24.0)
			if unit["posture"] == "hold":
				var zone: Dictionary = zones[unit["zone"]]
				var cap := float(zone.get("fortifiable", 0.0))
				if cap > 0.0: zone["fort"] = minf(cap, float(zone["fort"]) + tick_hours / 24.0 * 0.08 * Process.engineering_rate(army, _ctx(unit, "hold")))
				for e in enemies_of(unit):
					if _hops(unit["zone"], e["zone"]) == 1 and e["posture"] == "hold" and float(zones[e["zone"]]["fort"]) > 0.0:
						unit["siege_prep"] = float(unit["siege_prep"]) + tick_hours / 24.0 * 0.3 * Process.engineering_rate(army, _ctx(unit, "assault"))
		if float(sides[unit["side"]]["supply_days"]) <= 0.0:
			army["morale"] = maxf(0.0, float(army["morale"]) - float(field.get("hunger_morale", 3)))
			army["organization"] = maxf(0.0, float(army["organization"]) - float(field.get("hunger_org", 2)))
	for key in sides:
		var side: Dictionary = sides[key]
		if not side["spec"].has("depot") or side["depot_burnt"]: continue
		var depot := str(side["spec"]["depot"]["zone"])
		var raiders := units.filter(func(u): return u["side"] != key and active(u) and u["zone"] == depot)
		var guards := units.filter(func(u): return u["side"] == key and active(u) and u["zone"] == depot)
		if not raiders.is_empty() and guards.is_empty():
			side["depot_burnt"] = true
			side["supply_days"] = minf(float(side["supply_days"]), float(field.get("burnt_supply_days", 1.0)))
			for u in units:
				if u["side"] == key and active(u):
					u["army"]["morale"] = maxf(0.0, float(u["army"]["morale"]) - float(field.get("burnt_morale", 15)))
					u["plan_invalid"] = true
			events.append({"tick": tick, "text": "%s粮囤被焚" % side["name"]})


# ---------------------------------------------------------------- 胜负

func _check_end() -> void:
	for key in sides:
		for objective in sides[key]["spec"].get("objectives", []):
			var zone := str(objective.get("zone", ""))
			var held := units.any(func(u): return u["side"] == key and active(u) and u["zone"] == zone) and not units.any(func(u): return u["side"] != key and active(u) and u["zone"] == zone)
			if str(objective["type"]) == "take" and held: sides[key]["taken"] = true
			if str(objective["type"]) == "relieve" and held and tick <= int(objective.get("deadline", field["ticks"])): sides[key]["relieved"] = true
	for key in sides:
		if not units.any(func(u): return u["side"] == key and active(u)):
			outcome = _judge()
			return


func _judge() -> Dictionary:
	var result := {"tick": tick, "sides": {}}
	for key in sides:
		var met: Array = []
		for objective in sides[key]["spec"].get("objectives", []): met.append({"type": objective["type"], "met": _objective_met(key, objective)})
		var alive := 0
		var escaped := 0
		for u in units:
			if u["side"] != key: continue
			if active(u): alive += Combat.strength(u["army"])
			if u["escaped"]: escaped += Combat.strength(u["army"])
		result["sides"][key] = {"objectives": met, "all_met": met.all(func(m): return m["met"]), "start": sides[key]["initial"], "alive": alive, "escaped": escaped, "loss": sides[key]["initial"] - alive - escaped, "depot_burnt": sides[key]["depot_burnt"]}
	var winners: Array = result["sides"].keys().filter(func(k): return result["sides"][k]["all_met"] and not result["sides"][other_side(k)]["all_met"])
	result["winner"] = winners[0] if winners.size() == 1 else "draw"
	return result


func _objective_met(side: String, objective: Dictionary) -> bool:
	var zone := str(objective.get("zone", ""))
	var own_here := units.any(func(u): return u["side"] == side and active(u) and u["zone"] == zone)
	var foe_here := units.any(func(u): return u["side"] != side and active(u) and u["zone"] == zone)
	var enemy := other_side(side)
	match str(objective["type"]):
		"hold": return own_here and not foe_here
		"take": return bool(sides[side].get("taken", false))
		"relieve": return bool(sides[side].get("relieved", false))
		"burn": return sides[enemy]["depot_burnt"]
		"protect": return not sides[side]["depot_burnt"]
		"destroy":
			var alive := 0
			for u in units:
				if u["side"] == enemy and active(u): alive += Combat.strength(u["army"])
			return float(alive) < float(sides[enemy]["initial"]) * float(objective.get("ratio", 0.4))
		"escape":
			var saved := 0
			for u in units:
				if u["side"] == side and (u["escaped"] or active(u)): saved += Combat.strength(u["army"])
			return float(saved) >= float(sides[side]["initial"]) * float(objective.get("ratio", 0.5))
	return false
