extends SceneTree

const Edges = preload("res://scripts/war/campaign/officer_edges.gd")
const Tactical = preload("res://scripts/war/battle/tactical_battlefield.gd")

const Combat = preload("res://scripts/war/battle/combat_system.gd")
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


func edge(id: String) -> Dictionary:
	return {"id": id, "uses": 0, "cooldown_until": 0, "active_until": 0}


func _initialize() -> void: call_deferred("_run")


func _run() -> void:
	# Scoring and threshold: at most one edge, none below 65.
	var plain := {"skills": {}, "personality": {}}
	check(Edges.generate_id(plain) == "", "全50能力不生成专长")
	var cunning := {"skills": {"智计": 90}, "personality": {"耐心": 90}}
	check(Edges.generate_id(cunning) == "ambush", "智计与耐心高者生成设伏")
	var borderline := {"skills": {"智计": 64}, "personality": {"耐心": 64}}
	check(Edges.generate_id(borderline) == "", "低于阈值65不生成专长")
	var saved := {"edge": edge("ambush")}
	saved["edge"]["uses"] = 2
	saved["edge"]["cooldown_until"] = 7
	var kept := Edges.ensure(saved, cunning)
	check(str(kept["id"]) == "ambush" and int(kept["uses"]) == 2 and int(kept["cooldown_until"]) == 7, "读档保持专长次数与冷却")
	var reset := Edges.ensure(saved, cunning, true)
	check(int(reset["uses"]) == 0 and int(reset["cooldown_until"]) == 0, "战场重新生成清零专长状态")
	var missing := Edges.ensure({}, cunning)
	check(str(missing["id"]) == "ambush" and int(missing["uses"]) == 0, "旧档缺省重新生成专长")
	# Battlefield triggers run on the real Xiaopei fixture.
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
	var tick: int = int(war.state["tick"])
	var corps: Dictionary = war.state["corps"].values().filter(func(c): return c["faction"] == war.state["player_faction"])[0]
	var root_army: Dictionary = war.state["armies"][corps["root_id"]]
	var unit: Dictionary = war.state["armies"][corps["units"].filter(func(id): return id != corps["root_id"] and war.state["armies"][id]["status"] != "ended")[0]]
	var ally: Dictionary = war.state["armies"][corps["units"].filter(func(id): return id != corps["root_id"] and id != unit["id"] and war.state["armies"][id]["status"] != "ended")[0]]
	var enemy: Dictionary = war.active_armies().filter(func(a): return a["faction"] != war.state["player_faction"] and a.has("tactical"))[0]
	var saved_ally := {"cell": int(ally["tactical"]["cell"]), "returning": bool(ally["returning"]), "organization": float(ally["organization"])}
	var saved_intel: Dictionary = enemy["intel"]["enemies"].duplicate(true)
	var saved_traits: Array = unit["trait_ids"].duplicate()
	# steady: first time morale drops below 40.
	unit["edge"] = edge("steady")
	unit["morale"] = 35.0
	Edges.day_start(war)
	check(is_equal_approx(float(unit["morale"]), 45.0) and int(unit["edge"]["uses"]) == 1, "临阵稳军首次低士气回复10")
	unit["morale"] = 30.0
	Edges.day_start(war)
	check(is_equal_approx(float(unit["morale"]), 30.0), "临阵稳军每战只触发一次")
	unit["morale"] = 100.0
	# surge: yesterday's kill ratio favours us, then cooldown.
	unit["edge"] = edge("surge")
	unit["edge_advantage_tick"] = tick - 1
	Edges.day_start(war)
	check(absf(float(unit.get("edge_attack", 1.0)) - 1.1) < 0.0001 and int(unit["edge"]["cooldown_until"]) == tick + 3, "乘势突击当日攻击×1.1并进入冷却")
	unit.erase("edge_attack")
	unit.erase("edge_advantage_tick")
	war.state["tick"] = tick + 1
	Edges.day_start(war)
	check(not unit.has("edge_attack"), "冷却期间不再触发")
	war.state["tick"] = tick
	# cover: an adjacent ally is withdrawing.
	unit["edge"] = edge("cover")
	ally["tactical"]["cell"] = int(Tactical.neighbors(int(unit["tactical"]["cell"]))[0])
	ally["returning"] = true
	Edges.day_start(war)
	check(absf(float(unit.get("edge_defense", 1.0)) - 0.8) < 0.0001, "断后掩护撤退友军，受伤×0.8")
	# 端到端方向断言：旧实现把 edge_defense 乘进防御除式，0.8 落在分母上，
	# 文档写的"伤亡减轻"实际变成受伤×1.25。只断言标志值看不出方向。
	var uncovered := unit.duplicate(true)
	uncovered.erase("edge_defense")
	var covered_hit: Dictionary = Combat.losses_detail(enemy, unit, war.rules, "plains", 1.0)
	var plain_hit: Dictionary = Combat.losses_detail(enemy, uncovered, war.rules, "plains", 1.0)
	check(int(covered_hit["loss"]) < int(plain_hit["loss"]), "断后掩护没有真正降低当日损失")
	check(absf(float(covered_hit["factors"].get("专长守御", 1.0)) - 0.8) < 0.0001, "专长守御因子未进入军报依据")
	# rally: a nearby ally is disorganized.
	unit["edge"] = edge("rally")
	unit.erase("edge_defense")
	ally["returning"] = false
	ally["organization"] = 30.0
	Edges.day_start(war)
	check(is_equal_approx(float(ally["organization"]), 35.0) and int(unit["edge"]["cooldown_until"]) == tick + 3, "激将提升范围内友军组织5")
	ally["tactical"]["cell"] = saved_ally["cell"]
	ally["organization"] = saved_ally["organization"]
	ally["returning"] = saved_ally["returning"]
	unit.erase("edge_defense")
	# ambush: only against a target that has not observed us.
	enemy["intel"]["enemies"] = {}
	unit["edge"] = edge("ambush")
	check(absf(Edges.attack_mult(war, unit, enemy, false) - 1.2) < 0.0001, "设伏首轮攻击×1.2")
	check(absf(Edges.attack_mult(war, unit, enemy, false) - 1.0) < 0.0001, "设伏每战只触发一次")
	unit["edge"] = edge("ambush")
	enemy["intel"]["enemies"] = {str(unit["id"]): {"id": unit["id"]}}
	check(absf(Edges.attack_mult(war, unit, enemy, false) - 1.0) < 0.0001, "敌军已观测到本队时不能设伏")
	enemy["intel"]["enemies"] = saved_intel
	# awe: first frontal contact shakes the enemy; 武圣 keeps its own stronger effect.
	unit["edge"] = edge("awe")
	unit["trait_ids"] = []
	var enemy_morale := float(enemy["morale"])
	Edges.attack_mult(war, unit, enemy, true)
	check(is_equal_approx(float(enemy["morale"]), enemy_morale - 6.0) and int(unit["edge"]["uses"]) == 1, "立威首次正面接敌减敌士气6")
	var after_awe := float(enemy["morale"])
	Edges.attack_mult(war, unit, enemy, true)
	check(is_equal_approx(float(enemy["morale"]), after_awe), "立威每战只触发一次")
	unit["edge"] = edge("awe")
	unit["trait_ids"] = ["unique_wusheng"]
	enemy["morale"] = enemy_morale
	Edges.attack_mult(war, unit, enemy, true)
	check(is_equal_approx(float(enemy["morale"]), enemy_morale) and int(unit["edge"]["uses"]) == 0, "武圣威压独立结算，专长不重复触发")
	unit["trait_ids"] = saved_traits
	# Save round-trip keeps a real officer's edge id and uses.
	root_army["edge"] = Edges.ensure(root_army, war.roster.officers[str(root_army["officer_id"])], true)
	root_army["edge"]["uses"] = 1
	var exported: Dictionary = war.export_state()
	var sandbox := preload("res://scripts/core/game_state.gd").new()
	sandbox.persist_enabled = false
	sandbox._load_demo()
	sandbox.war.setup(sandbox, exported)
	var restored: Dictionary = sandbox.war.state["armies"][root_army["id"]]
	check(str(restored.get("edge", {}).get("id", "")) == str(root_army["edge"]["id"]) and int(restored["edge"]["uses"]) == 1, "存档恢复专长与次数")
	sandbox.free()
	store.restore_battle_test()
	check(store.day == old_day and store.war.state["tick"] == old_tick and store.agent == original_agent, "测试退出恢复原战役")
	fixture.queue_free()
	print("OFFICER_EDGES_VALIDATION: " + ("PASS" if failures.is_empty() else str(failures)))
	quit(0 if failures.is_empty() else 1)
