extends SceneTree
## 检验战场跑测器：逐个战场、逐个试验、固定种子多次推演，汇总人物决策与结果，并做硬断言。
##
##   godot --headless --path . --script res://tests/war/proving/battlefield_runner.gd -- [--seeds=24] [--only=<id>] [--out=/abs/summary.json] [--log=/abs/decisions.jsonl]
##
## 断言（任一不过即 FAIL，退出码 1）：
##   1. 数据引用无误（ProvingGroundData.check）。
##   2. 每个战场 compare 列出的试验对：同一部队的决策分布（每场各决策点所选姿态的占比）差异显著
##      （同种子配对置换检验 p<0.01 且总变差 ≥0.10）。按刻计的姿态占比只作参考，一并写进报告。
##   3. expect 列出的定向预期成立（某些姿态占比更高、某项结果更多/更少）。
##   4. 镜像试验（mirror_of）：同一人物放到对称一侧，姿态分布总变差 <0.15。
##   5. 增益上限：每个决策点的 OfficerLeadership.audit 为空（特性单来源与合计都在 hooks.json 上限内）。
##   6. 无禁用机制：新模块源码与数据里没有技能按钮、冷却、怒气、等级压制等字段，姿态表只含偏好不含数值加成。
##   7. 可复现：每个战场第一个试验的前 3 个种子重跑，结果逐字相同。

const Data = preload("res://scripts/war/proving/battlefield_data.gd")
const Sim = preload("res://scripts/war/proving/battlefield_sim.gd")
const Intent = preload("res://scripts/officers/officer_intent.gd")
const Leadership = preload("res://scripts/officers/officer_leadership.gd")

const P_SIGNIFICANT := 0.01
const TVD_SIGNIFICANT := 0.10
const TVD_MIRROR := 0.15
const PERMUTATIONS := 400
const SCANNED := ["res://scripts/officers/officer_awareness.gd", "res://scripts/officers/officer_intent.gd", "res://scripts/officers/officer_leadership.gd", "res://scripts/war/proving/battlefield_sim.gd", "res://scripts/war/proving/battlefield_data.gd", "res://data/officers/intent_profile.json"]
const FORBIDDEN := ["cooldown", "冷却", "rage", "怒气", "skill_button", "战法", "active_skill", "主动技能", "level_gap", "等级压制", "mana"]
const POSTURE_KEYS := ["name", "base", "requires", "requires_any", "features", "skills", "axes"]

var failures: Array[String] = []
var seeds := 24
var rules: Dictionary
var log_file: FileAccess


func _initialize() -> void:
	var only := ""
	var out := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--seeds="): seeds = int(arg.trim_prefix("--seeds="))
		elif arg.begins_with("--only="): only = arg.trim_prefix("--only=")
		elif arg.begins_with("--out="): out = arg.trim_prefix("--out=")
		elif arg.begins_with("--log="): log_file = FileAccess.open(arg.trim_prefix("--log="), FileAccess.WRITE)
	rules = Sim.rules_config()
	var report := {"seeds": seeds, "battlefields": [], "static": _static_checks()}
	for id in Data.ids():
		if not only.is_empty() and id != only: continue
		report["battlefields"].append(_battlefield(id))
	report["failures"] = failures
	if not out.is_empty():
		var file := FileAccess.open(out, FileAccess.WRITE)
		file.store_string(JSON.stringify(report, " ", false))
	print("BATTLEFIELD_AI: " + ("PASS" if failures.is_empty() else "FAIL %d 项 %s" % [failures.size(), str(failures)]))
	quit(0 if failures.is_empty() else 1)


func _fail(text: String) -> void:
	failures.append(text)
	print("  FAIL " + text)


