extends SceneTree
## 特性注册表校验：真实数据零错误；上限在查询时统一夹住；坏数据必须被拒绝；
## 人物卡特性与注册表一致；Notion task.kind 条件；令辞含混、过度负责的条件分支；武圣、小霸王机制不变。
##
##   godot --headless --path . --script res://tests/officers/trait_registry_validation.gd

const Traits = preload("res://scripts/officers/trait_registry.gd")
const Process = preload("res://scripts/officers/officer_process.gd")
const Signature = preload("res://scripts/officers/signature_traits.gd")
const Roster = preload("res://scripts/agents/officer_context.gd")
const Card = preload("res://scripts/officers/officer_card.gd")

var failures: Array[String] = []


func check(value: bool, message: String) -> void:
	if not value:
		failures.append(message)
		push_error(message)


func army(units: Dictionary, traits: Array) -> Dictionary:
	return {"id": "t", "officer_id": "t", "units": units, "skills": {}, "trait_ids": traits, "morale": 100.0, "organization": 100.0, "fatigue": 0.0, "training": 70, "equipment": 60, "action": {"type": "engage"}}


func _initialize() -> void:
	var errors := Traits.validate()
	for error in errors: print("  校验错误：", error)
	check(errors.is_empty(), "真实特性数据应零校验错误，实际 %d 条" % errors.size())

	var cards: Array = JSON.parse_string(FileAccess.get_file_as_string("res://data/officers.json"))
	var roster := Roster.new()
	roster.setup(cards, {})
	var flaw_total := 0
	var sides := {}
	for card in cards:
		var ids: Array = roster.officers[str(card["id"])]["trait_ids"]
		flaw_total += Traits.flaws({"trait_ids": ids}).size()
		sides[card["faction"]] = int(sides.get(card["faction"], 0)) + 1
		check(ids == Traits.ids_for_officer(str(card["id"])), "%s 运行时特性与注册表配置一致" % card["name"])
	check(sides == {"袁绍集团": 10, "曹操集团": 10}, "官渡人物卡每方 10 人：%s" % str(sides))
	print("REGISTRY: traits=%d officers=%d flaws_assigned=%d" % [Traits.all_ids().size(), cards.size(), flaw_total])

	# Notion 特性库的 task.kind：调用方没给时按 hook 所在流程补上；本人动作类要调用方明说。
	var host := army({"infantry": 14000, "archers": 0, "cavalry": 6000}, ["trait_015", "trait_049"])
	check(is_equal_approx(Traits.modifier(host, "command整理", {"subcommanders_assigned": true, "communication": true}), -0.08), "合阵：十个受令单位、分统、通信齐备时整理 -8%")
	check(Traits.modifier(host, "command整理", {"subcommanders_assigned": true}) == 0.0, "合阵：通信不明时不触发")
	check(Traits.attribute_points(host, "武艺", {"task": "personal_melee", "mounted": true}) == 2, "骑战：马上近战武艺 +2")
	check(Traits.attribute_points(host, "武艺") == 0, "骑战：不是本人近战时不触发")
	# 令辞含混、过度负责是条件分支：多路命令、原方案失效或高压时才付代价，幅度仍在普通档上限内。
	var garbled := army({"infantry": 20000}, ["trait_011"])
	var small := army({"infantry": 4000}, ["trait_011"])
	check(is_equal_approx(Traits.modifier(garbled, "command整理"), 0.05) and Traits.modifier(small, "command整理") == 0.0, "令辞含混：四路以上命令才返工 +5%")
	check(is_equal_approx(Traits.modifier(garbled, "pressure失误", {"pressure": 0.6}), 0.02) and Traits.modifier(garbled, "pressure失误", {"pressure": 0.3}) == 0.0, "令辞含混：多路命令且压力≥0.5 才加失误 +2pp")
	var micro := army({"infantry": 20000}, ["flaw_micromanage"])
	check(is_equal_approx(Traits.modifier(micro, "command整理", {"subcommanders_assigned": true}), 0.05) and Traits.modifier(micro, "command整理") == 0.0, "过度负责：设了分统仍逐部节度才 +5%")
	check(is_equal_approx(Traits.modifier(micro, "replan重规划", {"subcommanders_assigned": true, "plan_invalid_known": true}), 0.05) and Traits.modifier(micro, "replan重规划", {"subcommanders_assigned": true}) == 0.0, "过度负责：原方案失效后重排 +5%")

	# 合计上限：急行 -5% + 山行 -5% + 善骑 -3% = -13%，夹到 -10%。
	var rider := army({"infantry": 0, "archers": 0, "cavalry": 6000}, ["trait_016", "trait_033", "trait_046"])
	check(is_equal_approx(Traits.modifier(rider, "march行军", {"terrain": "mountains"}), -0.10), "同一 hook 合计夹到 -10%")
	check(is_equal_approx(Traits.modifier(rider, "march行军", {"terrain": "plains"}), -0.08), "山行只在山地丘陵生效")
	check(Traits.sources(rider, "march行军", {"terrain": "mountains"}).size() == 3, "来源列表保留三条未夹值")
	# 条件字段缺失视为不知道：骄矜不知道对手名望时不触发。
	var proud := army({"infantry": 5000, "archers": 0, "cavalry": 0}, ["flaw_arrogant"])
	check(Traits.modifier(proud, "commit投入") == 0.0, "缺失条件字段时不触发")
	check(is_equal_approx(Traits.modifier(proud, "commit投入", {"enemy_renown_gap": 20}), -0.3), "面对低名望对手骄矜触发")
	# 善骑：骑乘时骑术+2，步战不触发。
	check(Traits.attribute_points(rider, "骑术") == 2, "骑兵部队默认骑乘，骑术+2")
	check(Traits.attribute_points(army({"infantry": 5000}, ["trait_046"]), "骑术") == 0, "步兵部队不骑乘，善骑属性不触发")

	# 坏数据必须被拒绝。
	var hooks: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(Traits.HOOKS_PATH))
	var bad_traits := {"traits": [
		{"id": "trait_900", "name": "未注册", "tier": "common", "effects": [{"hook": "神力加伤", "value": -0.05}]},
		{"id": "trait_901", "name": "超档", "tier": "common", "effects": [{"hook": "command整理", "value": -0.08}]},
		{"id": "flaw_backward", "name": "反向", "tier": "flaw", "effects": [{"hook": "command整理", "value": -0.05}]},
		{"id": "trait_902", "name": "错字段", "tier": "common", "effects": [{"hook": "command整理", "value": -0.05, "when": [["enemy.true_strength", ">", 1]]}]},
		{"id": "trait_903", "name": "运筹帷幂", "tier": "common", "effects": [{"hook": "plan遗漏", "value": -0.02}]},
		{"id": "trait_904", "name": "叠点甲", "tier": "elite", "effects": [{"hook": "attribute.武艺", "value": 3}]},
		{"id": "trait_905", "name": "叠点乙", "tier": "elite", "effects": [{"hook": "attribute.武艺", "value": 3}]},
		{"id": "trait_906", "name": "叠点丙", "tier": "elite", "effects": [{"hook": "attribute.武艺", "value": 3}]}]}
	var bad_assign := {"officers": {"x": {"name": "三卓越", "trait_ids": ["trait_904", "trait_905", "trait_906"]}}}
	var bad := Traits.load_data(hooks, bad_traits, bad_assign)
	var joined := "\n".join(bad)
	for needle in ["未注册的 hook", "trait_901", "flaw_backward", "enemy.true_strength", "运筹帷幂", "超出 GDD 8.1", "没有局限"]:
		check(joined.contains(needle), "校验应拒绝：" + needle)
	check(Traits.attribute_points(army({"infantry": 1}, ["trait_904", "trait_905", "trait_906"]), "武艺") == 6, "属性点合计夹到 +6")

	# 恢复真实数据，验证专属机制行为不变（Notion 专属库为空，当前无人持有，用合成部队测）。
	Traits.load_data(hooks, JSON.parse_string(FileAccess.get_file_as_string(Traits.TRAITS_PATH)), Card.assignments(cards))
	var saint := army({"infantry": 5000}, ["unique_wusheng"])
	var famous := army({"infantry": 5000}, [])
	famous["skills"]["名望"] = 90
	famous["officer_id"] = "famous"
	check(not Signature.first_contact(saint, famous, false), "远射不触发武圣")
	check(Signature.first_contact(saint, famous) and is_equal_approx(famous["morale"], 92.0), "首次正面武圣威压 -8")
	check(not Signature.first_contact(saint, famous) and is_equal_approx(famous["morale"], 92.0), "同一目标只触发一次")
	var plain := army({"infantry": 5000}, [])
	check(not Signature.first_contact(plain, army({"infantry": 5000}, []), true), "没有武圣不触发")
	var chain := army({"infantry": 5000}, ["unique_xiaobawang"])
	chain["victory_chain"] = true
	check(is_equal_approx(Process.march_speed(chain) / Process.march_speed(army({"infantry": 5000}, ["unique_xiaobawang"])), 1.08), "小霸王首次接敌移动 +8%")
	var shocked := army({"infantry": 5000}, [])
	check(Signature.opening(chain, shocked) and is_equal_approx(shocked["incoming_shock"], 1.08), "小霸王首次士气冲击 +8%")
	check(not Signature.opening(chain, army({"infantry": 5000}, [])), "连胜只触发一次")

	print("TRAIT_REGISTRY_VALIDATION: " + ("PASS" if failures.is_empty() else "FAIL " + str(failures)))
	quit(0 if failures.is_empty() else 1)
