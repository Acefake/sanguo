class_name OfficerAwareness
extends RefCounted
## 态势感知：把战场真值变成“这个人看到的态势”。
##
## 敌军兵力按料敌的 σ 估计（σ 即 OfficerProcess.intel_sigma，多源研判/核报经 intel 条件生效；接战后 σ 减半），
## 敌军士气与敌将性子按同一 σ 加噪。对同一支敌军，误差方向只抽一次（标准正态 z，记在 own.estimates），
## 之后只随 σ 缩放：判断会一直错在同一个方向，直到接战看清，而不是每次复核都重新掷骰；隐蔽敌军先按其奇袭抽暴露，再按本人（及参军进言被采纳时）料敌抽识破。
## 迎战门槛、脱离线读 OfficerConduct，所以同一真值下不同人物得到的“兵力占优/该撤了”可以不同。
## 输出 features 供 OfficerIntent 打分，seen 供理由与报告引用。

const Process = preload("res://scripts/officers/officer_process.gd")
const Conduct = preload("res://scripts/officers/officer_conduct.gd")
const PROFILE_PATH := "res://data/officers/intent_profile.json"
const OBJECTIVES := ["hold", "take", "relieve", "escape", "burn", "protect", "destroy", "feint"]

static var _profile: Dictionary = {}


static func profile() -> Dictionary:
	if _profile.is_empty(): _profile = JSON.parse_string(FileAccess.get_file_as_string(PROFILE_PATH))
	return _profile


## own：部队字典（skills、trait_ids、personality、morale、organization、units）。
## truth：战场真值，字段见 docs/战场AI检验说明.md「态势字段」。ctx：特性条件用的情境（intel.* 等）。
## adviser：参军的人物视角（同一部队字典换上参军的 skills/trait_ids/personality），可为空。
static func perceive(own: Dictionary, truth: Dictionary, ctx: Dictionary, rng: RandomNumberGenerator, adviser: Dictionary = {}) -> Dictionary:
	var tuning: Dictionary = profile()["awareness"]
	var intel := ctx.duplicate()
	intel["task"] = "intel_interpret"
	var sigma := Process.intel_sigma(own, intel) * (float(tuning["contact_sigma"]) if truth.get("in_contact", false) else 1.0)
	var key := str(truth.get("enemy_key", "enemy"))
	var enemy_true := float(truth.get("enemy_strength", 0))
	var enemy_est := maxf(0.0, enemy_true * (1.0 + sigma * _z(own, key + ":strength", rng)))
	var friendly := float(truth.get("own_strength", Process.strength(own))) + float(truth.get("ally_strength", 0))
	var engage := Conduct.engage_ratio(own, ctx)
	var line := Conduct.disengage_line(own, ctx)
	var morale_est := clampf(float(truth.get("enemy_morale", 100)) + sigma * 100.0 * float(tuning["morale_noise"]) * _z(own, key + ":morale", rng), 0.0, 100.0)
	var risk_read := clampf(float(truth.get("enemy_risk", 50)) + sigma * float(tuning["risk_read_noise"]) * _z(own, key + ":risk", rng), 0.0, 100.0)
	var threat := _threat(own, truth, intel, rng, adviser)
	# 识破的隐蔽敌军也算进对面的兵力（按同一 σ 估计），兵力比随之下降。
	if threat["known"] and not truth.get("hidden", {}).is_empty():
		var hidden_est := maxf(0.0, float(Process.strength(truth["hidden"]["army"])) * (1.0 + sigma * _z(own, str(truth["hidden"]["id"]) + ":strength", rng)))
		enemy_est += hidden_est
		enemy_true += float(Process.strength(truth["hidden"]["army"]))
	# 未接战的近处敌军：风险承受高的人只算一部分（冒进者低估援军），谨慎者全算。
	var nearby_weight := clampf(1.0 - maxf(0.0, _axis(own, "风险承受")) * float(tuning["nearby_discount"]), 0.0, 1.0)
	var nearby_est := maxf(0.0, float(truth.get("nearby_strength", 0)) * (1.0 + sigma * _z(own, "nearby:strength", rng))) * nearby_weight
	if enemy_true > 0.0:
		enemy_est += nearby_est
		enemy_true += float(truth.get("nearby_strength", 0)) * nearby_weight
	var ratio := friendly / maxf(enemy_est, 1.0) if enemy_true > 0.0 else 9.0
	var depot: Dictionary = truth.get("depot", {})
	var guard_est := maxf(0.0, float(depot.get("guard", 0)) * (1.0 + sigma * _z(own, "depot:guard", rng))) if not depot.is_empty() else 0.0
	var objectives: Array = truth.get("objectives", [])
	var deadline := int(truth.get("deadline_ticks", 0))
	var features := {
		"ratio_margin": clampf((ratio - engage) / 0.5, -1.0, 1.0),
		"ratio_deficit": clampf((engage - ratio) / 0.5, 0.0, 1.0),
		"enemy_shaken": clampf((70.0 - morale_est) / 40.0, 0.0, 1.0) if enemy_true > 0.0 else 0.0,
		"target_fortified": clampf(float(truth.get("target_fort", 0.0)), 0.0, 1.0),
		"defensive_ground": clampf(float(truth.get("defense", 0.0)), 0.0, 1.0),
		"threat_known": 1.0 if threat["known"] or bool(truth.get("ambushed", false)) else 0.0,
		"enemy_retreating": 1.0 if truth.get("enemy_retreating", false) else 0.0,
		"bait": 1.0 if truth.get("bait", false) else 0.0,
		"own_bait": 1.0 if truth.get("own_bait", false) else 0.0,
		"lure_ground": float(truth.get("lure_ground", 0.0)),
		"flank_route": 1.0 if truth.get("flank_route", false) else 0.0,
		"flank_open": 1.0 if truth.get("flank_open", false) else 0.0,
		"enemy_rash": clampf((risk_read - 50.0) / 50.0, -1.0, 1.0),
		"depot_route": 0.0 if depot.is_empty() else 1.0,
		"depot_exposed": 0.0 if depot.is_empty() else clampf(1.5 - guard_est / maxf(float(truth.get("own_strength", Process.strength(own))), 1.0), 0.0, 1.0),
		"cover_route": float(depot.get("cover", 0.0)),
		"ally_danger": clampf(float(truth.get("ally_danger", 0.0)), 0.0, 1.0),
		"relief_target": 1.0 if truth.get("relief_target", false) else 0.0,
		"time_pressure": clampf(1.0 - float(truth.get("ticks_left", deadline)) / maxf(float(deadline), 1.0), 0.0, 1.0) if deadline > 0 else 0.0,
		"org_low": clampf((line + 10.0 - float(own.get("organization", 100))) / 20.0, 0.0, 1.0),
		"supply_low": clampf((3.0 - float(truth.get("supply_days", 30))) / 3.0, 0.0, 1.0),
		"morale_low": clampf((60.0 - float(own.get("morale", 100))) / 40.0, 0.0, 1.0),
		"in_contact": 1.0 if truth.get("in_contact", false) else 0.0,
		"ambush_ready": 1.0 if truth.get("ambush_ready", false) else 0.0,
		"enemy_nearby": clampf(nearby_est / maxf(friendly, 1.0), 0.0, 1.0),
		"ambush_terrain": clampf(float(truth.get("target_cover", 0.0)), 0.0, 1.0) if float(truth.get("target_cover", 0.0)) >= 0.5 else 0.0,
	}
	for kind in OBJECTIVES: features["objective_" + kind] = 1.0 if kind in objectives else 0.0
	var seen := {"nearby_est": nearby_est, "nearby_weight": nearby_weight, "ratio": ratio, "enemy_est": enemy_est, "enemy_true": enemy_true, "engage_ratio": engage, "disengage_line": line, "enemy_morale_est": morale_est, "enemy_risk_read": risk_read, "sigma": sigma, "threat_known": threat["known"], "threat_by": threat["by"], "guard_est": guard_est, "organization": float(own.get("organization", 100)), "morale": float(own.get("morale", 100)), "supply_days": float(truth.get("supply_days", 30))}
	return {"features": features, "seen": seen}


