extends SceneTree
## 生成将职业模板：同一剧本两次生成完全相同；8 个模板都出现；每人 1 优势 + 1 局限且都已注册；
## 模板主项不低于历史人物中位；位置按人物卡格式写出，岗位分配可直接读。
##
##   godot --headless --path . --script res://tests/officers/career_template_validation.gd

const Roster = preload("res://scripts/agents/officer_context.gd")
const Careers = preload("res://scripts/officers/career_templates.gd")
const Traits = preload("res://scripts/officers/trait_registry.gd")

var failures: Array[String] = []


func check(value: bool, message: String) -> void:
	if not value:
		failures.append(message)
		push_error(message)


func build() -> Roster:
	var cards: Array = JSON.parse_string(FileAccess.get_file_as_string("res://data/officers.json"))
	var rules: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/war/campaign_rules.json"))
	var roster := Roster.new()
	roster.setup(cards, rules.get("faction_mapping", {}))
	roster.ensure_factions(JSON.parse_string(FileAccess.get_file_as_string("res://data/scenario_world_demo.json")))
	return roster


func _initialize() -> void:
	var first := build()
	var second := build()
	var generated: Array = first.officers.values().filter(func(o): return bool(o.get("generated", false)))
	check(not generated.is_empty(), "应生成地方将领")
	check(JSON.stringify(first.officers) == JSON.stringify(second.officers), "两次生成完全相同（可复现）")

	var keys: Array = []
	for row in Roster.SKILLS: keys.append_array(row)
	var medians := Careers.medians(first.officers, keys)
	var counts := {}
	var by_faction := {}
	for officer in generated:
		var template: Dictionary = Careers.templates().filter(func(t): return t["id"] == officer["career"])[0]
		counts[template["name"]] = int(counts.get(template["name"], 0)) + 1
		var faction := str(officer["faction"])
		if not by_faction.has(faction): by_faction[faction] = []
		by_faction[faction].append(template["id"])
		var ids: Array = officer["trait_ids"]
		check(ids.size() == 2 and Traits.tier_of(str(ids[1])) == "flaw" and Traits.tier_of(str(ids[0])) in ["common", "elite"], "%s 应为 1 优势 + 1 局限" % officer["name"])
		check(template["primary"].any(func(key): return float(officer["skills"][key]) >= float(medians[key])), "%s 主项峰值低于历史中位" % officer["name"])
		check(str(officer["positions"]).contains("核心位置") and str(officer["name"]).contains(template["name"]) or str(officer["name"]).ends_with("代行主政"), "%s 位置或名称未写明模板" % officer["name"])
	for faction in by_faction:
		var list: Array = by_faction[faction].slice(0, mini(8, by_faction[faction].size()))
		var unique := {}
		for id in list: unique[id] = true
		check(unique.size() == list.size(), "%s 前 8 名生成将模板应各不相同" % faction)
	check(counts.size() == Careers.templates().size(), "8 个模板都应出现，实际 %d" % counts.size())
	var spread := []
	for name in counts: spread.append("%s%d" % [name, counts[name]])
	print("CAREERS: 生成将 %d 人，模板分布 %s" % [generated.size(), " ".join(spread)])
	print("CAREER_TEMPLATE_VALIDATION: " + ("PASS" if failures.is_empty() else "FAIL " + str(failures)))
	quit(0 if failures.is_empty() else 1)
