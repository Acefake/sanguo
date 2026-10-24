extends SceneTree

const Policy = preload("res://scripts/agents/baseline_policy.gd")
var failures: Array[String] = []

func _initialize() -> void: call_deferred("_run")

func check(value: bool, message: String) -> void:
	if not value:
		failures.append(message)
		push_error(message)

func _personality(overrides: Dictionary = {}) -> Dictionary:
	var p := {}
	for axis in Policy.Roster.AXES: p[axis] = 50
	for key in overrides: p[key] = overrides[key]
	return p

func _unit(task: String, fatigue: float = 20.0, organization: float = 90.0, returning: bool = false) -> Dictionary:
	return {"task": {"type": task}, "fatigue": fatigue, "organization": organization, "returning": returning}

func _context(corps: Dictionary, candidates: Array, officer: Dictionary, extra: Dictionary = {}) -> Dictionary:
	var context := {
		"officer": {"personality": _personality(officer), "battle_traits": []},
		"corps": corps, "candidates": candidates, "army": extra.get("army", {"grain_days": 20.0}),
		"battlefield": extra.get("battlefield", {"enemy_to_friendly_ratio": 1.0, "friendly_ready_strength": 0.0}),
		"siege": extra.get("siege", {}), "unit_mix": extra.get("unit_mix", {}),
		"enemy_unit_mix_estimate": extra.get("enemy", {}), "terrain": extra.get("terrain", "plains"),
		"background": extra.get("background", false), "deployment_age": extra.get("deployment_age", 0),
		"withdraw_hysteresis": extra.get("withdraw_hysteresis", false), "observation_revision": 10
	}
	return context

func _deploy_candidates() -> Array:
	return [
		{"id": "maintain", "action": {"type": "maintain"}, "description": "保持部署"},
		{"id": "deploy:balanced", "action": {"type": "deploy_corps", "posture": "balanced"}, "description": "均势展开"},
		{"id": "deploy:assault", "action": {"type": "deploy_corps", "posture": "assault"}, "description": "加强前锋"},
		{"id": "deploy:flanking", "action": {"type": "deploy_corps", "posture": "flanking"}, "description": "加强侧翼"}
	]

