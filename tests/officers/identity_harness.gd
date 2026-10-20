extends SceneTree
## 人物特色对照验收（M6）。
##
## 8 个 battle_scenarios × 固定种子；同一场景同一种子下只换主将。硬验收：
##   1. 同类型两人（identity_probe.json 的 pairs）至少 2 项指标显著不同；
##   2. 每人至少 1 个场景的表现分高于全体中位；
##   3. 每个已分配的局限特性至少在 1 个场景里复现代价（与去掉该特性的同一人物对照）。
##
##   godot --headless --path . --script res://tests/officers/identity_harness.gd [-- --out=/abs/path.json]

const Probe = preload("res://tests/officers/battle_probe.gd")
const Roster = preload("res://scripts/agents/officer_context.gd")
const Traits = preload("res://scripts/officers/trait_registry.gd")

const T_SIGNIFICANT := 2.5
const T_COST := 2.0
const MIN_COST := 0.03

var settings: Dictionary
var scenarios: Dictionary = {}
var rules: Dictionary
var failures: Array[String] = []
var generated_pairs: Array = []


func _initialize() -> void:
	settings = JSON.parse_string(FileAccess.get_file_as_string("res://tests/officers/identity_probe.json"))
	rules = JSON.parse_string(FileAccess.get_file_as_string("res://data/war/campaign_rules.json"))
	for scenario in JSON.parse_string(FileAccess.get_file_as_string("res://data/war/battle_scenarios.json")): scenarios[scenario["id"]] = scenario
	var subjects := _subjects()
	var opponent := _flat_officer(str(settings["opponent"]["name"]), float(settings["opponent"]["skill"]), {})
	var staff := _flat_officer(str(settings["staff"]["name"]), float(settings["staff"]["skill"]), settings["staff"]["skills"])

	var results := {}
	for officer in subjects: results[officer["name"]] = _run_all(officer, opponent, staff)
	print("IDENTITY: 主将 %d 人 × 场景 %d × 种子 %d" % [subjects.size(), scenarios.size(), int(settings["seeds"])])
	_print_table(results)

	var report := {"pairs": _check_pairs(results), "median": _check_median(results), "flaws": _check_flaws(subjects, opponent, staff, results), "signatures": _signatures(results)}
	report["advice"] = _check_advice(subjects, opponent)
	for key in ["pairs", "median", "flaws"]:
		for row in report[key]:
			if not bool(row["pass"]): failures.append("%s: %s" % [key, row["label"]])
	if not report["advice"].is_empty() and not bool(report["advice"][0]["pass"]): failures.append("advice: " + str(report["advice"][0]["label"]))
	_write(report, results)
	print("IDENTITY_HARNESS: " + ("PASS" if failures.is_empty() else "FAIL %d 项 %s" % [failures.size(), str(failures)]))
	quit(0 if failures.is_empty() else 1)


func _subjects() -> Array:
	var cards: Array = JSON.parse_string(FileAccess.get_file_as_string("res://data/officers.json"))
	var roster := Roster.new()
	roster.setup(cards, rules.get("faction_mapping", {}))
	var world: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/scenario_world_demo.json"))
	roster.ensure_factions(world)
	var list: Array = []
	for card in cards: list.append(roster.officers[str(card["id"])])
	# 生成将：每个模板取第一人（曹方优先），generated_pairs 里的模板再取第二人做同模板对照。
	var generated: Array = roster.officers.values().filter(func(o): return bool(o.get("generated", false)) and o.has("career"))
	generated.sort_custom(func(x, y): return [not str(x["id"]).contains("cao_cao"), str(x["id"])] < [not str(y["id"]).contains("cao_cao"), str(y["id"])])
	var taken := {}
	for officer in generated:
		var career := str(officer["career_name"])
		var limit := 2 if career in settings["generated_pairs"] else 1
		if int(taken.get(career, 0)) >= limit: continue
		taken[career] = int(taken.get(career, 0)) + 1
		list.append(officer)
		if int(taken[career]) == 2: generated_pairs.append([_first_of(list, career), officer["name"]])
	return list


func _first_of(list: Array, career: String) -> String:
	for officer in list:
		if str(officer.get("career_name", "")) == career: return str(officer["name"])
	return ""


func _flat_officer(name: String, skill: float, overrides: Dictionary) -> Dictionary:
	var skills := {}
	for group in Roster.SKILLS:
		for key in group: skills[key] = skill
	skills.merge(overrides, true)
	var personality := {}
	for axis in Roster.AXES: personality[axis] = float(settings["opponent"]["personality"])
	return {"id": name, "name": name, "skills": skills, "personality": personality, "trait_ids": []}


