class_name OfficerIntent
extends RefCounted
## 人物战术姿态：每个人按自己看到的态势、自己的能力和性子，在八种姿态里选一个，并给出带来源的理由。
##
##   强攻 assault  坚守 hold  诱敌 lure  侧击 flank  奇袭 raid  追击 pursue  撤退 withdraw  救援 relieve
##
## 打分权重在 data/officers/intent_profile.json；态势特征来自 OfficerAwareness（已含料敌误差与人物自己的门槛）。
## 姿态不是技能：没有按钮、冷却、怒气或数值加成，执行效果由战场规则结算（侧击突然性读 campaign_rules.combat.flank）。
## 局限只经条件分支进入：参军进言是否采纳（刚愎）、压力失误（沉着、临危不乱）在这里；
## 协同未到位就投入（急躁、好谋少决）、追击深度（穷追、贪功）、脱离线（恋战、怯战）由调用方读 OfficerConduct。
## 将来接用户本地的 unit_brain：把 decide() 的 posture 映射到 unit_brain 的单位命令，reasons 写进 last_reason。

const Process = preload("res://scripts/officers/officer_process.gd")
const Conduct = preload("res://scripts/officers/officer_conduct.gd")
const Awareness = preload("res://scripts/officers/officer_awareness.gd")
const Explain = preload("res://scripts/officers/officer_explain.gd")
const Card = preload("res://scripts/officers/officer_card.gd")

const POSTURES := ["assault", "hold", "lure", "flank", "raid", "pursue", "withdraw", "relieve"]
## 姿态 → OfficerExplain.INTENTS / baseline_policy 的动作名，供面板与本地 unit_brain 对接。
const ACTION := {"assault": "engage", "hold": "hold", "lure": "withdraw", "flank": "flank", "raid": "flank", "pursue": "pursue", "withdraw": "withdraw", "relieve": "support"}
## 姿态对应的计划类型（特性条件 task.plan_type）。
const PLAN_TYPE := {"lure": "ambush", "flank": "flank", "raid": "feint_cover", "relieve": "relief", "assault": "assault", "hold": "defense", "pursue": "pursuit", "withdraw": "retreat"}
const SOURCE_SITUATION := "态势"
const SOURCE_SKILL := "属性"
const SOURCE_AXIS := "人格"
const SOURCE_TRAIT := "特性"
const SOURCE_ADVISER := "参军"


static func posture_name(posture: String) -> String:
	return str(Awareness.profile()["postures"].get(posture, {}).get("name", posture))


## 给全部姿态打分，返回 {posture, name, score, scores, reasons}；纯函数，同一输入同一输出。
static func decide(own: Dictionary, picture: Dictionary, ctx: Dictionary = {}) -> Dictionary:
	var postures: Dictionary = Awareness.profile()["postures"]
	var features: Dictionary = picture["features"]
	var scores := {}
	var terms_by := {}
	for posture in POSTURES:
		var spec: Dictionary = postures[posture]
		if spec.get("requires", []).any(func(f): return float(features.get(f, 0.0)) <= 0.0): continue
		if spec.has("requires_any") and not spec["requires_any"].any(func(f): return float(features.get(f, 0.0)) > 0.0): continue
		var terms := _terms(own, spec, features, ctx)
		var total := float(spec["base"])
		for term in terms: total += float(term["value"])
		scores[posture] = total
		terms_by[posture] = terms
	var best := "hold"
	for posture in scores:
		if float(scores[posture]) > float(scores.get(best, -INF)) + 1e-9: best = posture
	return {"posture": best, "name": posture_name(best), "score": float(scores.get(best, 0.0)), "scores": scores, "reasons": _reasons(best, terms_by.get(best, []), picture)}


