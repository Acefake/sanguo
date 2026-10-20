extends SceneTree
## 人格与失败模式进入决策：人格平滑移动投入、脱离与迎战门槛；局限特性叠在其上；
## 效用表里七个人格因素 90 对 30 相差约一个模板分差（≥15 分）。
## baseline_policy 本身依赖本仓库缺失的 officer_brain / tactical_evaluator，这里不加载它，只校验它读取的数据与查询。
##
##   godot --headless --path . --script res://tests/officers/officer_conduct_validation.gd

const Conduct = preload("res://scripts/officers/officer_conduct.gd")
const Roster = preload("res://scripts/agents/officer_context.gd")

var failures: Array[String] = []


func check(value: bool, message: String) -> void:
	if not value:
		failures.append(message)
		push_error(message)


func officer(personality: Dictionary, traits: Array = []) -> Dictionary:
	return {"personality": personality, "trait_ids": traits, "skills": {}}


func _initialize() -> void:
	var bold := officer({"风险承受": 95, "耐心": 30})
	var careful := officer({"风险承受": 20, "耐心": 90})
	check(Conduct.engage_ratio(bold) < 0.95 and Conduct.engage_ratio(careful) > 1.12, "迎战门槛：勇猛约 0.92、谨慎约 1.15（%.2f / %.2f）" % [Conduct.engage_ratio(bold), Conduct.engage_ratio(careful)])
	check(Conduct.disengage_line(bold) < Conduct.disengage_line(careful), "风险承受高的人脱离线更低")
	check(Conduct.commit_readiness(bold) < Conduct.commit_readiness(careful), "耐心低的人等协同更短")
	# 局限叠在人格之上，且方向与人格一致时不被人格抵消。
	check(Conduct.disengage_line(officer({"风险承受": 50}, ["flaw_brawler"])) == 20.0, "恋战在中性人格下脱离线 20")
	check(Conduct.commit_readiness(officer({"耐心": 90}, ["flaw_rash"])) < Conduct.commit_readiness(officer({"耐心": 90})) - 0.4, "急躁在高耐心者身上照样把就位度压低 0.5")
	check(is_equal_approx(Conduct.dissent_shift(officer({}, ["flaw_stubborn"])), 0.05), "刚愎违令 +5pp")

	# 真实人物：颜良与文丑卡面几乎相同，靠局限区分；田丰与魏延人格相反。
	var cards: Array = JSON.parse_string(FileAccess.get_file_as_string("res://data/officers.json"))
	var roster := Roster.new()
	roster.setup(cards, {})
	var by_name := {}
	for o in roster.officers.values(): by_name[o["name"]] = o
	print("CONDUCT: 迎战门槛 魏延 %.2f 田丰 %.2f；脱离线 魏延 %.1f 田丰 %.1f 黄忠 %.1f；就位度 文丑 %.2f 颜良 %.2f(对低名望 %.2f) 袁绍 %.2f" % [
		Conduct.engage_ratio(by_name["魏延"]), Conduct.engage_ratio(by_name["田丰"]),
		Conduct.disengage_line(by_name["魏延"]), Conduct.disengage_line(by_name["田丰"]), Conduct.disengage_line(by_name["黄忠"]),
		Conduct.commit_readiness(by_name["文丑"]), Conduct.commit_readiness(by_name["颜良"]), Conduct.commit_readiness(by_name["颜良"], {"enemy_renown_gap": 20}), Conduct.commit_readiness(by_name["袁绍"])])
	check(Conduct.engage_ratio(by_name["魏延"]) < Conduct.engage_ratio(by_name["田丰"]), "魏延比田丰更敢迎战")

	# 效用表：七个人格因素在主轴 90 与 30 之间的权重差。
	var weights: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/agents/policy_weights.json"))
	var axes := {"patience": "耐心", "ambition": "野心", "greed": "贪欲", "suspicion": "猜疑", "discipline": "自制", "pride": "自尊", "order": "秩序偏好"}
	for factor in axes:
		var base := float(weights["factors"][factor]["weight"])
		var coef := float(weights["personality_modifiers"][axes[factor]][factor])
		check(not is_zero_approx(base), "%s 基础权重应非 0" % factor)
		check(absf(coef * 60.0) >= 15.0 - 0.001, "%s：%s 90 对 30 相差 %.1f 分，应≥15" % [factor, axes[factor], absf(coef * 60.0)])
	check(float(weights["support"]["relation"]["宿怨"]) < float(weights["support"]["relation"]["同袍"]), "宿怨降低支援承诺")
	print("OFFICER_CONDUCT_VALIDATION: " + ("PASS" if failures.is_empty() else "FAIL " + str(failures)))
	quit(0 if failures.is_empty() else 1)
