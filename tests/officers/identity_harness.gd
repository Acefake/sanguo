extends SceneTree
## 人物特色对照验收（M6）。
##
## 8 个 battle_scenarios × 固定种子；同一场景同一种子下只换主将。硬验收：
##   1. 同类型两人（identity_probe.json 的 pairs）至少 2 项指标显著不同（reference_pairs 只打印）；
##   2. 每人至少 1 个场景的表现分高于全体中位；
##   3. 每个已分配的局限特性至少在 1 个场景里复现代价（与去掉该特性的同一人物、同一组种子配对对照）；
##   4. identity_probe.json 的 key_officers 每人至少有一个署名情境（署名来自特性或≥80 的子属性），且重跑结果一致。
##
##   godot --headless --path . --script res://tests/officers/identity_harness.gd [-- --out=/abs/path.json]

const Probe = preload("res://tests/officers/battle_probe.gd")
const Roster = preload("res://scripts/agents/officer_context.gd")
const Traits = preload("res://scripts/officers/trait_registry.gd")
const Explain = preload("res://scripts/officers/officer_explain.gd")
## 指标对应的流程 hook，用来给署名情境找署名来源。
## 投入时机在攻城、解围、伏击场景里分别由攻坚准备、行军、重规划主导。
const METRIC_HOOK := {"commit_hour": "command整理", "ambushed": "ambush识破", "org_min": "special轮换", "pursuit_depth": "pursuit深入", "objective": ""}
const COMMIT_HOOK_BY_KIND := {"siege": "engineering准备", "relief": "march行军", "ambush": "replan重规划"}
const METRIC_TEXT := {"commit_hour": "投入时机", "ambushed": "受伏率", "org_min": "组织最低点", "loss_ratio": "伤亡比", "objective": "目标达成", "pursuit_depth": "追击深度", "disengages": "脱离次数", "command_hours": "命令整理耗时"}

const OFF_BATTLE_STAGES := ["logistics", "council", "influence"]
const T_SIGNIFICANT := 2.5
const T_COST := 2.0
const MIN_COST := 0.03

var settings: Dictionary
var scenarios: Dictionary = {}
var rules: Dictionary
var failures: Array[String] = []
var generated_pairs: Array = []
var subjects_by_name: Dictionary = {}


func _initialize() -> void:
	settings = JSON.parse_string(FileAccess.get_file_as_string("res://tests/officers/identity_probe.json"))
	rules = JSON.parse_string(FileAccess.get_file_as_string("res://data/war/campaign_rules.json"))
	for scenario in JSON.parse_string(FileAccess.get_file_as_string("res://data/war/battle_scenarios.json")): scenarios[scenario["id"]] = scenario
	var subjects := _subjects()
	for officer in subjects: subjects_by_name[officer["name"]] = officer
	var opponent := _flat_officer(str(settings["opponent"]["name"]), float(settings["opponent"]["skill"]), {})
	var staff := _flat_officer(str(settings["staff"]["name"]), float(settings["staff"]["skill"]), settings["staff"]["skills"])

	var results := {}
	for officer in subjects: results[officer["name"]] = _run_all(officer, opponent, staff)
	print("IDENTITY: 主将 %d 人 × 场景 %d × 种子 %d" % [subjects.size(), scenarios.size(), int(settings["seeds"])])
	_print_table(results)

	var report := {"pairs": _check_pairs(results), "median": _check_median(results), "flaws": _check_flaws(subjects, opponent, staff, results), "signatures": _signatures(results, opponent, staff)}
	for key in ["pairs", "median", "flaws", "signatures"]:
		for row in report[key]:
			if not bool(row["pass"]): failures.append("%s: %s" % [key, row["label"]])
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
	for metric in Probe.METRICS + Probe.STAGE_METRICS: samples[metric] = []
	for index in int(settings["seeds"]):
		var m := Probe.run(scenarios[id], settings["scenarios"][id], settings, officer, opponent, staff, hash([id, index]), rules)
		for metric in Probe.METRICS + Probe.STAGE_METRICS: samples[metric].append(float(m[metric]))
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