## 参军进言：参军自己的判断与主将不同、且在参军眼里明显更好（差 ≥ 0.1）时进言，
## 主将按 OfficerConduct.advice_adoption 决定听不听（刚愎 −15pp，善辩等 +）。
static func consult(commander: Dictionary, decision: Dictionary, adviser: Dictionary, advice: Dictionary, rng: RandomNumberGenerator, ctx: Dictionary = {}) -> Dictionary:
	if adviser.is_empty() or advice.is_empty() or str(advice["posture"]) == str(decision["posture"]): return decision
	var own_view := float(advice["scores"].get(str(decision["posture"]), -INF))
	if float(advice["score"]) - own_view < 0.1: return decision
	var advice_ctx := ctx.duplicate()
	advice_ctx["lord_pride"] = float(commander.get("personality", {}).get("自尊", 50))
	advice_ctx["evidence_quality"] = clampf(1.0 - Process.intel_sigma(adviser, ctx) / float(Process.profile()["intel"]["sigma0"]) * 0.5, 0.0, 1.0)
	var p := Conduct.advice_adoption(commander, adviser, advice_ctx)
	var top := str(advice["reasons"][0]["text"]) if not advice["reasons"].is_empty() else ""
	var result := decision.duplicate(true)
	if rng.randf() < p:
		result["posture"] = advice["posture"]
		result["name"] = advice["name"]
		result["reasons"] = [{"text": "采纳参军%s的%s建议：%s（采纳概率 %d%%）" % [adviser.get("name", ""), advice["name"], top, roundi(p * 100.0)], "source": SOURCE_ADVISER, "value": p}] + advice["reasons"].slice(0, 2)
		result["advice"] = {"from": adviser.get("name", ""), "posture": advice["posture"], "adopted": true, "p": p}
	else:
		var why := Explain.credit(commander, "advice采纳", advice_ctx)
		result["reasons"] = result["reasons"] + [{"text": "未采纳参军%s的%s建议（采纳概率 %d%%%s）" % [adviser.get("name", ""), advice["name"], roundi(p * 100.0), "，" + why if not why.is_empty() else ""], "source": SOURCE_TRAIT if not why.is_empty() else SOURCE_ADVISER, "value": p}]
		result["advice"] = {"from": adviser.get("name", ""), "posture": advice["posture"], "adopted": false, "p": p}
	return result


## 压力失误：按 OfficerProcess.pressure_error（沉着；临危不乱等经 registry）抽一次，失误时本次维持原姿态（无原姿态则坚守）。
static func pressure_slip(own: Dictionary, decision: Dictionary, previous: String, pressure: float, rng: RandomNumberGenerator, ctx: Dictionary = {}) -> Dictionary:
	var slip_ctx := ctx.duplicate()
	slip_ctx["pressure"] = pressure
	slip_ctx["task"] = "command_issue"
	var p := Process.pressure_error(own, pressure, slip_ctx)
	if p <= 0.0 or rng.randf() >= p: return decision
	var fallback := previous if not previous.is_empty() and previous != str(decision["posture"]) else "hold"
	if fallback == str(decision["posture"]): return decision
	var result := decision.duplicate(true)
	result["posture"] = fallback
	result["name"] = posture_name(fallback)
	result["slip"] = {"intended": decision["posture"], "p": p}
	var credit := Explain.credit(own, "pressure失误", slip_ctx)
	result["reasons"] = [{"text": "压力 %.2f 下失误：本想%s，实际维持%s（失误概率 %d%%，沉着 %d%s）" % [pressure, decision["name"], result["name"], roundi(p * 100.0), int(Process.value(own, "沉着")), "，" + credit if not credit.is_empty() else ""], "source": SOURCE_SKILL, "value": p}] + decision["reasons"].slice(0, 2)
	return result


## 一个姿态的全部打分项：态势特征、能力（子属性 u 相对中心值）、人格轴。
static func _terms(own: Dictionary, spec: Dictionary, features: Dictionary, ctx: Dictionary) -> Array:
	var center := float(Awareness.profile()["capability_center"])
	var terms: Array = []
	for key in spec.get("features", {}):
		var value := float(spec["features"][key]) * float(features.get(key, 0.0))
		if not is_zero_approx(value): terms.append({"kind": "feature", "key": key, "value": value})
	for key in spec.get("skills", {}):
		var value := float(spec["skills"][key]) * (Process.u(own, key, ctx) - center) * 2.0
		terms.append({"kind": "skill", "key": key, "value": value, "level": Process.value(own, key, ctx)})
	for key in spec.get("axes", {}):
		var value := float(spec["axes"][key]) * (float(own.get("personality", {}).get(key, 50)) - 50.0) / 50.0
		if not is_zero_approx(value): terms.append({"kind": "axis", "key": key, "value": value, "axis": float(own.get("personality", {}).get(key, 50))})
	return terms


