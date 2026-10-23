extends SceneTree

const Process = preload("res://scripts/officers/officer_process.gd")
const Combat = preload("res://scripts/war/battle/combat_system.gd")
const Tactical = preload("res://scripts/war/battle/tactical_battlefield.gd")
var failures: Array = []


class BattleAgent extends Node:
	var model := "battle-fixture"
	var last_status := "测试代理"
	var metrics := {"fallbacks": 0}
	var count := 0
	func choose_batch(contexts: Array) -> Dictionary:
		var results := {}
		for context in contexts:
			count += 1
			var choice := "maintain"
			for candidate in context["candidates"]:
				if candidate["action"]["type"] == "deploy_corps":
					choice = candidate["id"]
					break
			results[context["request_id"]] = {"candidate_id": choice, "reason_summary": "测试接战", "source": "battle-fixture"}
		return results


func check(value: bool, message: String) -> void:
	if not value: failures.append(message); push_error(message)


func army(skill_value: int = 50) -> Dictionary:
	var names := ["武艺", "膂力", "布阵", "应变", "治军", "带兵", "威仪", "沉着", "忠义", "箭术", "骑术", "水练"]
	var skills := {}
	for name in names: skills[name] = skill_value
	return {"id": "test", "officer_id": "test", "units": {"infantry": 5000, "archers": 0, "cavalry": 0}, "skills": skills, "trait_ids": [], "morale": 100.0, "organization": 100.0, "fatigue": 0.0, "training": 80, "equipment": 70, "action": {"type": "engage"}}


func _initialize() -> void: call_deferred("_run")