func _run_all(officer: Dictionary, opponent: Dictionary, staff: Dictionary) -> Dictionary:
	var by_scenario := {}
	for id in settings["scenarios"]: by_scenario[id] = _run_scenario(id, officer, opponent, staff if settings["scenarios"][id].get("staff", false) else {})
	return by_scenario


func _run_scenario(id: String, officer: Dictionary, opponent: Dictionary, staff: Dictionary) -> Dictionary:
	var samples := {}
	for metric in Probe.METRICS: samples[metric] = []
	for index in int(settings["seeds"]):
		var m := Probe.run(scenarios[id], settings["scenarios"][id], settings, officer, opponent, staff, hash([id, index]), rules)
		for metric in Probe.METRICS: samples[metric].append(float(m[metric]))
	return samples


static func mean(values: Array) -> float:
	var total := 0.0
	for v in values: total += float(v)
	return total / maxf(values.size(), 1)


static func variance(values: Array) -> float:
	var mu := mean(values)
	var total := 0.0
	for v in values: total += (float(v) - mu) * (float(v) - mu)
	return total / maxf(values.size() - 1, 1)


## Welch t；两组都没有方差时，均值不同记为无穷大。
static func welch(x: Array, y: Array) -> float:
	var diff := mean(x) - mean(y)
	var se := sqrt(variance(x) / maxf(x.size(), 1) + variance(y) / maxf(y.size(), 1))
	if se < 1e-9: return 0.0 if absf(diff) < 1e-9 else INF * signf(diff)
	return diff / se


func _score(samples: Dictionary) -> float:
	return mean(samples["objective"]) - 0.2 * minf(mean(samples["loss_ratio"]), 5.0)


func _check_pairs(results: Dictionary) -> Array:
	var rows: Array = []
	for pair in settings["pairs"] + generated_pairs:
		var differing := {}
		for id in settings["scenarios"]:
			for metric in Probe.METRICS:
				var x: Array = results[pair[0]][id][metric]
				var y: Array = results[pair[1]][id][metric]
				var t := welch(x, y)
				if absf(t) >= T_SIGNIFICANT and absf(mean(x) - mean(y)) >= 0.05 * maxf(absf(mean(x)), absf(mean(y))):
					if not differing.has(metric) or absf(t) > absf(float(differing[metric]["t"])):
						differing[metric] = {"scenario": id, "a": mean(x), "b": mean(y), "t": t}
		var row := {"label": "%s/%s" % pair, "differing": differing, "pass": differing.size() >= 2}
		rows.append(row)
		print("PAIR %s/%s 显著不同指标 %d 项：%s" % [pair[0], pair[1], differing.size(), _describe(differing)])
	return rows


func _describe(differing: Dictionary) -> String:
	var parts: Array = []
	for metric in differing:
		var d: Dictionary = differing[metric]
		parts.append("%s@%s %.2f/%.2f(t=%.1f)" % [metric, d["scenario"], d["a"], d["b"], d["t"]])
	return "；".join(parts)


func _check_median(results: Dictionary) -> Array:
	var medians := {}
	for id in settings["scenarios"]:
		var scores: Array = results.keys().map(func(name): return _score(results[name][id]))
		scores.sort()
		medians[id] = scores[scores.size() / 2]
	var rows: Array = []
	for name in results:
		var above: Array = []
		for id in settings["scenarios"]:
			if _score(results[name][id]) > float(medians[id]) + 1e-6: above.append(id)
		rows.append({"label": name, "above": above, "pass": not above.is_empty()})
		print("MEDIAN %s 高于中位的场景 %d 个：%s" % [name, above.size(), ",".join(above)])
	return rows