static func _axis(own: Dictionary, name: String) -> float:
	return (float(own.get("personality", {}).get(name, 50)) - 50.0) / 50.0


## 某项判断的误差方向：第一次用到时抽一个标准正态数并记住。
static func _z(own: Dictionary, key: String, rng: RandomNumberGenerator) -> float:
	var memo: Dictionary = own.get("estimates", {})
	if not memo.has(key): memo[key] = clampf(rng.randfn(0.0, 1.0), -2.5, 2.5)
	own["estimates"] = memo
	return float(memo[key])


## 隐蔽敌军：结果记在 own.threat_rolls，看破之后不再重抽。
## 暴露读隐蔽方的奇袭与潜行等；识破读本人料敌，参军识破则按采纳概率转达。
static func _threat(own: Dictionary, truth: Dictionary, intel: Dictionary, rng: RandomNumberGenerator, adviser: Dictionary) -> Dictionary:
	var hidden: Dictionary = truth.get("hidden", {})
	if hidden.is_empty(): return {"known": false, "by": ""}
	# 斥候是持续的：隐蔽敌军在近处的每一刻都有一次看破的机会，看破后记住，不再重抽。
	var rolls: Dictionary = own.get("threat_rolls", {})
	var key := str(hidden.get("id", "hidden"))
	if rolls.has(key) and bool(rolls[key]["known"]): return rolls[key]
	var cover := float(hidden.get("cover", 0.5))
	var exposure := Process.conceal_exposure(hidden["army"], 1.0 - cover, {"action": "flank", "visibility_cover": cover, "task": "concealed_approach", "plan_type": str(hidden.get("plan_type", "ambush")), "feint_executed": bool(hidden.get("feint_executed", false))})
	var result := {"known": false, "by": ""}
	if rng.randf() < exposure:
		if rng.randf() < Process.ambush_read(own, intel): result = {"known": true, "by": "self"}
		elif not adviser.is_empty() and rng.randf() < Process.ambush_read(adviser, intel) and rng.randf() < Conduct.advice_adoption(own, adviser, {"lord_pride": float(own.get("personality", {}).get("自尊", 50))}):
			result = {"known": true, "by": "adviser"}
	rolls[key] = result
	own["threat_rolls"] = rolls
	return result