func _battlefield(id: String) -> Dictionary:
	var field := Data.load_field(id)
	for error in Data.check(field): _fail("%s 数据：%s" % [id, error])
	print("== %s %s" % [id, field["name"]])
	var trials := {}
	var order: Array = []
	for trial in field["trials"]:
		trials[trial["id"]] = _trial(field, trial)
		order.append(trial["id"])
	var comparisons: Array = []
	for pair in field.get("compare", []):
		var unit := str(pair[2]) if pair.size() > 2 else str(field["subject"])
		comparisons.append(_compare(id, trials[pair[0]], trials[pair[1]], unit))
	var expects: Array = []
	for expect in field.get("expect", []): expects.append(_expect(id, trials, expect))
	var mirrors: Array = []
	for trial in field["trials"]:
		if trial.has("mirror_of"): mirrors.append(_mirror(id, field, trials[trial["mirror_of"]], trials[trial["id"]]))
	var repro := _reproducible(field)
	if not repro["same"]: _fail("%s 同种子重跑结果不一致" % id)
	return {"id": id, "name": field["name"], "summary": field["summary"], "history": field.get("history", ""), "checks": field.get("checks", []), "subject": field["subject"], "trials": order.map(func(t): return trials[t]), "comparisons": comparisons, "expects": expects, "mirrors": mirrors, "reproducible": repro}


## 一个试验跑 seeds 次，汇总每支部队的姿态占比（按刻计）、决策计数、理由频次、结果，以及种子 0 的完整决策记录。
func _trial(field: Dictionary, trial: Dictionary) -> Dictionary:
	var battlefield := Data.with_trial(field, trial)
	var subject := str(trial.get("subject", field["subject"]))
	var per_unit := {}
	var wins := {}
	var side_loss := {}
	var objectives := {}
	var sample: Array = []
	var events: Array = []
	var audits := 0
	for seed in seeds:
		var result := Sim.run(battlefield, seed, rules)
		var winner := str(result["outcome"]["winner"])
		wins[winner] = int(wins.get(winner, 0)) + 1
		for side in result["outcome"]["sides"]:
			var row: Dictionary = result["outcome"]["sides"][side]
			side_loss[side] = float(side_loss.get(side, 0.0)) + float(row["loss"]) / float(row["start"]) / seeds
			for objective in row["objectives"]:
				var key := "%s.%s" % [side, objective["type"]]
				objectives[key] = float(objectives.get(key, 0.0)) + (1.0 if objective["met"] else 0.0) / seeds
		var by_unit := {}
		for unit in result["units"]: by_unit[unit["id"]] = unit
		for unit in result["units"]: _accumulate(per_unit, unit, result, seed)
		for decision in result["decisions"]:
			if not decision["audit"].is_empty():
				audits += 1
				_fail("%s/%s 增益超上限：%s" % [field["id"], trial["id"], decision["audit"]])
			var stats: Dictionary = per_unit[decision["unit"]]
			stats["decisions"][decision["posture"]] = int(stats["decisions"].get(decision["posture"], 0)) + 1
			for reason in decision["reasons"]:
				var text := "［%s］%s" % [reason["source"], _reason_key(str(reason["text"]))]
				var bucket: Dictionary = stats["reasons"].get(decision["posture"], {})
				bucket[text] = int(bucket.get(text, 0)) + 1
				stats["reasons"][decision["posture"]] = bucket
			if decision.get("advice", {}).has("from"):
				stats["advice"][("adopted" if decision["advice"]["adopted"] else "rejected")] = int(stats["advice"].get("adopted" if decision["advice"]["adopted"] else "rejected", 0)) + 1
			if decision.get("slip", {}).has("intended"): stats["slips"] += 1
			if log_file != null:
				var line: Dictionary = decision.duplicate()
				line["battlefield"] = field["id"]
				line["trial"] = trial["id"]
				line["seed"] = seed
				line["result"] = by_unit[decision["unit"]]
				log_file.store_line(JSON.stringify(line))
		if seed == 0:
			for decision in result["decisions"]:
				var row: Dictionary = decision.duplicate()
				row["result"] = {"loss": by_unit[decision["unit"]]["loss"], "start": by_unit[decision["unit"]]["start"], "routed": by_unit[decision["unit"]]["routed"], "escaped": by_unit[decision["unit"]]["escaped"]}
				row.erase("audit")
				sample.append(row)
			events = result["events"]
			objectives["sample_winner"] = winner
	for unit_id in per_unit: _finish(per_unit[unit_id])
	var officers := {}
	for side in battlefield["sides"]:
		for unit in battlefield["sides"][side]["units"]: officers[unit["id"]] = {"officer": Data.officer(str(unit["officer"]))["name"], "adviser": Data.officer(str(unit.get("adviser", ""))).get("name", "") if not str(unit.get("adviser", "")).is_empty() else "", "side": side}
	var subject_unit := _unit_spec(battlefield, subject)
	var subject_army := {"name": Data.officer(str(subject_unit["officer"]))["name"], "units": subject_unit["troops"], "skills": Data.officer(str(subject_unit["officer"]))["skills"], "trait_ids": Data.officer(str(subject_unit["officer"])).get("trait_ids", []), "personality": Data.officer(str(subject_unit["officer"])).get("personality", {})}
	var buffs := Leadership.breakdown(subject_army, {"terrain": "plains"})
	print("  %s：%s 胜负 %s 亡损 %s 姿态 %s" % [trial["id"], trial["label"], wins, _rounded(side_loss), _top(per_unit[subject]["choice_share"])])
	return {"id": trial["id"], "label": trial["label"], "subject": subject, "officers": officers, "wins": wins, "loss_rate": _rounded(side_loss), "objectives": _rounded(objectives), "units": per_unit, "subject_buffs": buffs, "subject_traits": subject_army["trait_ids"], "sample": sample.filter(func(d): return d["unit"] == subject).slice(0, 14), "sample_all": sample.slice(0, 40), "events": events, "audit_violations": audits}


