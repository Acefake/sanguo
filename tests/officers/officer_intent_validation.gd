extends SceneTree
## 人物决策层（OfficerAwareness / OfficerIntent / OfficerLeadership）的单元校验。
##
##   godot --headless --path . --script res://tests/officers/officer_intent_validation.gd
##
## 只依赖本仓库已有脚本，不加载 baseline_policy 或缺失的 unit_brain。

const Roster = preload("res://scripts/agents/officer_context.gd")
const Repository = preload("res://scripts/officers/officer_repository.gd")
const Awareness = preload("res://scripts/officers/officer_awareness.gd")
const Intent = preload("res://scripts/officers/officer_intent.gd")
const Leadership = preload("res://scripts/officers/officer_leadership.gd")
const Process = preload("res://scripts/officers/officer_process.gd")
const Conduct = preload("res://scripts/officers/officer_conduct.gd")
const Traits = preload("res://scripts/officers/trait_registry.gd")

const SOURCES := ["态势", "属性", "人格", "特性", "参军"]

var failures: Array[String] = []
var by_name := {}


func check(value: bool, message: String) -> void:
	if not value:
		failures.append(message)
		push_error(message)


func army(name: String, units: Dictionary = {"infantry": 6000, "archers": 2000, "cavalry": 2000}) -> Dictionary:
	var o: Dictionary = by_name[name]
	return {"name": name, "officer_id": o["id"], "skills": o["skills"], "trait_ids": o["trait_ids"].duplicate(), "personality": o["personality"], "units": units.duplicate(), "morale": 90.0, "organization": 90.0}


func picture(own: Dictionary, truth: Dictionary, seed: int, adviser: Dictionary = {}) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	return Awareness.perceive(own, truth, {}, rng, adviser)


