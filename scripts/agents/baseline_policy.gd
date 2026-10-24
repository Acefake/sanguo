extends RefCounted

# Data-driven local decision policy. Keeps the historical `choose(context)` entry
# point; internals read data/agents/policy_weights.json and score every authorized
# candidate so the best option is explainable and personality-driven.

const Combat = preload("res://scripts/war/combat_system.gd")
const Roster = preload("res://scripts/agents/officer_context.gd")
const WEIGHTS_PATH := "res://data/agents/policy_weights.json"
const MELEE := ["engage", "flank", "pursue", "besiege"]
const TARGETED := ["engage", "flank", "pursue"]

static var _weights: Dictionary = {}
static var _warned := false


static func weights() -> Dictionary:
	if _weights.is_empty():
		var file := FileAccess.open(WEIGHTS_PATH, FileAccess.READ)
		var parsed: Variant = null if file == null else JSON.parse_string(file.get_as_text())
		if parsed is Dictionary:
			_weights = parsed
		else:
			_weights = default_weights()
			if not _warned:
				_warned = true
				push_warning("policy_weights.json 读取失败，使用内置默认权重")
	return _weights


static func version() -> int:
	return int(weights().get("version", 0))


static func default_weights() -> Dictionary:
	return {
		"version": 0,
		"base_score": {"continue": 35, "march": 30, "scout": 18, "hold": 15, "resupply": 8, "engage": 42, "besiege": 48, "withdraw": 5, "pursue": 30, "request_support": 25, "support": 20, "flank": 18},
		"march": {"progress": 12},
		"scout": {"unknown": 22},
		"hold": {"defend": 28, "reserve": 55, "reserve_danger": 1.5},
		"resupply": {"urgent": 80, "urgent_days": 12, "base": 8},
		"engage": {"risk": 14, "danger": 40, "decisive": 6, "suggested": 8},
		"flank": {"role": 58, "other": 18, "decisive": 6},
		"besiege": {"risk": 10, "defender": 38, "defender_risk": 16, "defender_floor": 0.6},
		"pursue": {"risk": 28, "decisive": 6},
		"support": {"role": 60, "other": 20},
		"request_support": {"danger": 15, "danger_floor": 0.8},
		"withdraw": {"crisis": 95, "base": 5, "returning": 120, "grain_days": 4, "morale": 30, "organization": 25, "threshold": 0.8, "risk_scale": 0.8, "ordered_threshold": 1.35, "ordered_risk_scale": 0.65, "danger_weight": 65},
		"factors": {},
		"personality_modifiers": {},
		"hysteresis": {"stay_bonus": 10},
		"target_value": {"kill": 1.0, "isolated": 1.0, "broken": 1.2, "broken_weak": 0.4, "counter": 2.0, "threat": 0.6, "grudge": 2.0, "suggested": 1.5, "isolated_radius": 2, "weak_ratio": 0.75},
		# These four sections are read by commander_rank, order_bias, should_ask_model and
		# Experience. Omitting them meant one failed JSON read silently turned every
		# commander into "maintain" and disabled the whole model gate.
		"commander": {
			"base_score": {"maintain": 20, "deploy": 45, "siege_mode": 12, "withdraw_corps": 30, "detach": 14, "assign_main_attack": 15, "assign_flank": 12, "assign_reserve": 10, "assign_regroup": 8, "assign_rear_guard": 15, "assign_raid_rear": 15, "assign_cut_supply": 13, "rotate_front": 6},
			"hysteresis": {"stay_bonus": 8, "hysteresis_bonus": 40},
			"siege": {"assault_bonus": 16, "blockade_bonus": 20, "blockade_grain": 20, "assault_preparation": 70},
			"deploy": {"assault_aggression": 12, "flanking_aggression": 12, "defensive_ratio": 1.4, "balanced": 5},
			"rotate": {"reserve_morale": 55, "reserve_organization": 50},
			"front": {"empty_bonus": 30, "guard_bonus": 25, "reserve_bonus": 25, "flank_bonus": 22, "regroup_bonus": 22},
			"raid": {"bonus": 15, "aggression": 60},
			"withdraw": {"ratio": 2.5, "ready_ratio": 0.55, "grain_days": 2, "majority_returning": 0.5, "bonus": 100, "hysteresis_bonus": 40},
			"factors": {"fatigue": 20, "returning": 15, "raid": 12, "enemy_ratio": -50, "ready_ratio": 40, "grain": -8, "siege_supply": 10}
		},
		"model_gate": {
			"high_risk": ["withdraw", "withdraw_corps", "besiege", "engage"],
			"always_keep": ["withdraw", "hold", "maintain", "withdraw_corps"],
			"max_candidates": 8,
			"top_k": 3,
			"veto_margin": 6.0
		},
		"intents": {},
		# Risk allowance scores the risky actions per level. Without this the only
		# effect of 冒险许可 was the 保守 candidate filter, so 放手 == 常规.
		"risk_allowance": {"conservative": {"engage": -4, "flank": -12, "pursue": -14, "besiege": -4}, "reckless": {"engage": 4, "flank": 10, "pursue": 12, "besiege": 4}},
		"experience": {"drift_enabled": false, "drift_per_battle": 3.0, "grudge_days": 20}
	}