## 配对 t：同一组种子下“有/无局限”的逐场差值。共同随机数下这是正确的检验；差值全相同记为无穷大。
static func paired(x: Array, y: Array) -> float:
	var diffs: Array = []
	for i in mini(x.size(), y.size()): diffs.append(float(x[i]) - float(y[i]))
	var mu := mean(diffs)
	var se := sqrt(variance(diffs) / maxf(diffs.size(), 1))
	if se < 1e-9: return 0.0 if absf(mu) < 1e-9 else INF * signf(mu)
	return mu / se


func _score(samples: Dictionary) -> float:
	return mean(samples["objective"]) - 0.2 * minf(mean(samples["loss_ratio"]), 5.0)


func _check_pairs(results: Dictionary) -> Array:
	var rows: Array = []
	for pair in settings["pairs"] + generated_pairs + settings.get("reference_pairs", []):
		var differing := {}
		for id in settings["scenarios"]:
			for metric in Probe.METRICS:
				var x: Array = results[pair[0]][id][metric]
				var y: Array = results[pair[1]][id][metric]
				var t := welch(x, y)
				if absf(t) >= T_SIGNIFICANT and absf(mean(x) - mean(y)) >= 0.05 * maxf(absf(mean(x)), absf(mean(y))):
					if not differing.has(metric) or absf(t) > absf(float(differing[metric]["t"])):
						differing[metric] = {"scenario": id, "a": mean(x), "b": mean(y), "t": t}
		var reference: bool = pair in settings.get("reference_pairs", [])
		var row := {"label": "%s/%s" % pair, "differing": differing, "pass": reference or differing.size() >= 2, "reference": reference}
		rows.append(row)
		print("PAIR %s%s/%s 显著不同指标 %d 项：%s" % ["（参考）" if reference else "", pair[0], pair[1], differing.size(), _describe(differing)])
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
			if _off_battle(flaw):
				print("FLAW %s·%s 不在战斗探针范围（只改 %s），跳过" % [officer["name"], Traits.definition(flaw)["name"], ",".join(Traits.definition(flaw)["effects"].map(func(e): return e["hook"]))])
				continue
			var ablated: Dictionary = officer.duplicate(true)
			ablated["trait_ids"] = officer["trait_ids"].filter(func(id): return id != flaw)
			var control := _run_all(ablated, opponent, staff)
			var best := {}
			for id in settings["scenarios"]:
				for metric in Probe.METRICS + Probe.STAGE_METRICS:
					var direction := int(Probe.BETTER[metric])
					if direction == 0: continue
					var t := paired(results[officer["name"]][id][metric], control[id][metric]) * direction
					var with_flaw := mean(results[officer["name"]][id][metric])
					var without := mean(control[id][metric])
					var relative := absf(with_flaw - without) / maxf(absf(without), 0.05)
					# 代价要显著（t）且不小（相对变化 ≥ MIN_COST）；报告相对变化最大的一处。
					if t <= -T_COST and relative >= MIN_COST and (best.is_empty() or relative > float(best["relative"])):
						best = {"scenario": id, "metric": metric, "with": with_flaw, "without": without, "t": t, "relative": relative}
			var row := {"label": "%s·%s" % [officer["name"], Traits.definition(flaw)["name"]], "flaw": flaw, "cost": best, "pass": not best.is_empty()}
			if not best.is_empty():
				var hook := str(Traits.definition(flaw)["effects"][0]["hook"])
				var only_flaw: Dictionary = officer.duplicate()
				only_flaw["trait_ids"] = [flaw]
				row["report"] = Explain.signed(only_flaw, hook, "%s在%s%s变差（有 %.2f / 无 %.2f）" % [Traits.definition(flaw)["summary"].trim_suffix("。"), scenarios[best["scenario"]]["name"], METRIC_TEXT[best["metric"]], best["with"], best["without"]], {"enemy_renown_gap": 30, "subcommanders_assigned": true, "pressure": 1.0, "recipient_count": 10, "plan_invalid_known": true})
			rows.append(row)
			if row.has("report"): print("REPORT " + str(row["report"]))
			print("FLAW %s 代价：%s" % [row["label"], "未复现" if best.is_empty() else "%s@%s 有%.2f/无%.2f (t=%.1f, %+.0f%%)" % [best["metric"], best["scenario"], best["with"], best["without"], best["t"], (best["with"] - best["without"]) / maxf(absf(best["without"]), 0.05) * 100.0]])
	return rows


