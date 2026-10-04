extends RefCounted


static func choose(context: Dictionary) -> Dictionary:
	var choices: Array = context.get("candidates", [])
	var officer: Dictionary = context.get("officer", {})
	var personality: Dictionary = officer.get("personality", {})
	var army: Dictionary = context.get("army", {})
	var risk: float = float(personality.get("风险承受", 50)) / 100.0
	var patience: float = float(personality.get("耐心", 50)) / 100.0
	var grain_days: float = float(army.get("grain_days", 0))
	var strength: int = int(army.get("strength", 0))
	var danger: float = 0.0
	for enemy in context.get("enemies", []):
		danger = maxf(danger, float(enemy.get("strength_estimate", 0)) / maxf(strength, 1))
	var best: Dictionary = {}
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
				score += maxf(0, danger - (0.8 + risk * 0.8)) * 65.0
				if bool(context.get("returning", false)):
					score = 120.0
			"pursue": score = 30.0 + risk * 28.0 - (20.0 if grain_days < 8.0 else 0.0)
			"request_support": score = 25.0 + maxf(0, danger - 0.8) * 15.0
		if score > best_score:
			best_score = score
			best = candidate
	if best.is_empty():
		return {}
	return {"candidate_id": best["id"], "reason_summary": str(best.get("description", "按当前任务行动。")), "source": "baseline"}