func _run() -> void:
	var rules: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/war/campaign_rules.json"))
	# 将领乘子只剩兵种执行（±6%）：命令已就绪时，90 对 50 的杀伤比不超过 1.06。
	var high_result := Combat.power_breakdown(army(120), rules, "plains")
	check(float(high_result["unit_skill"]) <= 1.06 + 0.0001 and float(high_result["readiness"]) == 1.0, "兵种执行上限约 1.06，未下新命令时就绪为 1")
	var strong := army(90)
	var plain := army(50)
	var defender := army(50)
	var ratio := float(Combat.losses(strong, defender, rules, "plains", 1.0)) / float(maxi(Combat.losses(plain, defender, rules, "plains", 1.0), 1))
	check(ratio >= 1.0 and ratio <= 1.06 + 0.001, "90对50杀伤比在1.00–1.06（实际%.3f）" % ratio)
	# 差异改在时机：同一天刚下新命令时，高带兵布阵者当天出力更多。
	Process.issue_order(strong, {"terrain": "plains"})
	Process.issue_order(plain, {"terrain": "plains"})
	check(Combat.power(strong, rules, "plains") > Combat.power(plain, rules, "plains") * 1.05, "新命令当天高统率者先动")
	# Aura formula and range.
	var capable := army(90)
	check(is_equal_approx(Process.aura_strength(capable, rules), 0.12), "光环强度公式：(90-50)×0.003")
	check(is_equal_approx(Process.aura_strength(army(120), rules), 0.15), "光环强度封顶0.15")
	check(is_equal_approx(Process.aura_strength(army(30), rules), 0.0), "低于50无光环")
	var prestiged := army(70)
	prestiged["skills"]["威仪"] = 80
	check(Process.aura_range(army(70), rules) == 3 and Process.aura_range(prestiged, rules) == 4, "威仪80扩大光环范围")
	# Aura softens morale and organization losses; aura=0 is the old behaviour exactly.
	var soft := army()
	var hard := army()
	Combat.apply_loss(soft, 1000, false, 0.0, 0.12)
	Combat.apply_loss(hard, 1000, false, 0.0)
	var soft_morale := 100.0 - float(soft["morale"])
	var hard_morale := 100.0 - float(hard["morale"])
	check(absf(soft_morale * 1.12 - hard_morale) < 0.01, "光环按1/(1+光环)减轻士气损失")
	var soft_org := 100.0 - float(soft["organization"])
	var hard_org := 100.0 - float(hard["organization"])
	check(absf(soft_org * 1.06 - hard_org) < 0.01, "光环按1/(1+0.5×光环)减轻组织损失")
	var default_loss := army()
	var zero_loss := army()
	Combat.apply_loss(default_loss, 800)
	Combat.apply_loss(zero_loss, 800, false, 1.0, 0.0)
	check(default_loss["morale"] == zero_loss["morale"] and default_loss["organization"] == zero_loss["organization"], "aura缺省与显式0逐位一致")
	# Battlefield checks run on the real Xiaopei fixture.
	var store: Node = root.get_node("GameState")
	store.persist_enabled = false
	var old_day: int = store.day
	var old_tick: int = store.war.state["tick"]
	var original_agent: Node = store.agent
	store.prepare_battle_test()
	var fixture := BattleAgent.new()
	root.add_child(fixture)
	await store.war.step(fixture)
	var war = store.war
	var corps: Dictionary = war.state["corps"].values().filter(func(c): return c["faction"] == war.state["player_faction"])[0]
	var root_army: Dictionary = war.state["armies"][corps["root_id"]]
	# Make the aura strength deterministic for the fixture.
	var saved_root_skills := {"带兵": float(root_army["skills"].get("带兵", 50)), "威仪": float(root_army["skills"].get("威仪", 50)), "治军": float(root_army["skills"].get("治军", 50))}
	for name in saved_root_skills: root_army["skills"][name] = 90
	# Range boundary: a unit at 3 cells gets the aura, one at 4+ does not.
	var members: Array = corps["units"].filter(func(id): return id != corps["root_id"] and war.state["armies"][id]["status"] != "ended")
	var near: Dictionary = war.state["armies"][members[0]]
	var far: Dictionary = war.state["armies"][members[1]]
	var saved_near := int(near["tactical"]["cell"])
	var saved_far := int(far["tactical"]["cell"])
	var near_cell := int(Tactical.neighbors(int(root_army["tactical"]["cell"]))[0])
	near["tactical"]["cell"] = near_cell
	far["tactical"]["cell"] = Tactical.cell_at(Tactical.column_of(near_cell) + 5, Tactical.row_of(near_cell))
	Tactical._compute_auras(war)
	check(float(near["aura"]) > 0.0, "3格内享受统帅光环")
	check(is_equal_approx(float(far["aura"]), 0.0), "范围外没有光环")
	far["tactical"]["cell"] = saved_far
	Tactical._compute_auras(war)
	check(float(far["aura"]) > 0.0, "回到范围内恢复光环")
	# Withdrawing commander turns the aura off for the whole corps.
	var was_returning: bool = root_army["returning"]
	root_army["returning"] = true
	Tactical._compute_auras(war)
	check(is_equal_approx(float(near["aura"]), 0.0) and is_equal_approx(float(root_army["aura"]), 0.0), "主帅撤退后光环为0")
	# Leader loss hits the rest of the corps once, and never re-fires for the same commander.
	var before_morale := float(near["morale"])
	var before_org := float(near["organization"])
	war._check_leader_lost()
	check(is_equal_approx(float(near["morale"]), before_morale - 8.0) and is_equal_approx(float(near["organization"]), before_org - 4.0), "主帅失位全军士气-8、组织-4")
	war._check_leader_lost()
	check(is_equal_approx(float(near["morale"]), before_morale - 8.0), "同一主帅只触发一次失位")
	check(bool(corps.get("leader_lost", false)) and str(corps.get("leader_lost_for", "")) == str(corps["commander_id"]), "主帅失位状态已记录")
	check(not war.state["reports"].is_empty() and str(war.state["reports"][-1]["kind"]) == "主帅失位", "主帅失位写入紧急军报")
	root_army["returning"] = was_returning
	near["tactical"]["cell"] = saved_near
	for name in saved_root_skills: root_army["skills"][name] = saved_root_skills[name]
	store.restore_battle_test()
	check(store.day == old_day and store.war.state["tick"] == old_tick and store.agent == original_agent, "测试退出恢复原战役")
	fixture.queue_free()
	print("OFFICER_COMMAND_VALIDATION: " + ("PASS" if failures.is_empty() else str(failures)))
	quit(0 if failures.is_empty() else 1)