func _initialize() -> void:
	var roster := Roster.new()
	roster.setup(Repository.cards(), {})
	for o in roster.officers.values(): by_name[o["name"]] = o

	# 1. 纯函数：同一画面同一结果；理由至多 3 条，来源只用登记过的标签。
	var truth := {"enemy_strength": 9000, "own_strength": 10000, "enemy_morale": 80, "enemy_risk": 70, "nearby_strength": 6000, "objectives": ["take"], "in_contact": true, "supply_days": 10}
	var yan := army("颜良")
	var view := picture(yan, truth, 7)
	check(JSON.stringify(Intent.decide(yan, view)) == JSON.stringify(Intent.decide(yan, view)), "decide 应是纯函数")
	for name in by_name:
		if str(by_name[name]["id"]).begins_with("local:") or str(by_name[name]["id"]).begins_with("militia:"): continue
		var own := army(name)
		var decision := Intent.decide(own, picture(own, truth, 7))
		check(decision["posture"] in Intent.POSTURES, "%s 选了未登记的姿态 %s" % [name, decision["posture"]])
		check(decision["reasons"].size() >= 1 and decision["reasons"].size() <= 3, "%s 理由条数应为 1–3" % name)
		for reason in decision["reasons"]: check(str(reason["source"]) in SOURCES, "%s 理由来源未登记：%s" % [name, reason["source"]])

	# 2. 同一真值、同一误差方向下，冒进与稳重的人选得不一样：颜良强攻，张郃/于禁坚守。
	var counts := {"颜良": {}, "张郃": {}, "于禁": {}}
	for name in counts:
		for seed in 40:
			var own := army(name)
			var posture := str(Intent.decide(own, picture(own, truth, seed))["posture"])
			counts[name][posture] = int(counts[name].get(posture, 0)) + 1
	print("INTENT: 同一态势 40 种子 颜良 %s 张郃 %s 于禁 %s" % [counts["颜良"], counts["张郃"], counts["于禁"]])
	check(int(counts["颜良"].get("assault", 0)) > int(counts["张郃"].get("assault", 0)) + 10, "颜良应比张郃更常强攻")
	check(int(counts["于禁"].get("hold", 0)) > int(counts["颜良"].get("hold", 0)) + 10, "于禁应比颜良更常坚守")

	# 3. 料敌决定估计误差：同一误差方向下，郭嘉（98）的兵力估计偏差小于颜良（57）。
	var err_guo := 0.0
	var err_yan := 0.0
	for seed in 60:
		var seen_guo: Dictionary = picture(army("郭嘉"), truth, seed)["seen"]
		var seen_yan: Dictionary = picture(army("颜良"), truth, seed)["seen"]
		err_guo += absf(float(seen_guo["enemy_est"]) - 9000.0 - 6000.0 * float(seen_guo["nearby_weight"]))
		err_yan += absf(float(seen_yan["enemy_est"]) - 9000.0 - 6000.0 * float(seen_yan["nearby_weight"]))
	check(err_guo < err_yan, "郭嘉估计误差应小于颜良（%.0f / %.0f）" % [err_guo, err_yan])
	check(float(picture(army("颜良"), truth, 1)["seen"]["nearby_weight"]) < float(picture(army("张郃"), truth, 1)["seen"]["nearby_weight"]), "风险承受高的人低估未接战敌军")

	# 4. 局限走条件分支：刚愎（程昱）采纳参军建议的频率低于去掉刚愎的同一人；压力失误频率与 pressure_error 一致。
	var cheng := army("程昱")
	var plain := cheng.duplicate()
	plain["trait_ids"] = cheng["trait_ids"].filter(func(id): return id != "flaw_stubborn")
	var adviser := army("荀攸")
	var own_choice := {"posture": "assault", "name": "强攻", "score": 1.0, "scores": {"assault": 1.0, "hold": 0.5}, "reasons": [{"text": "x", "source": "态势", "value": 1.0}]}
	var advice := {"posture": "hold", "name": "坚守", "score": 1.5, "scores": {"assault": 0.6, "hold": 1.5}, "reasons": [{"text": "y", "source": "态势", "value": 1.0}]}
	var adopted := {"with": 0, "without": 0}
	for seed in 400:
		for key in adopted:
			var rng := RandomNumberGenerator.new()
			rng.seed = seed
			var result := Intent.consult(cheng if key == "with" else plain, own_choice, adviser, advice, rng)
			if result["posture"] == "hold": adopted[key] += 1
	print("INTENT: 程昱采纳荀攸建议 有刚愎 %d/400 无刚愎 %d/400" % [adopted["with"], adopted["without"]])
	check(adopted["with"] < adopted["without"] - 30, "刚愎应明显降低采纳率")
	var slips := 0
	var p := Process.pressure_error(yan, 0.8, {"pressure": 0.8, "task": "command_issue"})
	for seed in 2000:
		var rng := RandomNumberGenerator.new()
		rng.seed = seed
		if Intent.pressure_slip(yan, own_choice, "hold", 0.8, rng).has("slip"): slips += 1
	check(absf(float(slips) / 2000.0 - p) < 0.03, "压力失误频率 %.3f 应接近 pressure_error %.3f" % [float(slips) / 2000.0, p])

	# 5. 增益拆解：总量 = (1+属性)(1+特性)−1；条件满足时特性来源出现并受上限约束；20 人在多种情境下全部合规。
	var zhang := army("张郃", {"infantry": 4000, "archers": 2000, "cavalry": 6000})
	var ctx := {"terrain": "plains", "subcommanders_assigned": true, "communication": true}
	var rows := Leadership.breakdown(zhang, ctx)
	var command: Dictionary = rows.filter(func(r): return r["channel"] == "command")[0]
	check(command["trait"]["sources"].any(func(s): return s["name"] == "合阵"), "张郃 12000 人分统畅通时号令应有合阵来源")
	for row in rows:
		var combined := (1.0 + float(row["attribute"]["value"])) * (1.0 + float(row["trait"]["value"])) - 1.0
		check(absf(combined - float(row["value"])) < 0.002, "%s 通道拆解不自洽：%.4f vs %.4f" % [row["label"], combined, row["value"]])
	var cao := army("曹操", {"infantry": 6000, "archers": 2000, "cavalry": 4000})
	var cao_command: Dictionary = Leadership.breakdown(cao, ctx).filter(func(r): return r["channel"] == "command")[0]
	check(cao_command["trait"]["sources"].any(func(s): return s["name"] == "过度负责") and float(cao_command["trait"]["value"]) < 0.0, "曹操过度负责应削弱号令")
	var contexts := [{"terrain": "plains"}, {"terrain": "forest", "visibility_cover": 0.7, "plan_type": "feint_cover", "feint_executed": true}, {"terrain": "hills", "plan_type": "ambush", "route_surveyed": true, "enemy_pattern_received": true}, {"terrain": "plains", "plan_type": "flank", "route_surveyed": true, "independent_groups": 3, "cross_checked": true, "plan_invalid_known": true, "route_alternatives": 3}, {"terrain": "plains", "engineering_type": "fortification", "subcommanders_assigned": true, "communication": true}]
	var violations: Array = []
	for name in by_name:
		if str(by_name[name]["id"]).begins_with("local:") or str(by_name[name]["id"]).begins_with("militia:"): continue
		for c in contexts:
			violations.append_array(Leadership.audit(army(name, {"infantry": 4000, "archers": 2000, "cavalry": 6000}), c))
			for row in Leadership.breakdown(army(name), c):
				for cap in row["trait"]["caps"]: check(absf(float(cap["applied"])) <= float(cap["cap"]) + 1e-6, "%s %s 合计超上限" % [name, cap["hook"]])
	check(violations.is_empty(), "增益上限违规：%s" % str(violations))
	print("LEADERSHIP: 张郃 " + Leadership.text(Leadership.notable(zhang, ctx)))
	print("OFFICER_INTENT_VALIDATION: " + ("PASS" if failures.is_empty() else "FAIL " + str(failures)))
	quit(0 if failures.is_empty() else 1)