static func choose(context: Dictionary, orders_aware: bool = true) -> Dictionary:
	if context.get("level","") == "adviser": return preload("res://scripts/agents/officer_brain.gd").choose(context)
	if context.get("level","") == "unit": return preload("res://scripts/agents/tactical_evaluator.gd").choose(context)
	var ranked := score(context, orders_aware)
	if ranked.is_empty(): return {}
	var best: Dictionary = ranked[0]
	return {"candidate_id": best["candidate"]["id"], "reason_summary": reason(context, best), "source": "baseline", "score_breakdown": best["breakdown"], "margin": margin(ranked), "score": best["score"]}


static func score(context: Dictionary, orders_aware: bool = true) -> Array:
	if context.get("level","") == "unit": return preload("res://scripts/agents/tactical_evaluator.gd").rank(context)
	var w := weights()
	var personality := effective_personality(context)
	var ranked: Array = []
	for candidate in context.get("candidates", []):
		var result := score_candidate(context, candidate, w, personality, orders_aware)
		ranked.append({"candidate": candidate, "score": result["score"], "breakdown": result["breakdown"]})
	ranked.sort_custom(func(a, b): return a["score"] > b["score"])
	return ranked


static func margin(ranked: Array) -> float:
	if ranked.size() < 2: return 999.0
	return float(ranked[0]["score"]) - float(ranked[1]["score"])


static func best_of(context: Dictionary, ids: Array) -> float:
	for entry in score(context):
		if str(entry["candidate"]["id"]) in ids: return float(entry["score"])
	return -INF


static func score_candidate(context: Dictionary, candidate: Dictionary, w: Dictionary, personality: Dictionary, orders_aware: bool = true) -> Dictionary:
	var kind: String = str(candidate.get("action", {}).get("type", ""))
	var breakdown: Dictionary = {}
	var base := float(w.get("base_score", {}).get(kind, 10.0))
	var score := base
	breakdown["基础:" + kind] = base
	var explicit: Dictionary = explicit_score(context, candidate, kind, w, personality)
	for key in explicit:
		score += float(explicit[key])
		breakdown[key] = float(explicit[key])
	var terms: Dictionary = factor_values(context, candidate, kind, personality, w)
	for name in terms:
		var value := float(terms[name])
		if is_zero_approx(value): continue
		var contribution := factor_weight(name, personality, w) * value
		score += contribution
		breakdown[name] = contribution
	if orders_aware:
		var order_terms: Dictionary = order_bias(context, candidate, kind, w)
		for key in order_terms:
			score += float(order_terms[key])
			breakdown[key] = float(order_terms[key])
	return {"score": score, "breakdown": breakdown}


static func order_bias(context: Dictionary, candidate: Dictionary, category: String, w: Dictionary) -> Dictionary:
	var orders: Dictionary = context.get("orders", {})
	if orders.is_empty(): return {}
	var out: Dictionary = {}
	var intent := str(orders.get("intent", "稳扎"))
	var bonus := float(w.get("intents", {}).get(intent, {}).get(category, 0.0))
	if not is_zero_approx(bonus): out["军令·" + intent] = bonus
	if category == "support":
		var relation_bonus: float = float({"同袍": 4.0, "猜忌": -2.0, "宿怨": -4.0}.get(str(candidate.get("relation", "中立")), 0.0))
		if not is_zero_approx(relation_bonus): out["同袍关系"] = relation_bonus
	var line: Dictionary = orders.get("retreat_line", {})
	var own: Dictionary = context.get("army", {})
	var initial := float(own.get("initial_strength", 0))
	if category == "withdraw" and initial > 0.0:
		var ratio := float(own.get("strength", 0)) / initial
		if float(line.get("strength", 0.0)) > 0.0 and ratio <= float(line["strength"]): out["军令撤退线"] = 45.0
		elif float(line.get("morale", 0.0)) > 0.0 and float(own.get("morale", 100)) <= float(line["morale"]): out["军令撤退线"] = 45.0
	# 冒险许可此前只影响违令概率与"保守"的候选过滤，"放手"与"常规"完全等价。
	# 这里按许可档位偏置高风险行动的评分，让三个档位真正分开。
	var table: Dictionary = w.get("risk_allowance", {})
	if not table.is_empty():
		var allowance := float({"保守": -1.0, "常规": 0.0, "放手": 1.0}.get(str(orders.get("risk_allowance", "常规")), 0.0))
		var weight := float(table.get({"保守": "conservative", "放手": "reckless"}.get(str(orders.get("risk_allowance", "常规")), ""), {}).get(category, 0.0))
		if not is_zero_approx(allowance) and not is_zero_approx(weight): out["军令·冒险许可"] = weight * allowance
	return out


static func effective_personality(context: Dictionary) -> Dictionary:
	var raw: Dictionary = context.get("officer", {}).get("personality", {})
	var out: Dictionary = {}
	for axis in Roster.AXES: out[axis] = float(raw.get(axis, 50))
	for axis in context.get("experience", {}).get("drift", {}):
		out[axis] = clampf(float(out[axis]) + float(context["experience"]["drift"][axis]), 0, 100)
	return out


static func risk_of(context: Dictionary, personality: Dictionary) -> float:
	var value: float = float(personality.get("风险承受", 50)) / 100.0
	if "冒进" in context.get("officer", {}).get("battle_traits", []): value = minf(1.0, value + 0.12)
	return value


