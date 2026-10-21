extends RefCounted
## 对照验收用的单场过程探针。
##
## 它不是游戏的战斗循环（那在 campaign_state / tactical_battlefield，依赖本仓库缺失的脚本），
## 而是把游戏里真实的结算模块按一场仗的顺序串起来：伏击暴露与识破、命令与侧翼就位、
## 主力投入、逐日交战（combat_system）、压力失误、脱离、溃败与追击。
## 人物差异只经 officer_process / officer_conduct / signature_traits 进入，同一种子下只换人。

const Combat = preload("res://scripts/war/combat_system.gd")
const Process = preload("res://scripts/officers/officer_process.gd")
const Conduct = preload("res://scripts/officers/officer_conduct.gd")
const Signature = preload("res://scripts/officers/signature_traits.gd")

const METRICS := ["commit_hour", "pursuit_depth", "disengages", "ambushed", "org_min", "loss_ratio", "objective"]
## 每项指标“更好”的方向：-1 越小越好，+1 越大越好，0 无优劣（只看是否不同）。
const BETTER := {"commit_hour": -1, "pursuit_depth": 0, "disengages": 0, "ambushed": -1, "org_min": 1, "loss_ratio": -1, "objective": 1}


## 本场景开战前的情境字段（特性触发条件读它）；伏击后的字段由 run 补上。
static func context(scenario: Dictionary, probe: Dictionary, settings: Dictionary, staff: Dictionary, renown_gap: float = 0.0) -> Dictionary:
	var terrain := str(probe.get("terrain", scenario.get("terrain", "plains")))
	return {"terrain": terrain, "enemy_renown_gap": renown_gap, "subcommanders_assigned": probe.has("flank_hours") or not staff.is_empty(), "independent_groups": 2 if not staff.is_empty() else 1, "urgency": 0.8 if probe.get("relief", false) else 0.3, "action": "engage", "communication": true, "route_alternatives": int(probe.get("route_alternatives", 1))}


