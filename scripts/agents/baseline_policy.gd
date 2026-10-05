extends RefCounted


static func choose(context: Dictionary) -> Dictionary:
	var choices: Array = context.get("candidates", [])
	var officer: Dictionary = context.get("officer", {})
	var personality: Dictionary = officer.get("personality", {})
	var army: Dictionary = context.get("army", {})
	var risk: float = float(personality.get("风险承受", 50)) / 100.0
	if "冒进" in officer.get("battle_traits", []): risk = minf(1, risk + 0.12)
	var discipline := float(personality.get("自制", 50)) / 100.0
	var decisiveness := float(personality.get("决断", 50)) / 100.0
	var patience: float = float(personality.get("耐心", 50)) / 100.0
	var grain_days: float = float(army.get("grain_days", 0))
	var strength: int = int(army.get("strength", 0))
	var danger: float = 0.0
	for enemy in context.get("enemies", []):
		danger = maxf(danger, float(enemy.get("strength_estimate", 0)) / maxf(strength, 1))
	if context.has("battlefield"):
		danger = float(context["battlefield"].get("enemy_to_friendly_ratio", danger))
	var best: Dictionary = {}
	var operation: Dictionary = context.get("operation", {})
	var role: String = str(operation.get("role", "main_attack"))
	var best_score: float = -INF
	for candidate in choices:
		var kind: String = str(candidate["action"]["type"])
		var score: float = -10.0
		match kind:
			"continue": score = 35.0
			"march": score = 30.0 + float(candidate.get("progress_gain", 0)) * 12.0
			"scout": score = 18.0 + patience * 8.0 + (22.0 if not bool(context.get("target_known", false)) else 0.0)
			"hold": score = 15.0 + patience * 8.0 + (28.0 if str(context.get("mission_type", "")) == "defend" and bool(context.get("at_objective", false)) else 0.0)
			"resupply": score = 80.0 if grain_days < 12.0 else 8.0
			"engage": score = 42.0 + risk * 14.0 - maxf(0, danger - 1) * 40.0
			"besiege": score = 48.0 + risk * 10.0 - maxf(0, float(candidate.get("defender_ratio", 0)) - 0.6) * (38.0 - risk * 16.0)
			"withdraw":
				score = 95.0 if grain_days < 4.0 or float(army.get("morale", 100)) < 30.0 or float(army.get("organization", 100)) < 25.0 else 5.0
				var threshold := 1.35 + risk * 0.65 if not operation.is_empty() else 0.8 + risk * 0.8
				score += maxf(0, danger - threshold) * 65.0
				if bool(context.get("returning", false)):
					score = 120.0
			"pursue": score = 30.0 + risk * 28.0 - (20.0 if grain_days < 8.0 else 0.0)
			"request_support": score = 25.0 + maxf(0, danger - 0.8) * 15.0
			"support": score = 60.0 if role in ["support", "rear_guard"] else 20.0
			"flank": score = 58.0 if role == "flank" else 18.0
		if kind in ["engage", "flank", "pursue"]: score += (decisiveness - 0.5) * 6
		if kind == "pursue" and grain_days < 8: score -= discipline * 8
		if kind == "scout" and not bool(context.get("target_known", false)) and "多疑" in officer.get("battle_traits", []): score += 6
		if kind == "hold" and role == "reserve" and danger < 1.5: score += 55.0
		if kind == "engage" and not str(operation.get("suggested_target", "")).is_empty() and str(candidate["action"].get("enemy", "")) == str(operation.get("suggested_target", "")): score += 8.0
		if int(operation.get("plan_until", 0)) > int(context.get("observation_revision", 0)) and candidate["action"] == context.get("current_action", {}): score += 10.0
		if score > best_score:
			best_score = score
			best = candidate
	if best.is_empty():
		return {}
	return {"candidate_id": best["id"], "reason_summary": str(best.get("description", "按当前任务行动。")), "source": "baseline"}