func _check_flaws(subjects: Array, opponent: Dictionary, staff: Dictionary, results: Dictionary) -> Array:
	var rows: Array = []
	for officer in subjects:
		for flaw in Traits.flaws(officer):
			if flaw == "flaw_caustic": continue
			var ablated: Dictionary = officer.duplicate(true)
			ablated["trait_ids"] = officer["trait_ids"].filter(func(id): return id != flaw)
			var control := _run_all(ablated, opponent, staff)
			var best := {}
			for id in settings["scenarios"]:
				for metric in Probe.METRICS:
					var direction := int(Probe.BETTER[metric])
					if direction == 0: continue
					var t := welch(results[officer["name"]][id][metric], control[id][metric]) * direction
					var with_flaw := mean(results[officer["name"]][id][metric])
					var without := mean(control[id][metric])
					var relative := absf(with_flaw - without) / maxf(absf(without), 0.05)
					# 代价要显著（t）且不小（相对变化 ≥ MIN_COST）；报告相对变化最大的一处。
					if t <= -T_COST and relative >= MIN_COST and (best.is_empty() or relative > float(best["relative"])):
						best = {"scenario": id, "metric": metric, "with": with_flaw, "without": without, "t": t, "relative": relative}
			var row := {"label": "%s·%s" % [officer["name"], Traits.definition(flaw)["name"]], "flaw": flaw, "cost": best, "pass": not best.is_empty()}
			rows.append(row)
			print("FLAW %s 代价：%s" % [row["label"], "未复现" if best.is_empty() else "%s@%s 有%.2f/无%.2f (t=%.1f, %+.0f%%)" % [best["metric"], best["scenario"], best["with"], best["without"], best["t"], (best["with"] - best["without"]) / maxf(absf(best["without"]), 0.05) * 100.0]])
	return rows


## 言辞刻薄只在当参军时起作用：同一主将配同一参军，对照去掉该特性的参军。
func _check_advice(subjects: Array, opponent: Dictionary) -> Array:
	var rows: Array = []
	for case in settings["advice_cases"]:
		var commander: Dictionary = subjects.filter(func(o): return o["name"] == case["commander"])[0]
		var adviser: Dictionary = subjects.filter(func(o): return o["name"] == case["adviser"])[0]
		var plain: Dictionary = adviser.duplicate(true)
		plain["trait_ids"] = adviser["trait_ids"].filter(func(id): return id != case["flaw"])
		var with_flaw := _run_scenario(case["scenario"], commander, opponent, adviser)
		var without := _run_scenario(case["scenario"], commander, opponent, plain)
		var t := welch(with_flaw["ambushed"], without["ambushed"])
		var row := {"label": "%s进言%s·%s" % [case["adviser"], case["commander"], Traits.definition(case["flaw"])["name"]], "with": mean(with_flaw["ambushed"]), "without": mean(without["ambushed"]), "t": t, "pass": t >= T_COST}
		rows.append(row)
		print("ADVICE %s 受伏率 有%.2f/无%.2f (t=%.1f)" % [row["label"], row["with"], row["without"], t])
	return rows


## 每人最突出的一处：相对全体均值、以全体标准差计的 z 分数最高（按“更好”方向）。
func _signatures(results: Dictionary) -> Array:
	var rows: Array = []
	for name in results:
		var best := {}
		for id in settings["scenarios"]:
			for metric in Probe.METRICS:
				var direction := int(Probe.BETTER[metric])
				if direction == 0: continue
				var all: Array = results.keys().map(func(other): return mean(results[other][id][metric]))
				var sd := sqrt(variance(all))
				if sd < 1e-6: continue
				var z := (mean(results[name][id][metric]) - mean(all)) / sd * direction
				if best.is_empty() or z > float(best["z"]): best = {"scenario": id, "metric": metric, "value": mean(results[name][id][metric]), "field": mean(all), "z": z}
		rows.append({"name": name, "best": best})
		print("SIGNATURE %s 最突出：%s@%s %.2f（全体 %.2f，z=%.1f）" % [name, best.get("metric", "-"), best.get("scenario", "-"), best.get("value", 0.0), best.get("field", 0.0), best.get("z", 0.0)])
	return rows


func _print_table(results: Dictionary) -> void:
	for id in settings["scenarios"]:
		print("SCENARIO %s" % id)
		for name in results:
			var s: Dictionary = results[name][id]
			print("  %-8s 投入%5.1fh 追深%.2f 脱离%.2f 受伏%.2f 组织低%5.1f 伤亡比%5.2f 目标%.2f" % [name, mean(s["commit_hour"]), mean(s["pursuit_depth"]), mean(s["disengages"]), mean(s["ambushed"]), mean(s["org_min"]), mean(s["loss_ratio"]), mean(s["objective"])])


func _write(report: Dictionary, results: Dictionary) -> void:
	for arg in OS.get_cmdline_user_args():
		if not arg.begins_with("--out="): continue
		var summary := {}
		for name in results:
			summary[name] = {}
			for id in results[name]:
				summary[name][id] = {}
				for metric in Probe.METRICS: summary[name][id][metric] = snappedf(mean(results[name][id][metric]), 0.001)
		var file := FileAccess.open(arg.substr(6), FileAccess.WRITE)
		file.store_string(JSON.stringify({"report": report, "means": summary}, "  "))