## 跑一场；subject/opponent/staff 是 roster 里的人物字典（skills、trait_ids、personality）。
static func run(scenario: Dictionary, probe: Dictionary, settings: Dictionary, subject: Dictionary, opponent: Dictionary, staff: Dictionary, seed: int, rules: Dictionary) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var terrain := str(probe.get("terrain", scenario.get("terrain", "plains")))
	var a := _army(subject, scenario, str(settings["subject_side"]), 1.0)
	var b := _army(opponent, scenario, _other_side(scenario, str(settings["subject_side"])), float(probe.get("opponent_scale", 1.0)))
	if probe.get("siege", false): b["units"] = _scaled_units(b["units"], (float(scenario["strengths"][_other_side(scenario, str(settings["subject_side"]))]) + float(scenario.get("garrison", 0))) / maxf(float(Combat.strength(b)), 1.0))
	var a0 := Combat.strength(a)
	var b0 := Combat.strength(b)
	var renown_gap := Process.value(a, "名望") - Process.value(b, "名望")
	var ctx := context(scenario, probe, settings, staff, renown_gap)
	var m := {"commit_hour": 0.0, "pursuit_depth": 0, "disengages": 0, "ambushed": 0, "org_min": float(a["organization"]), "loss_ratio": 0.0, "objective": 0, "errors": 0, "routed": 0, "counter": 0, "omissions": 0}

	# 敌军隐藏兵力：先按料敌估计，再按人物的迎战门槛决定打不打。
	if probe.get("decide_engage", false):
		var estimate := Process.estimate(float(b0), a, rng, ctx)
		if float(a0) / maxf(estimate, 1.0) < Conduct.engage_ratio(a, ctx):
			m["objective"] = 1
			m["commit_hour"] = 24.0 * float(settings["max_days"])
			return m

	# 伏击：敌方在一个接触窗口里暴露一次；暴露后本军（或参军进言被采纳）解读为伏兵才算识破。
	var plan_invalid := false
	var a_lost_hours := 0.0
	var pressure := 0.0
	if probe.get("ambush", false):
		# 受伏率记精确概率（暴露×未识破），交战仍按抽样走，避免小幅特性被抽样噪声淹没。
		var exposure := Process.conceal_exposure(b, float(probe["cover"]), {"action": "flank"})
		var own_read := Process.ambush_read(a, ctx)
		var staff_read := 0.0
		if not staff.is_empty(): staff_read = Process.ambush_read(staff, ctx) * Conduct.advice_adoption(a, staff, {"lord_pride": float(subject.get("personality", {}).get("自尊", 50))})
		var detect := 1.0 - (1.0 - own_read) * (1.0 - staff_read)
		m["ambushed"] = 1.0 - exposure * detect
		if not (rng.randf() < exposure and rng.randf() < detect):
			plan_invalid = true
			pressure = 0.8
			a["organization"] = maxf(0.0, float(a["organization"]) - float(probe["ambush_org"]))
			a_lost_hours = float(probe["ambush_hours"])

	# 部署：命令整理+展开（伏击后还要重规划），侧翼迂回就位，按人物的就位度门槛投入。
	ctx["plan_invalid_known"] = plan_invalid
	ctx["pressure"] = pressure
	var commit := Process.order_delay_hours(a, ctx, plan_invalid) + a_lost_hours
	var flank_share := 0.0
	if probe.has("flank_hours"):
		var wing := a.duplicate(true)
		wing["units"] = {"infantry": 0, "archers": 0, "cavalry": int(a["units"]["cavalry"])}
		var wing_hours := Process.formation_hours(wing, ctx) + float(probe["flank_hours"]) * Process.march_time_factor(wing, ctx)
		flank_share = Conduct.commit_readiness(a, ctx)
		commit += flank_share * wing_hours
	# 计划遗漏：认知内已有的约束被漏掉（路线、渡口、坡度），发现后重新展开，侧翼也只到一半。
	if rng.randf() < Process.plan_omission(a, float(probe.get("plan_difficulty", settings["plan_difficulty"])), ctx):
		commit += Process.formation_hours(a, ctx)
		flank_share *= 0.5
		m["omissions"] = 1
	var b_delay := 0.0 if probe.get("ambush", false) else Process.order_delay_hours(b, {"terrain": terrain})
	var fortification := 1.0
	if probe.get("siege", false):
		var prep_days := ceili(float(probe["prep_points"]) / (float(probe["prep_rate"]) * Process.engineering_rate(a, ctx)))
		commit += 24.0 * prep_days
		fortification = float(probe["fortification"])
	var late := false
	if probe.get("relief", false):
		commit += float(probe["march_hours"]) * Process.march_time_factor(a, ctx)
		late = commit > float(probe["deadline_hours"])
		if late: fortification = float(probe["fortification"])
	m["commit_hour"] = commit

	# 侧翼没到位就投入，敌军先转向正面，侧击的突然性整场都找不回来。
	var flank_bonus := float(settings["flank_bonus"]) * (1.0 if flank_share >= 0.8 else flank_share / 0.8 * 0.5)
	var frontal := float(settings["frontal_penalty"]) if probe.has("flank_hours") and flank_share < 0.8 else 1.0
	a["action"] = {"type": "engage"}
	b["action"] = {"type": "engage"}
	var start_day := floori(commit / 24.0)
	var hold_days := int(probe.get("hold_days", 0))
	var held := 0
	for day in range(start_day, int(settings["max_days"])):
		var a_hours := 24.0 - (fmod(commit, 24.0) if day == start_day else 0.0)
		var b_hours := 24.0 - (b_delay if day == start_day and b_delay < 24.0 else 0.0)
		if day == start_day:
			Signature.first_contact(a, b, true)
			if plan_invalid: a_hours = maxf(a_hours, 1.0)
		if int(m.get("pending_error", 0)) == 1:
			a_hours *= 0.75
			m["pending_error"] = 0
		var a_before := Combat.strength(a)
		var b_before := Combat.strength(b)
		var hit_b := int(float(Combat.losses_detail(a, b, rules, terrain, rng.randf_range(0.9, 1.1), fortification)["raw"]) * a_hours / 24.0 * (1.0 + (flank_bonus if probe.has("flank_hours") else 0.0)))
		var hit_a := int(float(Combat.losses_detail(b, a, rules, terrain, rng.randf_range(0.9, 1.1))["raw"]) * b_hours / 24.0 * (frontal if day == start_day else 1.0))
		hit_b = Combat.apply_loss(b, hit_b, false, 0.0, 0.0, 0.5, rules)
		hit_a = Combat.apply_loss(a, hit_a, false, 0.0, Process.aura_strength(a, rules), 0.5, rules)
		Combat.battle_morale(a, hit_a, hit_b, a_before, b_before, a_before, b_before, plan_invalid and day == start_day, Process.aura_strength(a, rules), 0.5, rules)
		Combat.battle_morale(b, hit_b, hit_a, b_before, a_before, b_before, a_before, false, 0.0, 0.5, rules)
		m["org_min"] = minf(float(m["org_min"]), float(a["organization"]))
		# 压力：当日伤亡比例与被伏，次日按沉着抽一次失误。
		pressure = clampf(float(hit_a) / maxf(a_before, 1) * 6.0 + (0.5 if plan_invalid and day == start_day else 0.0), 0.0, 1.0)
		for side in [a, b]: side["fatigue"] = minf(100.0, float(side["fatigue"]) + Process.fatigue_cost(side, float(settings["daily_fatigue"]), true))
		ctx["pressure"] = pressure
		if rng.randf() < Process.pressure_error(a, pressure, ctx):
			m["errors"] += 1
			m["pending_error"] = 1
		if float(b["morale"]) < float(settings["rout_morale"]) or float(b["organization"]) < float(settings["rout_organization"]) or Combat.strength(b) < float(b0) * float(settings["victory_strength"]):
			m["objective"] = 0 if late else 1
			_pursue(a, b, m, ctx, settings, rng)
			break
		if float(a["morale"]) < float(settings["rout_morale"]) or float(a["organization"]) < float(settings["rout_organization"]):
			m["routed"] = 1
			Combat.apply_loss(a, int(Combat.strength(b) * Process.pursuit_rate(b, a) * 2.0), true)
			break
		if float(a["organization"]) < Conduct.disengage_line(a, ctx):
			m["disengages"] = 1
			Combat.apply_loss(a, int(Combat.strength(b) * Process.pursuit_rate(b, a)), true)
			break
		held += 1
		if hold_days > 0 and held >= hold_days:
			m["objective"] = 1
			break
		Process.end_day(a)
	m["loss_ratio"] = float(a0 - Combat.strength(a)) / maxf(float(b0 - Combat.strength(b)), 1.0)
	m.erase("pending_error")
	return m