func _unit_spec(battlefield: Dictionary, id: String) -> Dictionary:
	for side in battlefield["sides"]:
		for unit in battlefield["sides"][side]["units"]:
			if unit["id"] == id: return unit
	return {}


func _accumulate(per_unit: Dictionary, unit: Dictionary, result: Dictionary, seed: int) -> void:
	if not per_unit.has(unit["id"]):
		per_unit[unit["id"]] = {"officer": unit["officer"], "adviser": unit["adviser"], "side": unit["side"], "runs": 0, "shares": [], "choice_shares": [], "first": {}, "decisions": {}, "reasons": {}, "advice": {}, "slips": 0, "loss": 0.0, "routed": 0.0, "escaped": 0.0, "ambushed": 0.0, "pursuit_steps": 0.0, "burn": 0.0, "commit_share": [], "start": unit["start"]}
	var stats: Dictionary = per_unit[unit["id"]]
	stats["runs"] += 1
	var total := 0
	for p in unit["postures"]: total += int(unit["postures"][p])
	var share := {}
	for p in unit["postures"]:
		if str(p).is_empty(): continue
		share[p] = float(unit["postures"][p]) / maxf(float(total), 1.0)
	stats["shares"].append(share)
	var chosen := {}
	var count := 0
	for decision in result["decisions"]:
		if decision["unit"] != unit["id"]: continue
		chosen[decision["posture"]] = int(chosen.get(decision["posture"], 0)) + 1
		count += 1
	var choice := {}
	for p in chosen: choice[p] = float(chosen[p]) / float(count)
	stats["choice_shares"].append(choice)
	for decision in result["decisions"]:
		if decision["unit"] == unit["id"]:
			stats["first"][decision["posture"]] = int(stats["first"].get(decision["posture"], 0)) + 1
			break
	stats["loss"] += float(unit["loss"]) / float(unit["start"])
	stats["routed"] += 1.0 if unit["routed"] else 0.0
	stats["escaped"] += 1.0 if unit["escaped"] else 0.0
	stats["ambushed"] += 1.0 if unit["ambushed"] else 0.0
	stats["pursuit_steps"] += float(unit["pursuit_steps"])
	var enemy_burnt := false
	for side in result["outcome"]["sides"]:
		if side != unit["side"] and result["outcome"]["sides"][side]["depot_burnt"]: enemy_burnt = true
	stats["burn"] += 1.0 if enemy_burnt else 0.0
	for event in result["events"]:
		if str(event.get("unit", "")) == unit["id"] and event.has("commit_share"): stats["commit_share"].append(float(event["commit_share"]))