func _run() -> void:
	var corps := {"strength": 10000, "units": [_unit("main_attack"), _unit("reserve")], "deployment_pending": false}
	# 1) 敌军以步兵为主、主帅冒进：展开时选强攻。
	var assault := _context({"strength": 10000, "units": [_unit("main_attack")], "deployment_pending": true}, _deploy_candidates(), {"野心": 90, "风险承受": 90, "决断": 90}, {"enemy": {"infantry": 9000, "archers": 500, "cavalry": 500}, "unit_mix": {"infantry": 6000, "archers": 2000, "cavalry": 2000}})
	check(str(Policy.choose_commander_id(assault)) == "deploy:assault", "步兵为主的敌军没有选择强攻展开")
	# 2) 敌军弓兵多、主帅多谋：选侧翼展开。
	var flanking := _context({"strength": 10000, "units": [_unit("main_attack")], "deployment_pending": true}, _deploy_candidates(), {"野心": 20, "猜疑": 90, "决断": 90, "风险承受": 20}, {"enemy": {"infantry": 4000, "archers": 5000, "cavalry": 1000}, "unit_mix": {"infantry": 5000, "archers": 3000, "cavalry": 2000}})
	check(str(Policy.choose_commander_id(flanking)) == "deploy:flanking", "弓兵为主的敌军没有选择侧翼展开")
	# 3) 后台首日不展开。
	var waiting := _context({"strength": 10000, "units": [_unit("main_attack")], "deployment_pending": true}, _deploy_candidates(), {}, {"background": true, "deployment_age": 1})
	check(str(Policy.choose_commander_id(waiting)) == "maintain", "后台首日不应提前展开")
	# 4) 守军断粮：选围困。
	var siege_candidates := [{"id": "maintain", "action": {"type": "maintain"}, "description": "保持"}, {"id": "siege:blockade", "action": {"type": "set_siege_mode", "mode": "blockade"}, "description": "围困"}]
	var siege := _context(corps, siege_candidates, {}, {"siege": {"grain_days": 6}})
	check(str(Policy.choose_commander_id(siege)) == "siege:blockade", "守军断粮时没有选择围困")
	# 5) 兵力优势：围困不会是默认选择。
	var fresh := _context(corps, siege_candidates, {}, {"siege": {"grain_days": 30}})
	check(str(Policy.choose_commander_id(fresh)) == "maintain", "守军粮足时不应围困")
	# 6) 兵力劣势撤退。
	var withdraw_candidates := [{"id": "maintain", "action": {"type": "maintain"}, "description": "保持"}, {"id": "withdraw_corps", "action": {"type": "withdraw_corps"}, "description": "全军撤退"}]
	var losing := _context(corps, withdraw_candidates, {}, {"battlefield": {"enemy_to_friendly_ratio": 3.0, "friendly_ready_strength": 6000}})
	check(str(Policy.choose_commander_id(losing)) == "withdraw_corps", "明显劣势没有选择撤退")
	var even := _context(corps, withdraw_candidates, {}, {"battlefield": {"enemy_to_friendly_ratio": 1.2, "friendly_ready_strength": 9500}})
	check(str(Policy.choose_commander_id(even)) == "maintain", "均势不应撤退")
	# 7) 撤退迟滞：进入门槛高于退出门槛，避免摇摆。
	var sticky := _context(corps, withdraw_candidates, {}, {"battlefield": {"enemy_to_friendly_ratio": 2.0, "friendly_ready_strength": 9000}, "withdraw_hysteresis": true})
	check(str(Policy.choose_commander_id(sticky)) == "withdraw_corps", "已开始撤退后不应因小改善立即回头")
	# 8) 前锋疲惫且无预备队：拆出预备队。
	var tired_corps := {"strength": 10000, "units": [_unit("main_attack", 85.0, 30.0)], "deployment_pending": false}
	var detach := _context(tired_corps, [
		{"id": "maintain", "action": {"type": "maintain"}, "description": "保持"},
		{"id": "detach:reserve", "action": {"type": "detach", "source": "u1", "officer": "o", "strength": 2000, "task": "reserve", "cell": -1}, "description": "拆出预备队"}
	], {})
	check(str(Policy.choose_commander_id(detach)) == "detach:reserve", "前锋疲惫且无预备队时没有拆出预备队")
	# 9) 前进锋疲惫但有预备队：轮换。
	var rotate_corps := {"strength": 10000, "units": [_unit("main_attack", 85.0, 100.0), _unit("reserve", 10.0, 100.0)], "deployment_pending": false}
	var rotate := _context(rotate_corps, [
		{"id": "maintain", "action": {"type": "maintain"}, "description": "保持"},
		{"id": "rotate:u0", "action": {"type": "rotate_front", "front": "u0", "reserve": "u1"}, "description": "轮换前锋"}
	], {})
	check(str(Policy.choose_commander_id(rotate)) == "rotate:u0", "有预备队时没有轮换疲惫前锋")
	# 10) 本地模式下的奇袭：主帅好冒险且条件满足。
	var raid := _context(corps, [
		{"id": "maintain", "action": {"type": "maintain"}, "description": "保持"},
		{"id": "raid", "action": {"type": "detach", "source": "u1", "officer": "o", "strength": 1000, "task": "raid_rear", "cell": 500}, "description": "绕后奇袭"},
		{"id": "supply", "action": {"type": "assign_task", "unit": "u1", "task": "cut_supply", "cell": 600, "enemy_corps": "e"}, "description": "截断粮道"}
	], {"野心": 90, "贪欲": 80})
	var picked := str(Policy.choose_commander_id(raid))
	check(picked in ["raid", "supply"], "条件满足时本地主帅没有选择绕后或截粮")
	# 11) 正面战线空虚：补线。
	var empty_front := {"strength": 10000, "units": [_unit("reserve")], "deployment_pending": false}
	var fill := _context(empty_front, [
		{"id": "maintain", "action": {"type": "maintain"}, "description": "保持"},
		{"id": "line", "action": {"type": "assign_task", "unit": "u1", "task": "main_attack"}, "description": "补线"}
	], {})
	check(str(Policy.choose_commander_id(fill)) == "line", "正面战线空虚没有补线")
	print("COMMANDER_POLICY_OK: posture by enemy mix, siege blockade, withdrawal with hysteresis, reserve fill/rotate, local raid" if failures.is_empty() else "COMMANDER_POLICY_FAILED")
	quit(0 if failures.is_empty() else 1)