static func danger_of(context: Dictionary) -> float:
	var strength := maxf(float(context.get("army", {}).get("strength", 0)), 1.0)
	var worst := 0.0
	var total := 0.0
	for enemy in context.get("enemies", []):
		var estimate := float(enemy.get("strength_estimate", 0))
		worst = maxf(worst, estimate / strength)
		total += estimate
	# Take the worse of "biggest single enemy" and "everything we know about". Reading
	# only the battlefield ratio let danger fall to 0 whenever no enemy was within the
	# scouting radius, which disabled the withdraw threshold entirely.
	var danger := maxf(worst, total / strength)
	if context.has("battlefield"): danger = maxf(danger, float(context["battlefield"].get("enemy_to_friendly_ratio", 0.0)))
	return danger


static func explicit_score(context: Dictionary, candidate: Dictionary, kind: String, w: Dictionary, personality: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	var danger := danger_of(context)
	var risk := risk_of(context, personality)
	var decisiveness := (float(personality.get("决断", 50)) - 50.0) / 50.0
	match kind:
		"march":
			out["推进"] = float(candidate.get("progress_gain", 0)) * float(w.get("march", {}).get("progress", 12))
		"scout":
			if not bool(context.get("target_known", false)): out["侦察未知"] = float(w.get("scout", {}).get("unknown", 22))
		"hold":
			if str(context.get("mission_type", "")) == "defend" and bool(context.get("at_objective", false)): out["守城"] = float(w.get("hold", {}).get("defend", 28))
			if str(context.get("operation", {}).get("role", "")) == "reserve" and danger < float(w.get("hold", {}).get("reserve_danger", 1.5)): out["预备待命"] = float(w.get("hold", {}).get("reserve", 55))
		"resupply":
			var urgent: bool = float(context.get("army", {}).get("grain_days", 99)) < float(w.get("resupply", {}).get("urgent_days", 12))
			out["补给"] = (float(w.get("resupply", {}).get("urgent", 80)) if urgent else float(w.get("resupply", {}).get("base", 8))) - float(w.get("base_score", {}).get("resupply", 8))
		"engage":
			out["接战勇气"] = risk * float(w.get("engage", {}).get("risk", 14)) - maxf(0.0, danger - 1.0) * float(w.get("engage", {}).get("danger", 40))
			out["决断"] = decisiveness * float(w.get("engage", {}).get("decisive", 6))
			if str(candidate.get("action", {}).get("enemy", "")) != "" and str(candidate.get("action", {}).get("enemy", "")) == str(context.get("operation", {}).get("suggested_target", "")):
				out["接战勇气"] = float(out["接战勇气"]) + float(w.get("engage", {}).get("suggested", 8))
		"flank":
			out["职责"] = (float(w.get("flank", {}).get("role", 58)) - float(w.get("base_score", {}).get("flank", 18))) if str(context.get("operation", {}).get("role", "")) == "flank" else 0.0
			out["决断"] = decisiveness * float(w.get("flank", {}).get("decisive", 6))
		"pursue":
			out["追击勇气"] = risk * float(w.get("pursue", {}).get("risk", 28)) + decisiveness * float(w.get("pursue", {}).get("decisive", 6))
		"besiege":
			var prior := maxf(0.0, float(candidate.get("defender_ratio", 0)) - float(w.get("besiege", {}).get("defender_floor", 0.6)))
			out["攻城勇气"] = risk * float(w.get("besiege", {}).get("risk", 10)) - prior * (float(w.get("besiege", {}).get("defender", 38)) - risk * float(w.get("besiege", {}).get("defender_risk", 16)))
		"support":
			out["协同"] = (float(w.get("support", {}).get("role", 60)) - float(w.get("base_score", {}).get("support", 20))) if str(context.get("operation", {}).get("role", "")) in ["support", "rear_guard"] else 0.0
		"request_support":
			out["求援"] = maxf(0.0, danger - float(w.get("request_support", {}).get("danger_floor", 0.8))) * float(w.get("request_support", {}).get("danger", 15))
		"withdraw":
			var wd: Dictionary = w.get("withdraw", {})
			var crisis: bool = float(context.get("army", {}).get("grain_days", 99)) < float(wd.get("grain_days", 4)) or float(context.get("army", {}).get("morale", 100)) < float(wd.get("morale", 30)) or float(context.get("army", {}).get("organization", 100)) < float(wd.get("organization", 25))
			var total: float = float(wd.get("crisis", 95)) if crisis else float(wd.get("base", 5))
			var ordered: bool = not context.get("operation", {}).is_empty()
			var threshold: float = (float(wd.get("ordered_threshold", 1.35)) + risk * float(wd.get("ordered_risk_scale", 0.65))) if ordered else (float(wd.get("threshold", 0.8)) + risk * float(wd.get("risk_scale", 0.8)))
			total += maxf(0.0, danger - threshold) * float(wd.get("danger_weight", 65))
			if bool(context.get("returning", false)): total = float(wd.get("returning", 120))
			out["撤退判定"] = total - float(w.get("base_score", {}).get("withdraw", 5))
		_:
			pass
	return out


static func factor_values(context: Dictionary, candidate: Dictionary, kind: String, personality: Dictionary, w: Dictionary) -> Dictionary:
	var terms: Dictionary = {}
	var forecast: Dictionary = candidate.get("forecast", {})
	var strength := maxf(float(context.get("army", {}).get("strength", 0)), 1.0)
	if kind in MELEE and forecast.has("kill_ratio"): terms["kill_ratio"] = _cap(w, "kill_ratio", float(forecast["kill_ratio"]))
	if (kind in MELEE or kind == "hold") and forecast.has("own_loss"): terms["own_loss"] = _cap(w, "own_loss", float(forecast["own_loss"]) / strength)
	if kind in ["march", "withdraw", "flank", "engage"] and forecast.has("flank_risk"): terms["flank_risk"] = _cap(w, "flank_risk", float(forecast["flank_risk"]))
	if kind in TARGETED:
		var value := target_value(context, candidate)
		if not is_zero_approx(value): terms["target_value"] = _cap(w, "target_value", value)
	if kind == "hold": terms["danger"] = minf(2.0, maxf(0.0, danger_of(context) - 1.0))
	if kind in ["scout", "hold", "besiege"]: terms["patience"] = 1.0
	if kind in ["besiege", "pursue"]: terms["ambition"] = 1.0
	if kind == "support": terms["empathy"] = 1.0
	if kind == "support" and _is_commander_ally(context, candidate): terms["loyalty"] = 1.0
	if kind in ["pursue", "besiege"]: terms["greed"] = 1.0
	if kind == "engage" and bool(_enemy(context, str(candidate.get("action", {}).get("enemy", ""))).get("routing", false)): terms["greed"] = 1.0
	if kind == "scout" and not bool(context.get("target_known", false)): terms["suspicion"] = 1.0
	if kind in ["engage", "flank"] and _exposed(context): terms["suspicion"] = float(terms.get("suspicion", 0.0)) + 1.0
	if kind == "pursue" and float(context.get("army", {}).get("grain_days", 99)) < 8.0: terms["discipline"] = 1.0
	if kind == "withdraw": terms["pride"] = 1.0
	var suggested := str(context.get("operation", {}).get("suggested_target", ""))
	if kind in TARGETED and suggested != "" and str(candidate.get("action", {}).get("enemy", "")) == suggested: terms["tolerance"] = 1.0
	var plan_active: bool = int(context.get("operation", {}).get("plan_until", 0)) > int(context.get("observation_revision", 0))
	var stays: bool = plan_active and candidate.get("action", {}) == context.get("current_action", {})
	var fits := role_fit(context, kind)
	if stays: terms["inertia"] = 1.0
	if fits: terms["role_fit"] = 1.0
	if fits or stays: terms["order"] = 1.0
	return terms


static func factor_weight(name: String, personality: Dictionary, w: Dictionary) -> float:
	var base := float(w.get("factors", {}).get(name, {}).get("weight", 0.0))
	for axis in w.get("personality_modifiers", {}):
		var offsets: Dictionary = w["personality_modifiers"][axis]
		if offsets.has(name): base += (float(personality.get(axis, 50)) - 50.0) * float(offsets[name])
	return base


static func _cap(w: Dictionary, name: String, value: float) -> float:
	var cap := float(w.get("factors", {}).get(name, {}).get("cap", 0.0))
	return clampf(value, 0.0, cap) if cap > 0.0 else value


static func role_fit(context: Dictionary, kind: String) -> bool:
	var role := str(context.get("operation", {}).get("role", ""))
	match role:
		"main_attack": return kind in ["engage", "continue", "flank"]
		"flank": return kind == "flank"
		"support": return kind == "support"
		"rear_guard": return kind == "support"
		"reserve": return kind == "hold"
		"withdraw": return kind in ["withdraw", "continue"]
		_: return false


static func target_value(context: Dictionary, candidate: Dictionary) -> float:
	var enemy_id := str(candidate.get("action", {}).get("enemy", ""))
	if enemy_id == "": return 0.0
	var enemy := _enemy(context, enemy_id)
	if enemy.is_empty(): return 0.0
	var tv: Dictionary = weights().get("target_value", {})
	var own: Dictionary = context.get("army", {})
	var strength := maxf(float(own.get("strength", 0)), 1.0)
	var value := float(tv.get("kill", 1.0)) * float(candidate.get("forecast", {}).get("kill_ratio", 1.0))
	if _target_isolated(context, enemy): value += float(tv.get("isolated", 1.0))
	if bool(enemy.get("routing", false)): value += float(tv.get("broken", 1.2))
	elif _target_weak(context, enemy): value += float(tv.get("broken_weak", 0.4))
	var mix: Dictionary = enemy.get("unit_mix_estimate", {})
	if not mix.is_empty(): value += float(tv.get("counter", 2.0)) * (Combat.counters({"units": own.get("units", {})}, {"units": mix}) - 1.0)
	value += float(tv.get("threat", 0.6)) * float(enemy.get("strength_estimate", 0)) / strength
	if _grudge(context, enemy_id): value += float(tv.get("grudge", 2.0))
	if str(context.get("operation", {}).get("suggested_target", "")) == enemy_id: value += float(tv.get("suggested", 1.5))
	return value


static func _enemy(context: Dictionary, id: String) -> Dictionary:
	for enemy in context.get("enemies", []):
		if str(enemy.get("id", "")) == id: return enemy
	return {}


static func _target_isolated(context: Dictionary, target: Dictionary) -> bool:
	var cell := int(target.get("tactical_cell", -1))
	if cell < 0: return false
	var radius := int(weights().get("target_value", {}).get("isolated_radius", 2))
	var neighbors := 0
	for enemy in context.get("enemies", []):
		if str(enemy.get("id", "")) == str(target.get("id", "")): continue
		var other := int(enemy.get("tactical_cell", -1))
		if other >= 0 and absi((other % 220) - (cell % 220)) + absi((other / 220) - (cell / 220)) <= radius: neighbors += 1
	return neighbors == 0


static func _target_weak(context: Dictionary, target: Dictionary) -> bool:
	var values: Array = []
	for enemy in context.get("enemies", []): values.append(float(enemy.get("strength_estimate", 0)))
	if values.is_empty(): return false
	values.sort()
	var median := float(values[values.size() / 2])
	return float(target.get("strength_estimate", 0)) < median * float(weights().get("target_value", {}).get("weak_ratio", 0.75))


static func _grudge(context: Dictionary, enemy_id: String) -> bool:
	var notes: Dictionary = context.get("experience", {}).get("enemy_notes", {})
	var note: Dictionary = notes.get(enemy_id, {})
	if not bool(note.get("beat_us", false)): return false
	var days := int(weights().get("experience", {}).get("grudge_days", 20))
	var now := int(context.get("observation_revision", 0))
	if days > 0 and now > 0 and now - int(note.get("last_seen", now)) > days: return false
	return true


static func _exposed(context: Dictionary) -> bool:
	for ally in context.get("allies", []):
		if bool(ally.get("can_support", false)): return false
	return not context.get("allies", []).is_empty()


static func _is_commander_ally(context: Dictionary, candidate: Dictionary) -> bool:
	var ally := str(candidate.get("action", {}).get("ally", ""))
	var commander := str(context.get("operation", {}).get("commander", ""))
	return ally != "" and ally == commander


static func reason(context: Dictionary, best: Dictionary) -> String:
	var candidate: Dictionary = best.get("candidate", {})
	var breakdown: Dictionary = best.get("breakdown", {})
	var entries: Array = []
	for key in breakdown:
		if str(key).begins_with("基础:") or float(breakdown[key]) <= 0.0: continue
		entries.append([float(breakdown[key]), str(key)])
	entries.sort_custom(func(a, b): return a[0] > b[0])
	var parts: Array = []
	for entry in entries.slice(0, 2):
		var phrase := _phrase(entry[1], context, candidate)
		if phrase != "": parts.append(phrase)
	if parts.is_empty(): parts.append(str(candidate.get("description", "按当前任务行动")))
	return "；".join(parts) + "。"


static func _phrase(key: String, context: Dictionary, candidate: Dictionary) -> String:
	if key.begins_with("军令"): return "遵从军令"
	match key:
		"kill_ratio": return "预计杀伤比 %.2f" % float(candidate.get("forecast", {}).get("kill_ratio", 0))
		"target_value": return "目标价值高"
		"patience": return "按兵持重"
		"ambition": return "进取求功"
		"empathy": return "顾及友军"
		"loyalty": return "忠义当先"
		"greed": return "贪图战果"
		"suspicion": return "慎察敌情"
		"inertia": return "保持既定计划"
		"role_fit": return "遵守作战职责"
		"order": return "遵从部署"
		"tolerance": return "接受建议目标"
		"flank_risk": return "戒备被夹击"
		"推进": return "按通路推进"
		"侦察未知": return "敌情未明"
		"接战勇气": return "风格果敢"
		"追击勇气": return "追击意愿高"
		"攻城勇气": return "攻城意愿高"
		"协同": return "协同友军"
		"求援": return "形势需要支援"
		"撤退判定": return "损失不可承受"
		"预备待命": return "保留预备队"
		"守城": return "履行守城职责"
		"补给": return "急需补充粮草"
		"基准": return "维持部署"
		"姿态": return "按敌情展开"
		"因敌换阵": return "因敌情换阵"
		"开侧翼": return "另开一路侧击"
		"归建整队": return "令归建整队"
		"奇袭倾向": return "遣队奇袭"
		"fatigue": return "前锋疲劳"
		"enemy_ratio": return "敌众我寡"
		"ready_ratio": return "可战兵力不足"
		"grain": return "粮草不继"
		"siege_supply": return "攻城补给不足"
		"撤退": return "可战兵力不足以再战"
		"迟滞": return "按既定决心继续撤退"
		"围困": return "守军即将断粮"
		"强攻": return "寻求破墙"
		"补预备": return "前锋疲惫且无预备队"
		"补线": return "正面战线空虚"
		"掩护": return "有部队正在撤退"
		"returning": return "部队已在脱离"
		"raid": return "奇袭意愿高"
		"同袍关系": return "顾及同袍"
		_: return ""


# ---- 军团主帅评分（阶段 C）----

# Action type -> policy_weights.json commander.base_score key.
const COMMANDER_CATEGORY := {
	"deploy_corps": "deploy",
	"set_siege_mode": "siege_mode"
}


static func commander_choose(context: Dictionary) -> Dictionary:
	var ranked := commander_rank(context)
	if ranked.is_empty(): return {}
	if bool(context.get("corps", {}).get("deployment_pending", false)):
		if not bool(context.get("background", false)) or int(context.get("deployment_age", 0)) >= 2:
			for entry in ranked:
				if str(entry["candidate"].get("action", {}).get("type", "")) == "deploy_corps": return commander_result(entry, ranked)
		return {"candidate_id": "maintain", "reason_summary": "军团保持集结，主帅正在制定分兵部署", "source": "commander-policy"}
	return commander_result(ranked[0], ranked)


static func rank(context: Dictionary, orders_aware: bool = true) -> Array:
	if context.get("level","") == "adviser": return preload("res://scripts/agents/officer_brain.gd").rank(context)
	if str(context.get("level", "")) == "commander": return commander_rank(context)
	return score(context, orders_aware)


static func commander_rank(context: Dictionary) -> Array:
	var w: Dictionary = weights().get("commander", {})
	if w.is_empty(): return []
	var personality := effective_personality(context)
	var ranked: Array = []
	for candidate in context.get("candidates", []):
		var result := commander_candidate(context, candidate, w, personality)
		ranked.append({"candidate": candidate, "score": result["score"], "breakdown": result["breakdown"]})
	ranked.sort_custom(func(a, b): return a["score"] > b["score"])
	return ranked


static func should_ask_model(context: Dictionary) -> bool:
	if context.get("level","") == "adviser": return context.get("crisis",false) or margin(preload("res://scripts/agents/officer_brain.gd").rank(context)) < 10
	if context.get("level","") == "unit":
		var ranked := score(context)
		return ranked.size() > 1 and (margin(ranked) < 10 or context.get("crisis",false) or context.get("current_plan",{}).get("template","") == "flank_then_engage")
	if not context.has("army"): return true
	var ranked := rank(context)
	if ranked.is_empty(): return true
	if ranked.size() < 2: return false
	var gate: Dictionary = weights().get("model_gate", {})
	var margin := float(ranked[0]["score"]) - float(ranked[1]["score"])
	var kind := str(ranked[0]["candidate"].get("action", {}).get("type", ""))
	var high_risk: bool = kind in gate.get("high_risk", [])
	return margin <= float(gate.get("margin", 12)) or high_risk or _desperate(context)


static func veto(context: Dictionary, candidate_id: String) -> Dictionary:
	if context.get("level","") == "unit":
		return {"ok":context.get("candidates",[]).any(func(c): return c["id"] == candidate_id),"reason":"模型只能选择当前请求内的规范战术"}
	var ranked := rank(context)
	if ranked.is_empty(): return {"ok": true}
	var top := float(ranked[0]["score"])
	for entry in ranked:
		if str(entry["candidate"]["id"]) == candidate_id:
			var line := float(weights().get("model_gate", {}).get("veto", 30))
			if top - float(entry["score"]) > line: return {"ok": false, "reason": "模型选择评分落后最高分%.0f" % (top - float(entry["score"]))}
			return {"ok": true}
	return {"ok": false, "reason": "模型选择了授权范围外的行动"}


static func _desperate(context: Dictionary) -> bool:
	var army: Dictionary = context.get("army", {})
	return float(army.get("morale", 100)) < 30.0 or float(army.get("organization", 100)) < 25.0 or float(army.get("grain_days", 99)) < 4.0 or bool(context.get("returning", false))


static func commander_result(entry: Dictionary, ranked: Array) -> Dictionary:
	return {"candidate_id": entry["candidate"]["id"], "reason_summary": commander_reason(entry), "source": "commander-policy", "score_breakdown": entry["breakdown"], "margin": margin(ranked)}


static func choose_commander_id(context: Dictionary) -> String:
	return str(commander_choose(context).get("candidate_id", ""))


static func commander_candidate(context: Dictionary, candidate: Dictionary, w: Dictionary, personality: Dictionary) -> Dictionary:
	var action: Dictionary = candidate.get("action", {})
	var kind: String = str(action.get("type", ""))
	var task: String = str(action.get("task", ""))
	# Deployment and siege commands use their own policy scoring categories.
	var category: String = str(COMMANDER_CATEGORY.get(kind, kind))
	if kind == "assign_task": category = "assign_" + task
	var base := float(w.get("base_score", {}).get(category, w.get("base_score", {}).get(kind, 10.0)))
	var breakdown: Dictionary = {"基础:" + category: base}
	var score := base
	var explicit := commander_explicit(context, candidate, kind, task, w, personality)
	for key in explicit:
		score += float(explicit[key])
		breakdown[key] = float(explicit[key])
	var terms := commander_terms(context, kind, task)
	for name in terms:
		if is_zero_approx(float(terms[name])): continue
		# The caps declared in policy_weights.json were never applied here, so an
		# outnumbered field multiplied its raw ratio straight into the score.
		var contribution := commander_factor_weight(name, personality, w) * _cap(w, name, float(terms[name]))
		score += contribution
		breakdown[name] = contribution
	var order_terms := order_bias(context, candidate, category, w)
	for key in order_terms:
		score += float(order_terms[key])
		breakdown[key] = float(order_terms[key])
	var advice_value := 0.0
	for advice in context.get("officer_advice",[]):
		var favored: bool = (advice["kind"] == "support" and (kind == "rotate_front" or task in ["support","rear_guard"])) or (advice["kind"] == "flank" and (task in ["flank","raid_rear"] or action.get("posture","") == "flanking")) or (advice["kind"] == "rally" and (kind == "rotate_front" or task == "regroup")) or (advice["kind"] == "observe" and kind == "maintain") or (advice["kind"] == "assault" and (task == "main_attack" or action.get("posture","") == "assault"))
		if favored: advice_value += clampf(float(advice.get("planning",50))/25.0,0,4)
	breakdown["参谋建议"] = minf(4,advice_value)
	score += float(breakdown["参谋建议"])
	return {"score": score, "breakdown": breakdown}


static func commander_explicit(context: Dictionary, candidate: Dictionary, kind: String, task: String, w: Dictionary, personality: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	var units: Array = context.get("corps", {}).get("units", [])
	var wd: Dictionary = w.get("withdraw", {})
	match kind:
		"maintain":
			out["基准"] = float(w.get("hysteresis", {}).get("stay_bonus", 8))
		"deploy_corps":
			out["姿态"] = deploy_score(context, candidate, w, personality)
		"withdraw_corps":
			if context.get("retreat_assessment",{}).get("reason","") == "攻城步兵不足": out["攻城无力"] = 100.0
			if context.get("retreat_assessment",{}).get("reason","") == "前军覆没，失去作战分队": out["前军覆没"] = 100.0
			if context.get("retreat_assessment", {}).get("reason", "") == "达到玩家撤退线": out["军令撤退线"] = 100.0
			var ratio := float(context.get("battlefield", {}).get("enemy_to_friendly_ratio", 0))
			var ready := float(context.get("battlefield", {}).get("friendly_ready_strength", 0))
			var strength := maxf(float(context.get("corps", {}).get("strength", 0)), 1.0)
			var fleeing := units.filter(func(u): return bool(u.get("returning", false))).size()
			if ratio > float(wd.get("ratio", 2.5)) or float(fleeing) > float(units.size()) * float(wd.get("majority_returning", 0.5)):
				out["撤退"] = float(wd.get("bonus", 100))
			elif ready / strength < float(wd.get("ready_ratio", 0.55)) or float(context.get("army", {}).get("grain_days", 99)) < float(wd.get("grain_days", 2)):
				out["撤退"] = float(wd.get("bonus", 100)) * 0.5
			if bool(context.get("withdraw_hysteresis", false)): out["迟滞"] = float(wd.get("hysteresis_bonus", 40))
		"set_siege_mode":
			var mode := str(candidate.get("action", {}).get("mode", ""))
			var siege_state: Dictionary = context.get("siege", {})
			var siege_cfg: Dictionary = w.get("siege", {})
			var wall := float(siege_state.get("wall", 0))
			var besieged_morale := float(siege_state.get("morale", 100))
			if mode == "blockade":
				if float(context.get("siege", {}).get("grain_days", 99)) < float(siege_cfg.get("blockade_grain", 12)):
					out["围困"] = float(siege_cfg.get("blockade_bonus", 20))
			elif mode == "assault":
				# 强攻只在城墙已破、守军将崩或准备已足时才划算，否则应当继续整阵。
				# Unconditional here made the choice a one-way ratchet back to assault.
				if wall <= 0.0 or besieged_morale < 30.0 or float(siege_state.get("preparation", 0)) >= float(siege_cfg.get("assault_preparation", 70)):
					out["强攻"] = float(siege_cfg.get("assault_bonus", 16))
		"detach":
			if task == "reserve" and _needs_reserve(w, units): out["补预备"] = float(w.get("front", {}).get("reserve_bonus", 25))
			if str(candidate.get("action", {}).get("task", "")) in ["raid_rear", "cut_supply"] and float(personality.get("野心", 50)) > float(w.get("raid", {}).get("aggression", 60)):
				out["奇袭倾向"] = float(w.get("raid", {}).get("bonus", 15))
		"assign_task":
			if task == "main_attack":
				if units.filter(func(u): return str(u.get("task", {}).get("type", "")) == "main_attack" and not bool(u.get("returning", false))).is_empty():
					out["补线"] = float(w.get("front", {}).get("empty_bonus", 30))
			elif task == "rear_guard":
				var fleeing := units.filter(func(u): return bool(u.get("returning", false))).size()
				var guard: bool = units.any(func(u): return str(u.get("task", {}).get("type", "")) == "rear_guard" and not bool(u.get("returning", false)))
				if fleeing > 0 and not guard: out["掩护"] = float(w.get("front", {}).get("guard_bonus", 25))
			elif task == "reserve":
				# Re-tasking an existing unit as the reserve. detach already had a branch,
				# assign_task did not, so this candidate could never outscore maintain.
				if _needs_reserve(w, units) and not units.any(func(u): return str(u.get("task", {}).get("type", "")) == "reserve" and not bool(u.get("returning", false))):
					out["补预备"] = float(w.get("front", {}).get("reserve_bonus", 25))
			elif task == "flank":
				# A flank is worth forming when a second front already exists, so the new
				# flank has something to envelop.
				var fronts := units.filter(func(u): return str(u.get("task", {}).get("type", "")) == "main_attack" and not bool(u.get("returning", false))).size()
				var flanks := units.filter(func(u): return str(u.get("task", {}).get("type", "")) == "flank" and not bool(u.get("returning", false))).size()
				if fronts > 0 and flanks < fronts and not context.get("enemies", []).is_empty():
					out["开侧翼"] = float(w.get("front", {}).get("flank_bonus", 22))
			elif task == "regroup":
				var broken: bool = units.any(func(u): return bool(u.get("returning", false)) or float(u.get("organization", 100)) < 30.0)
				if broken: out["归建整队"] = float(w.get("front", {}).get("regroup_bonus", 22))
			elif task in ["raid_rear", "cut_supply"] and float(personality.get("野心", 50)) > float(w.get("raid", {}).get("aggression", 60)):
				out["奇袭倾向"] = float(w.get("raid", {}).get("bonus", 15))
	if kind == "assign_task":
		for unit in units:
			if str(unit.get("id","")) == str(candidate.get("action",{}).get("unit","")):
				var fit := preload("res://scripts/war/troop_roles.gd").role_fit(unit,task)
				if not is_zero_approx(fit): out["兵种职责适配"] = fit

	return out


static func commander_terms(context: Dictionary, kind: String, task: String) -> Dictionary:
	var terms: Dictionary = {}
	var units: Array = context.get("corps", {}).get("units", [])
	if kind == "rotate_front":
		var fatigue := 0.0
		for unit in units:
			if str(unit.get("task", {}).get("type", "")) == "main_attack" and not bool(unit.get("returning", false)): fatigue = maxf(fatigue, float(unit.get("fatigue", 0)))
		terms["fatigue"] = fatigue / 100.0
	if kind == "assign_task" and task == "rear_guard" and units.any(func(u): return bool(u.get("returning", false))): terms["returning"] = 1.0
	if kind == "detach" or (kind == "assign_task" and task in ["raid_rear", "cut_supply"]): terms["raid"] = 1.0
	# enemy_ratio, ready_ratio, grain and siege_supply were declared in
	# policy_weights.json but never produced, which left 自尊 and 务实 with no effect
	# at all and made four factor weights dead configuration.
	var battlefield: Dictionary = context.get("battlefield", {})
	if kind != "maintain":
		# Outnumbered penalties discourage attacking, not the retreat or blockade
		# that responds to that danger. Equal forces incur no danger penalty.
		if kind not in ["withdraw_corps","set_siege_mode"]:
			terms["enemy_ratio"] = maxf(0,float(battlefield.get("enemy_to_friendly_ratio", 0.0))-1.0)
		if kind != "set_siege_mode":
			terms["ready_ratio"] = 1.0 - float(battlefield.get("friendly_ready_strength", 0)) / maxf(float(context.get("corps", {}).get("strength", 0)), 1.0)
	if kind in ["rotate_front"] or (kind == "assign_task" and task == "regroup"):
		terms["grain"] = _shortfall(context.get("army", {}).get("grain_days", 99), 24.0)
		terms["siege_supply"] = _shortfall(context.get("siege", {}).get("grain_days", 99), 20.0)
	return terms


# How far a day-count has fallen short of the given ceiling, for factors whose weight
# punishes running short rather than rewarding a large absolute value.
static func _shortfall(days: Variant, ceiling: float) -> float:
	return maxf(0.0, ceiling - minf(float(days), ceiling))


static func commander_factor_weight(name: String, personality: Dictionary, w: Dictionary) -> float:
	var base := float(w.get("factors", {}).get(name, {}).get("weight", 0.0))
	for axis in w.get("personality_modifiers", {}):
		var offsets: Dictionary = w["personality_modifiers"][axis]
		if offsets.has(name): base += (float(personality.get(axis, 50)) - 50.0) * float(offsets[name])
	return base


static func _needs_reserve(w: Dictionary, units: Array) -> bool:
	var rotate: Dictionary = w.get("rotate", {})
	var reserve: bool = units.any(func(u): return str(u.get("task", {}).get("type", "")) == "reserve" and not bool(u.get("returning", false)))
	if reserve: return false
	return units.any(func(u): return str(u.get("task", {}).get("type", "")) == "main_attack" and not bool(u.get("returning", false)) and (float(u.get("fatigue", 0)) >= float(rotate.get("fatigue", 70)) or float(u.get("organization", 100)) < float(rotate.get("organization", 40))))


static func deploy_score(context: Dictionary, candidate: Dictionary, w: Dictionary, personality: Dictionary) -> float:
	var cfg: Dictionary = w.get("deploy", {})
	var action: Dictionary = candidate.get("action", {})
	var score := 0.0
	var our: Dictionary = context.get("unit_mix", {})
	var enemy: Dictionary = context.get("enemy_unit_mix_estimate", {})
	var our_total := maxf(1.0, float(our.get("infantry", 0)) + float(our.get("archers", 0)) + float(our.get("cavalry", 0)))
	var enemy_total := maxf(1.0, float(enemy.get("infantry", 0)) + float(enemy.get("archers", 0)) + float(enemy.get("cavalry", 0)))
	var aggression := ((float(personality.get("野心", 50)) + float(personality.get("风险承受", 50)) + float(personality.get("决断", 50))) / 3.0 - 50.0) / 50.0
	var cunning := ((float(personality.get("野心", 50)) + float(personality.get("猜疑", 50)) + float(personality.get("决断", 50))) / 3.0 - 50.0) / 50.0
	match str(action.get("posture", "balanced")):
		"assault":
			score += aggression * 12.0
			if float(enemy.get("infantry", 0)) / enemy_total > 0.6: score += 4.0
			if float(our.get("cavalry", 0)) / our_total > 0.25: score += 4.0
		"flanking":
			score += cunning * 12.0
			if float(enemy.get("archers", 0)) / enemy_total > 0.4: score += 4.0
		_: score += 5.0
	return score


static func commander_reason(entry: Dictionary) -> String:
	var candidate: Dictionary = entry.get("candidate", {})
	var description := str(candidate.get("description", "保持军团部署"))
	var top: Array = []
	for key in entry.get("breakdown", {}):
		if str(key).begins_with("基础:") or float(entry["breakdown"][key]) <= 0.0: continue
		top.append([float(entry["breakdown"][key]), str(key)])
	top.sort_custom(func(a, b): return a[0] > b[0])
	for item in top.slice(0, 1):
		var phrase := _phrase(item[1], {}, candidate)
		if phrase != "": return description + "（" + phrase + "）"
	return description
