extends RefCounted

const Tactical = preload("res://scripts/war/battle/tactical_battlefield.gd")
const Evaluator = preload("res://scripts/agents/tactical_evaluator.gd")

# Uses only frozen proposals and communicated views; no authoritative enemies.
static func resolve(contexts: Array, proposals: Dictionary) -> Dictionary:
	var sorted: Array = contexts.duplicate()
	sorted.sort_custom(func(a,b):
		var left := priority(a)
		var right := priority(b)
		return left > right if left != right else str(a["actor_key"]) < str(b["actor_key"]))
	var reserved := {}
	var occupied := {}
	var targets := {}
	var chosen := {}
	for ctx in contexts: occupied[str(ctx["battle_id"])+":"+str(ctx["self"]["cell"])] = ctx["actor_key"]
	for ctx in sorted:
		var ranked := Evaluator.rank(ctx)
		var proposed: Dictionary = proposals[ctx["actor_key"]]
		var ordered: Array = []
		for entry in ranked:
			if entry["candidate"]["id"] == proposed.get("candidate_id",""): ordered.append(entry["candidate"])
		for entry in ranked:
			if not ordered.has(entry["candidate"]): ordered.append(entry["candidate"])
		var denied := ""
		for candidate in ordered:
			var action: Dictionary = candidate["action"]
			var conflict := false
			for cell in action["path"].slice(1):
				var key := str(ctx["battle_id"])+":"+str(cell)
				if reserved.has(key) or (occupied.has(key) and occupied[key] != ctx["actor_key"]): conflict = true
			if conflict: denied = "通路已占用，等待或改用接应位置"; continue
			var target: Dictionary = candidate.get("target",{})
			var group := str(ctx.get("corps_id",ctx["task"].get("commander",ctx["battle_id"])))
			var target_key := group + ":" + str(target.get("id",""))
			if target.get("routing",false) and float(targets.get(target_key,0)) >= maxf(1,float(target.get("strength_estimate",0))) * 1.5 and not ordered.is_empty(): denied = "追击兵力已足，保持职责覆盖"; continue
			if candidate["canonical_plan"]["template"] == "flank_then_engage" and candidate["stage"] == "execute" and not ctx["knowledge"]["allies"].any(func(a): return a.get("can_support",false) and a.get("role","") == "main_attack" and int(a.get("cell",-1)) >= 0 and not target.is_empty() and Tactical.cell_distance(int(a["cell"]),int(target["cell"])) <= 3):
				denied = "尚未确认正面牵制，保持侧翼等待位"
				candidate = candidate.duplicate(true)
				candidate["action"]["type"] = "hold"
				candidate["stage"] = "wait_support"
			var result: Dictionary = proposed.duplicate(true)
			result["candidate_id"] = candidate["id"]
			result["coordinated_candidate"] = candidate
			for entry in ranked:
				if entry["candidate"]["id"] == candidate["id"]:
					result["score"] = entry["score"]
					result["score_breakdown"] = entry["breakdown"].duplicate()
			if not denied.is_empty():
				result["coordination_reason"] = denied
				result["original_candidate_id"] = proposed.get("candidate_id","")
				result["reason_summary"] = denied
				result["source"] = "coordination"
			chosen[ctx["actor_key"]] = result
			result["coordination_intent"] = {"actor_key":ctx["actor_key"],"round":ctx["battle_round"],"goal_cell":candidate["canonical_plan"]["goal_cell"],"target_id":target.get("id",""),"ally_id":candidate["canonical_plan"]["ally_id"],"eta_rounds":candidate["eta_rounds"],"expires_round":int(ctx["battle_round"])+2,"phase":candidate["stage"],"support_confirmed":candidate["canonical_plan"]["template"] in ["cover_ally","reserve_reinforce"]}
			for cell in candidate["action"]["path"].slice(1): reserved[str(ctx["battle_id"])+":"+str(cell)] = ctx["actor_key"]
			if not target.is_empty(): targets[target_key] = float(targets.get(target_key,0)) + float(ctx["self"]["strength"])
			break
		if not chosen.has(ctx["actor_key"]): chosen[ctx["actor_key"]] = {"error":"no_legal_action","coordination_reason":denied}
	return chosen

static func priority(ctx: Dictionary) -> int:
	return (100 if ctx["local_state"] in ["disengaging_local","repositioning"] else 60 if ctx["crisis"] else 0) + (30 if ctx["authority"]["must_hold_objective"] else 0) + int(ctx["self"].get("blocked_days",0)) * 10
