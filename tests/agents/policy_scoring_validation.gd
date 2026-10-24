extends SceneTree

const Policy = preload("res://scripts/agents/baseline_policy.gd")
var failures: Array[String] = []

func _initialize() -> void: call_deferred("_run")

func check(value: bool, message: String) -> void:
	if not value:
		failures.append(message)
		push_error(message)

func _contexts(army: Dictionary, enemies: Array, candidates: Array, officer: Dictionary, extra: Dictionary = {}) -> Dictionary:
	var context := {
		"officer": {"personality": officer.get("personality", {}), "battle_traits": officer.get("battle_traits", [])},
		"army": army, "enemies": enemies, "allies": extra.get("allies", []),
		"operation": extra.get("operation", {}), "mission_type": extra.get("mission_type", "capture"),
		"at_objective": extra.get("at_objective", false), "target_known": extra.get("target_known", true),
		"returning": extra.get("returning", false), "observation_revision": extra.get("observation_revision", 10),
		"current_action": extra.get("current_action", {"type": "hold"}), "candidates": candidates
	}
	if extra.has("battlefield"): context["battlefield"] = extra["battlefield"]
	if extra.has("experience"): context["experience"] = extra["experience"]
	return context

func _army(strength: int, grain: float = 20.0, morale: float = 90.0, organization: float = 90.0) -> Dictionary:
	return {"strength": strength, "units": {"infantry": strength, "archers": 0, "cavalry": 0}, "grain_days": grain, "morale": morale, "organization": organization}

func _personality(overrides: Dictionary = {}) -> Dictionary:
	var p := {}
	for axis in Policy.Roster.AXES: p[axis] = 50
	for key in overrides: p[key] = overrides[key]
	return p

func _run() -> void:
	var weak: Array = [{"id": "e1", "strength_estimate": 1500, "unit_mix_estimate": {"infantry": 1500}, "routing": false}]
	var strong: Array = [{"id": "e1", "strength_estimate": 12000, "unit_mix_estimate": {"infantry": 12000}, "routing": false}]
	var engage := {"id": "engage", "action": {"type": "engage", "enemy": "e1"}, "description": "交战"}
	var withdraw := {"id": "withdraw", "action": {"type": "withdraw"}, "description": "撤退"}
	var hold := {"id": "hold", "action": {"type": "hold"}, "description": "驻守"}
	var march := {"id": "march", "action": {"type": "march", "target": "x", "edge": "e"}, "description": "行军"}
	# 1) 弱敌：应主动接战。
	var weak_context := _contexts(_army(5000), weak, [hold, march, engage, withdraw], {"personality": _personality()}, {"operation": {"role": "main_attack"}})
	check(str(Policy.choose(weak_context)["candidate_id"]) == "engage", "弱敌场景没有选择接战")
	# 2) 强敌：不应正面接战。
	var strong_context := _contexts(_army(3000), strong, [hold, march, engage, withdraw], {"personality": _personality()}, {"battlefield": {"enemy_to_friendly_ratio": 4.0}})
	check(str(Policy.choose(strong_context)["candidate_id"]) != "engage", "强敌场景仍选择正面接战")
	# 3) 断粮：应补给。
	var resupply := {"id": "resupply", "action": {"type": "resupply"}, "description": "补给"}
	var starve_context := _contexts(_army(5000, 2.0), weak, [hold, march, engage, resupply], {"personality": _personality()})
	check(str(Policy.choose(starve_context)["candidate_id"]) == "resupply", "断粮场景没有优先补给")
	# 4) 友军溃退、担任掩护：应支援而非接战。
	var cover := {"id": "support", "action": {"type": "support", "ally": "ally1"}, "description": "掩护友军"}
	var cover_context := _contexts(_army(5000), weak, [hold, engage, cover], {"personality": _personality()}, {"operation": {"role": "rear_guard", "commander": "ally1"}, "allies": [{"id": "ally1", "can_support": false, "returning": true, "strength": 800}]})
	check(str(Policy.choose(cover_context)["candidate_id"]) == "support", "友军溃退时掩护职责没有选择支援")
	# 5) 个性差异：同一局面仅改风险承受，选择应反向。
	var risky := _contexts(_army(3000), [{"id": "e1", "strength_estimate": 4500, "unit_mix_estimate": {"infantry": 4500}, "routing": false}], [engage, withdraw], {"personality": _personality({"风险承受": 90})}, {"battlefield": {"enemy_to_friendly_ratio": 1.5}})
	var timid := _contexts(_army(3000), [{"id": "e1", "strength_estimate": 4500, "unit_mix_estimate": {"infantry": 4500}, "routing": false}], [engage, withdraw], {"personality": _personality({"风险承受": 10})}, {"battlefield": {"enemy_to_friendly_ratio": 1.5}})
	check(str(Policy.choose(risky)["candidate_id"]) == "engage" and str(Policy.choose(timid)["candidate_id"]) == "withdraw", "风险承受没有改变行动选择")
	# 6) 目标选择：弱、孤立的败退敌军应优先，而不是列表第一个。
	var e1 := {"id": "e1", "strength_estimate": 6000, "unit_mix_estimate": {"infantry": 6000}, "routing": false, "tactical_cell": 2200}
	var e2 := {"id": "e2", "strength_estimate": 1200, "unit_mix_estimate": {"infantry": 1200}, "routing": true, "tactical_cell": 5000}
	var target_context := _contexts(_army(6000), [e1, e2], [
		{"id": "engage:e1", "action": {"type": "engage", "enemy": "e1"}, "description": "交战e1"},
		{"id": "engage:e2", "action": {"type": "engage", "enemy": "e2"}, "description": "交战e2"},
		{"id": "pursue:e2", "action": {"type": "pursue", "enemy": "e2"}, "description": "追击e2"}
	], {"personality": _personality({"记仇": 90})}, {"operation": {"role": "main_attack"}})
	var chosen: Dictionary = Policy.choose(target_context)
	check(str(chosen["candidate_id"]) == "engage:e2", "目标选择仍取列表第一个而非残破孤立敌军")
	# 7) 记仇：曾击败本队的敌军获得更高目标价值。
	var notes := {"experience": {"enemy_notes": {"e1": {"beat_us": true, "last_seen": 9}}}}
	var grudge := _contexts(_army(6000), [e1, e2], [
		{"id": "engage:e1", "action": {"type": "engage", "enemy": "e1"}, "description": "交战e1"},
		{"id": "engage:e2", "action": {"type": "engage", "enemy": "e2"}, "description": "交战e2"}
	], {"personality": _personality({"记仇": 90})}, notes)
	check(Policy.target_value(grudge, grudge["candidates"][0]) > Policy.target_value(grudge, grudge["candidates"][1]), "记仇没有提高宿敌目标价值")
	# 8) 决策可复现：评分明细存在且可重算。
	var ranked: Array = Policy.score(weak_context)
	check(not ranked.is_empty() and ranked[0].has("breakdown") and not ranked[0]["breakdown"].is_empty(), "评分明细缺失")
	check(Policy.version() >= 1, "权重文件版本缺失")
	print("POLICY_SCORING_OK: scenario table, personality contrast, target selection by weakness/isolation, grudge, replayable breakdown" if failures.is_empty() else "POLICY_SCORING_FAILED")
	quit(0 if failures.is_empty() else 1)