func _finish(stats: Dictionary) -> void:
	var runs := float(stats["runs"])
	var mean := {}
	for share in stats["shares"]:
		for p in share: mean[p] = float(mean.get(p, 0.0)) + float(share[p]) / runs
	stats["posture_share"] = _rounded(mean)
	var choice_mean := {}
	for share in stats["choice_shares"]:
		for p in share: choice_mean[p] = float(choice_mean.get(p, 0.0)) + float(share[p]) / runs
	stats["choice_share"] = _rounded(choice_mean)
	for key in ["loss", "routed", "escaped", "ambushed", "pursuit_steps", "burn"]: stats[key] = snappedf(float(stats[key]) / runs, 0.001)
	var commits: Array = stats["commit_share"]
	stats["commit_share_mean"] = snappedf(commits.reduce(func(a, b): return a + b, 0.0) / commits.size(), 0.001) if not commits.is_empty() else -1.0
	stats["commit_count"] = commits.size()
	var trimmed := {}
	for posture in stats["reasons"]:
		var bucket: Dictionary = stats["reasons"][posture]
		var keys := bucket.keys()
		keys.sort_custom(func(a, b): return int(bucket[a]) > int(bucket[b]))
		trimmed[posture] = keys.slice(0, 4).map(func(k): return [k, bucket[k]])
	stats["reasons"] = trimmed


## 理由去掉具体数字，便于跨种子合并计数（“估计兵力比 1.23，高于…1.05”→“估计兵力比 #，高于…#”）。
func _reason_key(text: String) -> String:
	var regex := RegEx.create_from_string("[0-9]+(\\.[0-9]+)?")
	return regex.sub(text, "#", true)


## 配对置换检验：同一种子下两个试验的姿态占比向量，随机交换标签，统计均值总变差不小于观测值的比例。
func _compare(id: String, a: Dictionary, b: Dictionary, unit: String) -> Dictionary:
	var sa: Array = a["units"][unit]["choice_shares"]
	var sb: Array = b["units"][unit]["choice_shares"]
	var observed := _tvd(_mean(sa), _mean(sb))
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([id, a["id"], b["id"], unit])
	var hits := 0
	for i in PERMUTATIONS:
		var xa: Array = []
		var xb: Array = []
		for k in sa.size():
			if rng.randf() < 0.5:
				xa.append(sa[k])
				xb.append(sb[k])
			else:
				xa.append(sb[k])
				xb.append(sa[k])
		if _tvd(_mean(xa), _mean(xb)) >= observed - 1e-9: hits += 1
	var p := float(hits + 1) / float(PERMUTATIONS + 1)
	var ok := p < P_SIGNIFICANT and observed >= TVD_SIGNIFICANT
	if not ok: _fail("%s %s vs %s（%s）决策分布差异不显著：TVD=%.3f p=%.4f" % [id, a["id"], b["id"], unit, observed, p])
	return {"a": a["id"], "b": b["id"], "unit": unit, "officer_a": a["units"][unit]["officer"], "officer_b": b["units"][unit]["officer"], "choice_a": a["units"][unit]["choice_share"], "choice_b": b["units"][unit]["choice_share"], "share_a": a["units"][unit]["posture_share"], "share_b": b["units"][unit]["posture_share"], "tvd": snappedf(observed, 0.001), "tick_tvd": snappedf(_tvd(a["units"][unit]["posture_share"], b["units"][unit]["posture_share"]), 0.001), "p": snappedf(p, 0.0001), "pass": ok}


func _expect(id: String, trials: Dictionary, expect: Dictionary) -> Dictionary:
	var a: Dictionary = trials[expect["trial"]]["units"][expect["unit"]]
	var ok := false
	var detail := ""
	if expect.has("more_than"):
		var b: Dictionary = trials[expect["more_than"]["trial"]]["units"][expect["unit"]]
		var va := 0.0
		var vb := 0.0
		for p in expect["more_than"]["postures"]:
			va += float(a["choice_share"].get(p, 0.0))
			vb += float(b["choice_share"].get(p, 0.0))
		ok = va > vb + 0.05
		detail = "%s 决策占比 %.2f vs %.2f" % ["/".join(expect["more_than"]["postures"].map(func(x): return Intent.posture_name(x))), va, vb]
	if expect.has("first_more"):
		var b: Dictionary = trials[expect["first_more"]["trial"]]["units"][expect["unit"]]
		var va := 0.0
		var vb := 0.0
		for p in expect["first_more"]["postures"]:
			va += float(a["first"].get(p, 0)) / float(a["runs"])
			vb += float(b["first"].get(p, 0)) / float(b["runs"])
		ok = va > vb + 0.05
		detail = "开局选%s的场次 %.2f vs %.2f" % ["/".join(expect["first_more"]["postures"].map(func(x): return Intent.posture_name(x))), va, vb]
	for key in ["metric_more", "metric_less"]:
		if not expect.has(key): continue
		var b: Dictionary = trials[expect[key]["trial"]]["units"][expect["unit"]]
		var metric := str(expect[key]["metric"])
		var field_name := "commit_share_mean" if metric == "commit_share" else metric
		var va := float(a[field_name])
		var vb := float(b[field_name])
		ok = va > vb if key == "metric_more" else (va >= 0.0 and (vb < 0.0 or va < vb))
		detail = "%s %.3f vs %.3f" % [metric, va, vb]
	if not ok: _fail("%s 预期不成立：%s（%s）" % [id, expect["why"], detail])
	return {"trial": expect["trial"], "unit": expect["unit"], "why": expect["why"], "detail": detail, "pass": ok}


