extends SceneTree

const Battle = preload("res://scripts/war/officer_battle.gd")
const Combat = preload("res://scripts/war/combat_system.gd")
const Store = preload("res://scripts/game_state.gd")
var failures: Array = []

func check(value: bool, message: String) -> void:
	if not value: failures.append(message); push_error(message)

func army(type: String = "infantry") -> Dictionary:
	return {"id": "test", "officer_id": "test", "units": {"infantry": 10000 if type == "infantry" else 0, "archers": 10000 if type == "archers" else 0, "cavalry": 10000 if type == "cavalry" else 0}, "skills": {}, "battle_traits": [], "morale": 100.0, "organization": 100.0, "fatigue": 0.0, "training": 80, "equipment": 70, "action": {"type": "engage"}}

func _initialize() -> void:
	var rules: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/war/campaign_rules.json"))["units"]
	for pair in [["带兵", "infantry"], ["布阵", "infantry"], ["治军", "infantry"], ["膂力", "infantry"], ["武艺", "infantry"], ["箭术", "archers"], ["沉着", "archers"], ["骑术", "cavalry"]]:
		var low := army(pair[1]); var high := low.duplicate(true)
		high["skills"][pair[0]] = 100
		check(Combat.power(high, rules, "plains") > Combat.power(low, rules, "plains"), pair[0] + "提高对应战斗力")
	var a := army(); var b := army()
	a["action"]["type"] = "flank"
	a["skills"] = {"奇袭": 100, "智计": 100}
	b["skills"] = {"料敌": 100, "应变": 100}
	check(Battle.tactic(a, army()) > Battle.tactic(a, b), "料敌应变反制奇袭")
	var trained := army(); trained["skills"] = {"体魄": 100, "治军": 100, "沉着": 100, "威仪": 100, "忠义": 100, "辩才": 100, "应变": 100}
	check(Battle.fatigue_cost(trained, 5) < Battle.fatigue_cost(army(), 5), "体魄减少疲劳")
	check(Battle.recovery(trained)["organization"] > Battle.recovery(army())["organization"], "治军提升恢复")
	var ordinary := army()
	Combat.apply_loss(ordinary, 1000); Combat.apply_loss(trained, 1000)
	check(trained["morale"] > ordinary["morale"] and trained["organization"] > ordinary["organization"], "士气组织抗损")
	var water := army(); water["skills"]["水练"] = 100
	check(Combat.power(water, rules, "river") > Combat.power(army(), rules, "river"), "水练影响水战")
	var over := army(); over["skills"]["箭术"] = 120
	check(is_equal_approx(Battle.skill(over, "箭术"), 106), "100以上递减收益")
	var cavalry := army("cavalry"); var trait_cavalry := cavalry.duplicate(true); trait_cavalry["battle_traits"] = ["骑战"]
	check(is_equal_approx(Combat.power(trait_cavalry, rules, "plains") / Combat.power(cavalry, rules, "plains"), 1.03), "骑战仅额外3%不重复属性加成")
	check(is_equal_approx(Combat.power(Combat.aggregate([trait_cavalry, cavalry]), rules, "plains"), Combat.power(trait_cavalry, rules, "plains") + Combat.power(cavalry, rules, "plains")), "合战保留每支部队特性")
	var saint := army(); saint["battle_traits"] = ["武圣"]
	var famous := army(); famous["skills"]["名望"] = 90
	check(not Battle.first_contact(saint, famous, false), "远射不触发武圣")
	check(Battle.first_contact(saint, famous) and famous["morale"] == 92, "首次正面武圣威压")
	check(not Battle.first_contact(saint, famous) and famous["morale"] == 92, "同目标不重复")
	var chain := army(); chain["victory_chain"] = true
	var shocked := army(); var unshocked := army()
	check(Battle.march_speed(chain) > Battle.march_speed(army()), "小霸王首次接敌移动加成")
	check(Battle.opening(chain, shocked), "连胜首次接敌")
	check(not Battle.opening(chain, shocked), "连胜只触发一次")
	Combat.battle_morale(shocked, 200, 100, 2000, 2000, 2000, 2000)
	Combat.battle_morale(unshocked, 200, 100, 2000, 2000, 2000, 2000)
	check(shocked["morale"] < unshocked["morale"] and not shocked.has("incoming_shock"), "首次士气冲击消费")
	var sandbox := Store.new(); sandbox.persist_enabled = false; sandbox._load_demo()
	var guan: Dictionary
	for officer in sandbox.war.roster.officers.values():
		if officer["name"] == "关羽": guan = officer
	check(Battle.has_trait(guan, "武圣"), "真实人物卡导入特性")
	var migrated := army(); migrated["officer_id"] = guan["id"]; migrated["faction"] = "liu_bei"; migrated["home"] = "luoyang"
	var saved: Dictionary = sandbox.war.export_state(); saved["armies"] = {"test": migrated}
	sandbox.war.setup(sandbox, saved)
	check(Battle.has_trait(sandbox.war.state["armies"]["test"], "武圣"), "旧存档自动补齐特性")
	sandbox.free()
	print("OFFICER_BATTLE_VALIDATION: " + ("PASS" if failures.is_empty() else str(failures)))
	quit(0 if failures.is_empty() else 1)