## 取对选择贡献最大的 3 项写成理由（正贡献优先），每条标来源。
static func _reasons(posture: String, terms: Array, picture: Dictionary) -> Array:
	var sorted := terms.duplicate()
	sorted.sort_custom(func(a, b): return float(a["value"]) > float(b["value"]))
	var picked: Array = sorted.filter(func(t): return float(t["value"]) > 0.02).slice(0, 3)
	if picked.is_empty() and not sorted.is_empty(): picked = [sorted[0]]
	var reasons: Array = []
	for term in picked: reasons.append({"text": _term_text(term, picture), "source": _source(term), "value": float(term["value"])})
	return reasons


static func _source(term: Dictionary) -> String:
	match str(term["kind"]):
		"skill": return SOURCE_SKILL
		"axis": return SOURCE_AXIS
	return SOURCE_SITUATION


static func _term_text(term: Dictionary, picture: Dictionary) -> String:
	var seen: Dictionary = picture["seen"]
	var key := str(term["key"])
	match str(term["kind"]):
		"skill": return "%s %d" % [Card.label(key), roundi(float(term["level"]))]
		"axis": return "%s %d" % [key, roundi(float(term["axis"]))]
	match key:
		"ratio_margin": return "估计兵力比 %.2f，高于本人迎战门槛 %.2f" % [seen["ratio"], seen["engage_ratio"]]
		"ratio_deficit": return "估计兵力比 %.2f，低于本人迎战门槛 %.2f" % [seen["ratio"], seen["engage_ratio"]]
		"enemy_shaken": return "判断敌军士气约 %d，已显动摇" % roundi(float(seen["enemy_morale_est"]))
		"target_fortified": return "目标有工事"
		"defensive_ground": return "据守之地有险可凭"
		"threat_known": return "察觉隐蔽敌军（%s）" % ("参军提醒" if seen.get("threat_by", "") == "adviser" else "本人识破") if bool(seen.get("threat_known", false)) else "已遭伏击"
		"enemy_retreating": return "敌军正在后退"
		"bait": return "敌遗辎重在前"
		"own_bait": return "有辎重可作诱饵"
		"lure_ground": return "身后有可设伏之地"
		"ambush_ready": return "伏兵未露，静待敌入"
		"flank_route": return "有迂回道路"
		"flank_open": return "敌侧翼暴露"
		"enemy_rash": return "判断敌将好斗（风险承受约 %d）" % roundi(float(seen["enemy_risk_read"]))
		"depot_exposed": return "敌粮囤守备估计约 %d 人，可袭" % roundi(float(seen["guard_est"]))
		"cover_route": return "袭粮路线有遮蔽"
		"ally_danger": return "友军告急"
		"ambush_terrain": return "前方地形遮蔽，恐有伏兵"
		"enemy_nearby": return "顾忌两程内未接战的敌军（约 %d 人，按 %d%% 计）" % [roundi(float(seen["nearby_est"]) / maxf(float(seen["nearby_weight"]), 0.01)), roundi(float(seen["nearby_weight"]) * 100.0)]
		"relief_target": return "受命解围"
		"time_pressure": return "时限将至"
		"org_low": return "组织 %d，近本人脱离线 %d" % [roundi(float(seen["organization"])), roundi(float(seen["disengage_line"]))]
		"supply_low": return "存粮仅 %.1f 日" % float(seen["supply_days"])
		"morale_low": return "己方士气 %d" % roundi(float(seen["morale"]))
	if key.begins_with("objective_"): return "任务：%s" % {"objective_hold": "守住要地", "objective_take": "夺取要地", "objective_relieve": "解围", "objective_escape": "全军退走", "objective_burn": "焚敌粮草", "objective_protect": "保住粮草", "objective_destroy": "击溃敌军", "objective_feint": "佯动牵制"}.get(key, key)
	return key
