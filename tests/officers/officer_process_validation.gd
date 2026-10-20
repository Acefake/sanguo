extends SceneTree
## 属性→流程单测：E(x) 递减；每个流程只被它拥有的那项子属性改变（控制变量）；
## 命令容量排队；新命令延迟进入当天出力并在日终结转；局限特性改变决策阈值且受合计上限。
##
##   godot --headless --path . --script res://tests/officers/officer_process_validation.gd

const Process = preload("res://scripts/officers/officer_process.gd")
const Conduct = preload("res://scripts/officers/officer_conduct.gd")
const Combat = preload("res://scripts/war/combat_system.gd")
const Roster = preload("res://scripts/agents/officer_context.gd")

var failures: Array[String] = []


func check(value: bool, message: String) -> void:
	if not value:
		failures.append(message)
		push_error(message)


func army(skills: Dictionary = {}, traits: Array = [], units: Dictionary = {"infantry": 2000, "archers": 0, "cavalry": 0}) -> Dictionary:
	return {"id": "t", "officer_id": "t", "units": units.duplicate(), "skills": skills.duplicate(), "trait_ids": traits, "morale": 100.0, "organization": 100.0, "fatigue": 0.0, "training": 70, "equipment": 60, "action": {"type": "engage"}}


## 流程名 -> [拥有它的子属性, 取值函数]
func processes() -> Dictionary:
	return {
		"命令整理": ["带兵", func(a): return Process.command_hours(a)],
		"展开整队": ["布阵", func(a): return Process.formation_hours(a, {"terrain": "hills"})],
		"行军": ["布阵", func(a): return Process.march_time_factor(a)],
		"轮换": ["治军", func(a): return Process.rotation_hours(a)],
		"重规划": ["应变", func(a): return Process.replan_hours(a)],
		"压力失误": ["沉着", func(a): return Process.pressure_error(a, 0.8)],
		"敌情误差": ["料敌", func(a): return Process.intel_sigma(a)],
		"接触暴露": ["奇袭", func(a): return Process.conceal_exposure(a, 0.5)],
		"计划遗漏": ["智计", func(a): return Process.plan_omission(a, 0.5)],
		"疲劳": ["体魄", func(a): return Process.fatigue_cost(a, 5.0)],
		"齐射准备": ["箭术", func(a): return Process.volley_hours(a)],
		"步兵执行": ["膂力", func(a): return Process.unit_execution(a, "infantry")],
		"骑兵执行": ["骑术", func(a): return Process.unit_execution(a, "cavalry")],
		"光环": ["威仪", func(a): return Process.aura_strength(a)],
	}


func _initialize() -> void:
	# GDD 5.2 的对照点。
	for pair in [[100.0, 100.0], [105.0, 101.97], [110.0, 103.16], [120.0, 104.32], [60.0, 60.0]]:
		check(absf(Process.effective(pair[0]) - pair[1]) < 0.01, "E(%s)=%s" % pair)

	# 控制变量：抬高拥有者，流程变化；抬高其余 24 项，流程不变。
	var keys: Array = []
	for group in Roster.SKILLS: keys.append_array(group)
	var table := processes()
	for name in table:
		var owner: String = table[name][0]
		var read: Callable = table[name][1]
		var base := float(read.call(army()))
		var raised := float(read.call(army({owner: 95})))
		check(not is_equal_approx(base, raised), "%s 应随 %s 变化" % [name, owner])
		for key in keys:
			if key == owner: continue
			if is_equal_approx(float(read.call(army({key: 95}))), base): continue
			check(false, "%s 不应被 %s 改变" % [name, key])

	# GDD 4.3.1：整理时间 = t×(1.2−0.4u)；容量 2+floor(6u)，超出排队。
	check(absf(Process.command_hours(army({"带兵": 50})) - 4.0 * (1.2 - 0.4 * 50.0 / 105.0)) < 0.001, "命令整理按 GDD 公式")
	var big := {"infantry": 20000, "archers": 0, "cavalry": 0}
	var weak := Process.command_hours(army({"带兵": 30}, [], big))
	var strong := Process.command_hours(army({"带兵": 95}, [], big))
	print("PROCESS: 两万人新命令整理 带兵30=%.2fh 带兵95=%.2fh" % [weak, strong])
	check(weak > strong * 2.0, "超编时低带兵排队明显更久")
	check(absf(Process.command_hours(army({}, ["trait_001"])) / Process.command_hours(army()) - 0.95) < 0.0001, "明令使整理耗时 −5%")
	check(Process.pressure_error(army(), 0.0) == 0.0, "无压力不制造失误")

	# 新命令延迟进入当天出力，日终结转后恢复。
	var rules: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/war/campaign_rules.json"))
	var unit := army({"带兵": 40, "布阵": 40})
	var before := Combat.power(unit, rules, "plains")
	Process.issue_order(unit, {"terrain": "forest"})
	var during := Combat.power(unit, rules, "plains")
	Process.end_day(unit)
	check(during < before and is_equal_approx(Combat.power(unit, rules, "plains"), before), "新命令当天出力下降，次日恢复")
	print("PROCESS: 新命令当天就绪 带兵/布阵40=%.3f 95=%.3f" % [during / before, _readiness_for({"带兵": 95, "布阵": 95})])

	# 局限特性进入决策阈值。
	check(is_equal_approx(Conduct.disengage_line(army({}, ["flaw_brawler"])), 20.0), "恋战脱离线 35→20")
	check(is_equal_approx(Conduct.disengage_line(army({}, ["flaw_timid"])), 55.0), "怯战脱离线 35→55")
	check(Conduct.pursuit_limit(army({}, ["flaw_glory"])) == 4, "贪功追击深入 2→4")
	check(Conduct.pursuit_limit(army({}, ["flaw_glory", "trait_026"])) == 4, "贪功+追击疏算 合计夹到 +2")
	check(is_equal_approx(Conduct.commit_readiness(army({}, ["flaw_rash"])), 0.3), "急躁协同就位度 0.8→0.3")
	var lord := army({}, ["flaw_stubborn"])
	var critic := army({}, ["flaw_caustic"])
	check(Conduct.advice_adoption(lord, critic, {"lord_pride": 90}) < Conduct.advice_adoption(army(), army(), {"lord_pride": 90}) - 0.2, "刚愎主将遇刻薄参军，采纳率下降 25pp")

	print("OFFICER_PROCESS_VALIDATION: " + ("PASS" if failures.is_empty() else "FAIL " + str(failures)))
	quit(0 if failures.is_empty() else 1)


func _readiness_for(skills: Dictionary) -> float:
	var unit := army(skills)
	Process.issue_order(unit, {"terrain": "forest"})
	return Process.readiness(unit)
