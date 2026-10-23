extends SceneTree

const Process = preload("res://scripts/officers/officer_process.gd")
const Signature = preload("res://scripts/officers/signature_traits.gd")
const Traits = preload("res://scripts/officers/trait_registry.gd")
const Combat = preload("res://scripts/war/battle/combat_system.gd")
const Store = preload("res://scripts/core/game_state.gd")
var failures: Array = []

func check(value: bool, message: String) -> void:
	if not value: failures.append(message); push_error(message)

func army(type: String = "infantry") -> Dictionary:
	return {"id": "test", "officer_id": "test", "units": {"infantry": 10000 if type == "infantry" else 0, "archers": 10000 if type == "archers" else 0, "cavalry": 10000 if type == "cavalry" else 0}, "skills": {}, "trait_ids": [], "morale": 100.0, "organization": 100.0, "fatigue": 0.0, "training": 80, "equipment": 70, "action": {"type": "engage"}}

func _initialize() -> void:
	var rules: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/war/campaign_rules.json"))["units"]
	# 只有兵种对应的子属性进入出力；带兵、布阵、治军改走各自流程。
	for pair in [["膂力", "infantry"], ["箭术", "archers"], ["骑术", "cavalry"]]:
		var low := army(pair[1]); var high := low.duplicate(true)
		high["skills"][pair[0]] = 100
		check(Combat.power(high, rules, "plains") > Combat.power(low, rules, "plains"), pair[0] + "提高对应兵种执行")
	for name in ["带兵", "布阵", "沉着", "武艺"]:
		var low := army(); var high := low.duplicate(true)
		high["skills"][name] = 100
		check(is_equal_approx(Combat.power(high, rules, "plains"), Combat.power(low, rules, "plains")), name + "不再整体放大出力")
	var commander := army(); commander["skills"] = {"带兵": 95, "布阵": 95}
	check(Process.order_delay_hours(commander) < Process.order_delay_hours(army()), "带兵布阵缩短新命令延迟")
	var a := army(); a["skills"] = {"奇袭": 100}
	var b := army(); b["skills"] = {"料敌": 100}
	check(Process.conceal_exposure(a, 0.5) < Process.conceal_exposure(army(), 0.5), "奇袭降低暴露")
	check(Process.ambush_read(b) > Process.ambush_read(army()), "料敌提高识破")
	var trained := army(); trained["skills"] = {"体魄": 100, "治军": 100}
	check(Process.fatigue_cost(trained, 5) < Process.fatigue_cost(army(), 5), "体魄减少疲劳")
	check(Process.recovery(trained)["organization"] > Process.recovery(army())["organization"], "治军提升恢复")
	var ordinary := army()
	Combat.apply_loss(ordinary, 1000); Combat.apply_loss(trained, 1000)
	check(trained["organization"] > ordinary["organization"], "治军轮换减少组织损失")
	var water := army(); water["skills"]["水练"] = 100
	check(Combat.power(water, rules, "river") > Combat.power(army(), rules, "river"), "水练影响水战")
	var over := army(); over["skills"]["箭术"] = 120
	check(absf(Process.value(over, "箭术") - 104.32) < 0.01, "100以上按 GDD E(x) 递减")
	var cavalry := army("cavalry"); var trait_cavalry := cavalry.duplicate(true); trait_cavalry["trait_ids"] = ["trait_046"]
	check(Combat.power(trait_cavalry, rules, "plains") > Combat.power(cavalry, rules, "plains"), "善骑本人骑术+2进入骑兵执行")
	check(is_equal_approx(Combat.power(Combat.aggregate([trait_cavalry, cavalry]), rules, "plains"), Combat.power(trait_cavalry, rules, "plains") + Combat.power(cavalry, rules, "plains")), "合战保留每支部队特性")
	var saint := army(); saint["trait_ids"] = ["unique_wusheng"]
	var famous := army(); famous["skills"]["名望"] = 90
	check(not Signature.first_contact(saint, famous, false), "远射不触发武圣")
	check(Signature.first_contact(saint, famous) and famous["morale"] == 92, "首次正面武圣威压")
	check(not Signature.first_contact(saint, famous) and famous["morale"] == 92, "同目标不重复")
	var chain := army(); chain["victory_chain"] = true; chain["trait_ids"] = ["unique_xiaobawang"]
	var shocked := army(); var unshocked := army()
	check(Process.march_speed(chain) > Process.march_speed(army()), "小霸王首次接敌移动加成")
	check(Signature.opening(chain, shocked), "连胜首次接敌")
	check(not Signature.opening(chain, shocked), "连胜只触发一次")
	Combat.battle_morale(shocked, 200, 100, 2000, 2000, 2000, 2000)
	Combat.battle_morale(unshocked, 200, 100, 2000, 2000, 2000, 2000)
	check(shocked["morale"] < unshocked["morale"] and not shocked.has("incoming_shock"), "首次士气冲击消费")
	var sandbox := Store.new(); sandbox.persist_enabled = false; sandbox._load_demo()
	var yan: Dictionary
	for officer in sandbox.war.roster.officers.values():
		if officer["name"] == "颜良": yan = officer
	check(Traits.has(yan, "trait_049") and Traits.has(yan, "flaw_rash"), "真实人物卡导入技术特性与人格型局限")
	var migrated := army(); migrated["officer_id"] = yan["id"]; migrated["faction"] = "yuan_shao"; migrated["home"] = "ye"
	var saved: Dictionary = sandbox.war.export_state(); saved["armies"] = {"test": migrated}
	sandbox.war.setup(sandbox, saved)
	check(Traits.has(sandbox.war.state["armies"]["test"], "flaw_rash"), "旧存档自动补齐特性")
	sandbox.free()
	print("OFFICER_BATTLE_VALIDATION: " + ("PASS" if failures.is_empty() else str(failures)))
	quit(0 if failures.is_empty() else 1)