## 敌溃后追击：每步按追击速率造成损失；越过最大安全深度后每步有反扑风险。
static func _pursue(a: Dictionary, b: Dictionary, m: Dictionary, ctx: Dictionary, settings: Dictionary, rng: RandomNumberGenerator) -> void:
	var safe := int(Process.profile()["conduct"]["pursuit_max_steps"])
	for step in Conduct.pursuit_limit(a, ctx):
		if Combat.strength(b) <= 0: break
		Combat.apply_loss(b, int(Combat.strength(a) * Process.pursuit_rate(a, b)), true)
		m["pursuit_depth"] = step + 1
		if step >= safe and rng.randf() < float(settings["counter_risk"]):
			m["counter"] = 1
			Combat.apply_loss(a, int(Combat.strength(a) * float(settings["counter_loss"])), false, 0.0)
			a["organization"] = maxf(0.0, float(a["organization"]) - float(settings["counter_org"]))
			m["org_min"] = minf(float(m["org_min"]), float(a["organization"]))
			break


static func _other_side(scenario: Dictionary, side: String) -> String:
	for key in scenario["strengths"]:
		if key != side: return key
	return side


static func _army(officer: Dictionary, scenario: Dictionary, side: String, scale: float) -> Dictionary:
	var total := float(scenario["strengths"][side]) * scale
	var counts := {"infantry": 0, "archers": 0, "cavalry": 0}
	var troops: Array = scenario["troops"]
	for type in troops: counts[type] += 1
	var units := {}
	for type in counts: units[type] = int(total * counts[type] / float(troops.size()))
	var condition: Dictionary = scenario.get("side_condition", {}).get(side, {})
	return {"id": side, "officer_id": str(officer.get("id", side)), "name": str(officer.get("name", side)), "units": units, "skills": officer.get("skills", {}).duplicate(), "trait_ids": officer.get("trait_ids", []).duplicate(), "personality": officer.get("personality", {}), "morale": 100.0, "organization": float(condition.get("organization", 100)), "fatigue": float(condition.get("fatigue", 0)), "training": 70, "equipment": 60, "action": {"type": "hold"}}


static func _scaled_units(units: Dictionary, factor: float) -> Dictionary:
	var result := {}
	for type in units: result[type] = int(float(units[type]) * factor)
	return result