func _mirror(id: String, field: Dictionary, base: Dictionary, mirrored: Dictionary) -> Dictionary:
	var unit := str(field["subject"])
	var twin := ""
	for trial in field["trials"]:
		if trial["id"] == mirrored["id"]: twin = str(trial["assign"].keys()[0])
	var tvd := _tvd(base["units"][unit]["choice_share"], mirrored["units"][twin]["choice_share"])
	var ok := tvd < TVD_MIRROR
	if not ok: _fail("%s 镜像不对称：%s/%s vs %s/%s TVD=%.3f" % [id, base["id"], unit, mirrored["id"], twin, tvd])
	return {"base": base["id"], "mirror": mirrored["id"], "unit": unit, "twin": twin, "tvd": snappedf(tvd, 0.001), "pass": ok}


func _reproducible(field: Dictionary) -> Dictionary:
	var battlefield := Data.with_trial(field, field["trials"][0])
	var same := true
	for seed in 3:
		var first := JSON.stringify(Sim.run(battlefield, seed, rules))
		var second := JSON.stringify(Sim.run(battlefield, seed, rules))
		if first != second: same = false
	return {"trial": field["trials"][0]["id"], "seeds": 3, "same": same}


func _static_checks() -> Dictionary:
	var hits: Array = []
	for path in SCANNED:
		# 只查代码与数据，跳过注释行（文档里写“没有冷却”不算违规）。
		var lines := FileAccess.get_file_as_string(path).split("\n")
		var text := "\n".join(Array(lines).filter(func(l): return not str(l).strip_edges().begins_with("#"))).to_lower()
		for word in FORBIDDEN:
			if text.contains(word.to_lower()): hits.append("%s 含 %s" % [path, word])
	var profile: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/officers/intent_profile.json"))
	for posture in profile["postures"]:
		for key in profile["postures"][posture]:
			if not key in POSTURE_KEYS: hits.append("姿态 %s 含非偏好字段 %s" % [posture, key])
	for hit in hits: _fail("禁用机制：" + hit)
	return {"scanned": SCANNED, "forbidden": FORBIDDEN, "hits": hits, "pass": hits.is_empty()}


func _mean(shares: Array) -> Dictionary:
	var mean := {}
	for share in shares:
		for p in share: mean[p] = float(mean.get(p, 0.0)) + float(share[p]) / shares.size()
	return mean


func _tvd(a: Dictionary, b: Dictionary) -> float:
	var keys := {}
	for k in a: keys[k] = true
	for k in b: keys[k] = true
	var total := 0.0
	for k in keys: total += absf(float(a.get(k, 0.0)) - float(b.get(k, 0.0)))
	return total / 2.0


func _rounded(values: Dictionary) -> Dictionary:
	var result := {}
	for k in values: result[k] = snappedf(float(values[k]), 0.001) if values[k] is float else values[k]
	return result


func _top(share: Dictionary) -> String:
	var keys := share.keys()
	keys.sort_custom(func(a, b): return float(share[a]) > float(share[b]))
	return "、".join(keys.slice(0, 3).map(func(k): return "%s %.0f%%" % [Intent.posture_name(k), float(share[k]) * 100.0]))