## 只改后勤、议事、传播流程的局限（如粮账紊乱）在战斗探针里没有对应环节。
func _off_battle(flaw: String) -> bool:
	return Traits.definition(flaw)["effects"].all(func(e): return str(Traits.hook_spec(str(e["hook"])).get("stage", "")) in OFF_BATTLE_STAGES)


## 每人最突出的一处：相对全体均值、以全体标准差计的 z 分数最高（按“更好”方向）；
## 署名情境：z>0 且能署名（特性或≥80 的子属性改了该指标所在流程）的最高一处。
## key_officers 必须有署名情境，并在同一组种子下重跑一次核对均值一致。
func _signatures(results: Dictionary, opponent: Dictionary, staff: Dictionary) -> Array:
	var rows: Array = []
	for name in results:
		var officer: Dictionary = subjects_by_name.get(name, {})
		# 署名只认长处：局限特性改了同一流程时不拿来署“表现突出”的名。
		var strengths: Dictionary = officer.duplicate()
		strengths["trait_ids"] = officer.get("trait_ids", []).filter(func(id): return Traits.tier_of(str(id)) != "flaw")
		var best := {}
		var signed := {}
		for id in settings["scenarios"]:
			for metric in Probe.METRICS:
				var direction := int(Probe.BETTER[metric])
				if direction == 0: continue
				var all: Array = results.keys().map(func(other): return mean(results[other][id][metric]))
				var sd := sqrt(variance(all))
				if sd < 1e-6: continue
				var z := (mean(results[name][id][metric]) - mean(all)) / sd * direction
				var row := {"scenario": id, "metric": metric, "value": mean(results[name][id][metric]), "field": mean(all), "z": z}
				if best.is_empty() or z > float(best["z"]): best = row
				var who := Explain.credit(strengths, _hook(id, metric), _credit_context(id))
				if z > 0.0 and not who.is_empty() and (signed.is_empty() or z > float(signed["z"])):
					signed = row
					signed["credit"] = who
		var key: bool = name in settings["key_officers"]
		var reproducible := false
		if not signed.is_empty() and key:
			var again := _run_scenario(str(signed["scenario"]), officer, opponent, staff if settings["scenarios"][signed["scenario"]].get("staff", false) else {})
			reproducible = is_equal_approx(mean(again[signed["metric"]]), float(signed["value"]))
		var row := {"label": name, "best": best, "signed": signed, "key": key, "reproducible": reproducible, "pass": not key or reproducible}
		rows.append(row)
		print("SIGNATURE %s 最突出：%s@%s %.2f（全体 %.2f，z=%.1f）；署名情境：%s" % [name, METRIC_TEXT.get(best.get("metric", ""), "-"), scenarios.get(best.get("scenario", ""), {}).get("name", "-"), best.get("value", 0.0), best.get("field", 0.0), best.get("z", 0.0),
			"无" if signed.is_empty() else "%s %s@%s %.2f（全体 %.2f，z=%.1f）%s" % [signed["credit"], METRIC_TEXT[signed["metric"]], scenarios[signed["scenario"]]["name"], signed["value"], signed["field"], signed["z"], "，重跑一致" if reproducible else ""]])
	return rows


func _hook(scenario_id: String, metric: String) -> String:
	if metric != "commit_hour": return str(METRIC_HOOK.get(metric, ""))
	var probe: Dictionary = settings["scenarios"][scenario_id]
	for kind in COMMIT_HOOK_BY_KIND:
		if probe.get(kind, false): return str(COMMIT_HOOK_BY_KIND[kind])
	return str(METRIC_HOOK["commit_hour"])


## 署名用的情境：开战前字段；伏击场景按被伏后（原方案失效、高压）判断。
func _credit_context(scenario_id: String) -> Dictionary:
	var probe: Dictionary = settings["scenarios"][scenario_id]
	var ctx := Probe.context(scenarios[scenario_id], probe, settings, {"staff": true} if probe.get("staff", false) else {})
	if probe.get("ambush", false): ctx.merge({"plan_invalid_known": true, "pressure": 0.8}, true)
	return ctx


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
				for metric in Probe.METRICS + Probe.STAGE_METRICS: summary[name][id][metric] = snappedf(mean(results[name][id][metric]), 0.001)
		var file := FileAccess.open(arg.substr(6), FileAccess.WRITE)
		file.store_string(JSON.stringify({"report": report, "means": summary}, "  "))
