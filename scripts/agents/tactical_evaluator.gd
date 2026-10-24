extends RefCounted

const Tactical = preload("res://scripts/war/battle/tactical_battlefield.gd")
const Plan = preload("res://scripts/agents/tactical_plan.gd")
const Preview = preload("res://scripts/agents/tactical_projection.gd")
const Roles = preload("res://scripts/war/battle/troop_roles.gd")

# Shared positional consequences are calculated once per frozen cell. Different
# plans can use that cell without recomputing every enemy/ally combination.
static func position_forecast(context: Dictionary, cell: int) -> Dictionary:
	if not context.has("_positions"): context["_positions"] = {}
	if context["_positions"].has(cell): return context["_positions"][cell]
	var own: Dictionary = context["self"]
	if not context.has("_enemy_support"):
		context["_enemy_support"] = {}
		for enemy in context["knowledge"]["enemies"]:
			var count := 1
			var enemy_range := int(context["exchanges"].get(enemy["id"],{}).get("range",1))
			for ally in context["knowledge"]["allies"]:
				if ally.get("can_support",false) and int(ally.get("cell",-1)) >= 0 and int(enemy.get("cell",-1)) >= 0 and Tactical.cell_distance(int(ally["cell"]),int(enemy["cell"])) <= enemy_range: count += 1
			context["_enemy_support"][enemy["id"]] = count
	var result := {"loss":0.0,"threats":0,"uncertainty":0.0,"enemy_strength":0.0,"cover":0.0,"friendly":maxf(1,float(own["strength"])),"ranged_bad":false}
	for enemy in context["knowledge"]["enemies"]:
		if int(enemy.get("cell",-1)) < 0: continue
		var age := maxi(0,int(context["battle_round"])-int(enemy["observed_round"]))
		result["uncertainty"] += (1.0-float(enemy.get("confidence",1)))*0.1 + age*0.05
		var gap := Tactical.cell_distance(cell,int(enemy["cell"]))
		var exchange: Dictionary = context["exchanges"].get(enemy["id"],{})
		if gap <= int(exchange.get("range",1)) and (gap <= 1 or Tactical.Fort.line_of_sight(context["knowledge"]["terrain"],cell,int(enemy["cell"]))):
			result["loss"] += float(exchange.get("own_loss_ranged",0) if gap > 1 else exchange.get("own_loss",0)) / int(context["_enemy_support"][enemy["id"]])
			result["threats"] += 1
			result["enemy_strength"] += float(enemy.get("strength_estimate",0))
			if own["kind"] == "archers" and gap <= 1: result["ranged_bad"] = true
	for ally in context["knowledge"]["allies"]:
		if ally.get("can_support",false) and int(ally.get("cell",-1)) >= 0 and Tactical.cell_distance(cell,int(ally["cell"])) <= 3:
			result["cover"] += 1
			result["friendly"] += float(ally["strength"])
	context["_positions"][cell] = result
	return result

static func axis(context: Dictionary, name: String) -> float:
	return clampf((float(context["officer"].get("personality", {}).get(name,50)) - 50.0) / 50.0,-1,1)

static func rank(context: Dictionary) -> Array:
	if context.has("_ranking"): return context["_ranking"]
	context["_positions"] = {}
	context.erase("_enemy_support")
	var ranked: Array = []
	for candidate in context.get("candidates",[]):
		var result := evaluate(context,candidate)
		ranked.append({"candidate":candidate,"score":result["score"],"breakdown":result["breakdown"]})
	ranked.sort_custom(func(a,b): return a["score"] > b["score"] if not is_equal_approx(a["score"],b["score"]) else str(a["candidate"]["id"]) < str(b["candidate"]["id"]))
	# Only the top few receive the bounded two-round projection. Never executes rules.
	for entry in ranked.slice(0,int(context["settings"].get("prediction_candidates",4))):
		var f: Dictionary = entry["candidate"]["forecast"]
		var projection := Preview.project(context,entry["candidate"])
		f["projection"] = projection
		var gain := clampf(float(projection["future_gain"])*0.75 + float(f.get("future_gain",0))*0.25,-5,5)
		entry["breakdown"]["短期计划"] = gain
		entry["score"] += gain
	ranked.sort_custom(func(a,b): return a["score"] > b["score"] if not is_equal_approx(a["score"],b["score"]) else str(a["candidate"]["id"]) < str(b["candidate"]["id"]))
	context["_ranking"] = ranked
	return ranked

static func evaluate(context: Dictionary, candidate: Dictionary) -> Dictionary:
	var own: Dictionary = context["self"]
	var plan: Dictionary = candidate["canonical_plan"]
	var template := str(plan["template"])
	var start := int(own["cell"])
	var cell := int(candidate["next_cell"])
	var strength := maxf(1,float(own["strength"]))
	var role := str(context["task"]["role"])
	var position := position_forecast(context,cell)
	var loss := float(position["loss"])
	var kill := 0.0
	var threats := int(position["threats"])
	var uncertainty := float(position["uncertainty"])
	var enemy_strength := float(position["enemy_strength"])
	var target: Dictionary = candidate["target"]
	if not target.is_empty() and template != "rally":
		var gap := Tactical.cell_distance(cell,int(target["cell"]))
		if gap <= int(own["attack_range"]):
			var exchange: Dictionary = context["exchanges"].get(target["id"],{})
			kill = float(exchange.get("enemy_loss_ranged",0) if gap > 1 else exchange.get("enemy_loss",0))
	var cover := float(position["cover"])
	var friendly := float(position["friendly"])
	var isolated := 1.0 if cover == 0 and enemy_strength > strength else 0.0
	# A reachable, unprotected bow line is the cavalry's best target. Escort and
	# screen risk are evaluated first, so protection outranks the type bonus.
	var type_bonus := 0.0
	if own["kind"] == "cavalry" and template in ["advance","flank_then_engage"] and not target.is_empty():
		if Roles.kind_from_mix(target.get("unit_mix_estimate",{})) == "archers":
			var target_cell := int(target["cell"])
			if Tactical.cell_distance(cell,target_cell) <= int(own["attack_range"]) + 2:
				var escort := 0
				for other in context["knowledge"]["enemies"]:
					if other["id"] == target["id"]: continue
					var other_cell := int(other.get("cell",-1))
					if other_cell < 0: continue
					if Tactical.cell_distance(other_cell,target_cell) <= int(context["settings"].get("cavalry_escort_radius",1)): escort += 1
				var exposure := clampf(1.0 - float(escort) * float(context["settings"].get("cavalry_escort_penalty",0.5)),0.0,1.0)
				type_bonus = float(context["settings"].get("cavalry_archer_bonus",16)) * exposure
	# Bows price a visible cavalry that could close next round: a fallback cell
	# that restores distance (and cover) scores, holding in its face scores down.
	var cavalry_answer := 0.0
	if own["kind"] == "archers":
		var threat_now := Tactical.cavalry_threat(context["knowledge"]["enemies"], start)
		if threat_now < 99.0:
			var threat_there := Tactical.cavalry_threat(context["knowledge"]["enemies"], cell)
			if template == "rally" and threat_there > threat_now:
				cavalry_answer += float(context["settings"].get("archer_cavalry_retreat_bonus",10)) * minf(2.0, threat_there - threat_now)
				if cover > 0: cavalry_answer += float(context["settings"].get("archer_cavalry_cover_bonus",6))
			elif template in ["advance","fire_with_cover","flank_then_engage"] and threat_there <= threat_now:
				cavalry_answer -= float(context["settings"].get("archer_cavalry_hold_penalty",8))
	var crisis := clampf((55-float(own["organization"]))/35.0,0,1) + clampf((50-float(own["morale"]))/30.0,0,1) + clampf((float(own["fatigue"])-60)/40.0,0,1)
	var goal := int(candidate["action"]["goal_cell"])
	if template == "fire_with_cover" and not target.is_empty(): goal = int(target["cell"])
	var progress := float(Tactical.cell_distance(start,goal) - Tactical.cell_distance(int(candidate.get("progress_cell",cell)),goal))
	var task_value := 12.0
	if template in ["advance","fire_with_cover"]: task_value = 20 + progress * 7
	if context.get("last_line",false) and template in ["advance","fire_with_cover"]: task_value += 22
	if template == "fire_with_cover" and cell == start and kill > 0: task_value += 6
	if template == "flank_then_engage": task_value = (32.0 if role in ["flank","raid_rear"] else 20.0) + progress * 6
	if template == "hold_line":
		task_value = 34 if role in ["command","reserve"] else 14
		if role == "command" and context.get("siege_approach",false) and int(context["task"]["anchor_cell"]) >= 0 and start != int(context["task"]["anchor_cell"]): task_value -= 20
		if role == "regroup": task_value = 36 + progress*7
		if context.get("last_line",false) and (not context["knowledge"]["enemies"].is_empty() or int(context["task"]["anchor_cell"]) >= 0): task_value -= 15
		if role in ["command","reserve"] and int(plan["goal_cell"]) != start: task_value += progress * 7
		if context["authority"]["must_hold_objective"]: task_value += 40
	if template == "approach_objective": task_value = 42 + progress * 9 + (18 if Tactical.cell_distance(start,goal) <= 1 else 0)
	if template == "reserve_reinforce": task_value = 58 + progress * 6
	if template == "cover_ally": task_value = 25 + progress * 5 + (16 if candidate["ally"].get("needs_support",false) else 0)
	if template == "scout": task_value = 12 + (10 if context["knowledge"]["enemies"].is_empty() else 0) + (20 + progress*7 if goal != start else 0)
	var point: Dictionary = context["knowledge"]["terrain"].get("control_point",{})
	if not point.is_empty() and not target.is_empty() and Tactical.cell_distance(int(target["cell"]),int(point["cell"])) <= int(point.get("radius",1)) and Tactical.cell_distance(cell,int(point["cell"])) <= int(point.get("radius",1)):
		if template in ["advance","fire_with_cover"]: task_value += 40
	if template == "approach_objective" and cell == start and kill == 0 and not point.is_empty() and point.get("contested",false): task_value -= 15
	if template == "rally":
		task_value = 4 + crisis * 35 + (16 if context["local_state"] in ["disengaging_local","repositioning","recovering"] else 0)
		if own.get("under_fire",false) and cell == start: task_value -= 20
		if (own["kind"] == "archers" and int(own["contact"]["adjacent_enemies"]) > 0) or (role == "command" and own.get("under_fire",false)): task_value += 35
		if context["local_state"] == "ready_to_rejoin": task_value -= 50
		if cell == start and candidate["stage"] != "recover": task_value -= 12
	var active_enemy: bool = not context["knowledge"]["enemies"].is_empty()
	if template == "hold_line" and role not in ["reserve","command","rear_guard"] and active_enemy and not context["authority"]["must_hold_objective"]: task_value -= 6
	if context["deployment_pending"] and cell != start: task_value -= 100
	var loss_ratio := clampf(loss / strength,0,1)
	var loss_cost := minf(55,loss_ratio * 180) + maxf(0,threats-1) * 5
	var kill_value := minf(24,kill / strength * 140)
	var risk := clampf(loss_ratio * 2 + isolated * 0.35 + maxf(0,threats-1)*0.15 + maxf(0,enemy_strength/friendly-1.5)*0.15,0,1)
	var ranged_bad: bool = position["ranged_bad"]
	var terrain_cost := 0.0
	if own["kind"] == "cavalry" and Tactical.terrain_class(cell) in ["mountains","marsh","ford","forest"]: terrain_cost = 9
	var duty_cost := 0.0
	var skills: Dictionary = context["officer"].get("skills",{})
	var position_skill := float(skills.get("布阵",50))/100.0
	var ordered_siege: bool = role == "command" and context.get("siege_approach",false) and template == "approach_objective"
	if role in ["command","reserve"] and not context.get("last_line",false) and not ordered_siege and template not in ["hold_line","rally","reserve_reinforce"] and not context["crisis"]: duty_cost = 15
	var p := {}
	p["风险承受"] = axis(context,"风险承受") * (risk * 12 + (5 if template in ["advance","flank_then_engage"] else -5 if template == "rally" else 0))
	p["野心"] = axis(context,"野心") * (4 if template in ["approach_objective","flank_then_engage"] else -2)
	p["耐心"] = axis(context,"耐心") * (5 if template == "hold_line" else -3 if template == "flank_then_engage" else 0)
	p["决断"] = axis(context,"决断") * (4 if progress > 0 else -2)
	p["自制"] = axis(context,"自制") * (-5 if target.get("routing",false) else 3 if template == "hold_line" else 0)
	p["猜疑"] = -axis(context,"猜疑") * uncertainty * (12 if template == "flank_then_engage" else 4)
	p["自尊"] = axis(context,"自尊") * (2 if template in ["advance","reserve_reinforce"] else -1)
	p["同理心"] = axis(context,"同理心") * (10 if template == "cover_ally" else 0)
	p["秩序偏好"] = axis(context,"秩序偏好") * (6 if template in ["hold_line","approach_objective"] else -3)
	p["务实"] = axis(context,"务实") * (progress * 2 + kill_value * 0.15 - risk * 4)
	var grudge: bool = context.get("experience",{}).get("enemy_notes",{}).get(target.get("id",""),{}).get("beat_us",false)
	p["记仇"] = axis(context,"记仇") * (3 if grudge else 0)
	p["容人"] = axis(context,"容人") * (5 if template == "cover_ally" else 2 if template == "hold_line" else 0)
	p["贪欲"] = axis(context,"贪欲") * (3 if target.get("routing",false) else 0)
	p["忠义"] = axis(context,"忠义") * (5 if template in ["cover_ally","approach_objective","hold_line"] else 0)
	var personality := 0.0
	for value in p.values(): personality += float(value)
	personality = clampf(personality,-20,20)
	var stable := float(context["settings"].get("stay_bonus",8)) * (1 + axis(context,"耐心") * 0.3 + (float(skills.get("沉着",50))-50)/500.0) if Plan.same(plan,context["current_plan"]) and not context["crisis"] else 0.0
	var support_value := minf(6,cover*2) if template != "rally" else minf(8,cover*3)
	support_value *= 0.5 + position_skill
	var b := {"职责收益":task_value,"有效杀伤":kill_value,"预计损失":-loss_cost,"协同掩护":support_value,"孤立风险":-isolated*10,"射程风险":-18.0 if ranged_bad else 0.0,"地形通路":-terrain_cost,"职责覆盖":-duty_cost,"情报不确定":-minf(8,uncertainty*8),"人格倾向":personality,"计划持续":stable,"兵种克制":type_bonus,"骑兵威胁":cavalry_answer}
	if context["supply_enabled"]:
		b["补给安全"] = (15 if template == "rally" else -10) if float(own.get("grain_days",100)) < 3 else 0
	var score := 0.0
	for name in b:
		b[name] *= float(context["settings"].get("factor_weights",{}).get(name,1))
		score += float(b[name])
	var memory_cost := 0.0
	for note in context.get("experience",{}).get("tactical_memory",[]):
		if note.get("template","") == template and note.get("target","") == plan.get("target_id",""):
			memory_cost += maxf(0,1.0-float(int(context["battle_round"])-int(note["round"]))/20.0) * (2 if note["event"] == "blocked" else 1)
	b["经验提醒"] = -minf(5,memory_cost)
	score += float(b["经验提醒"])
	var future := progress * 2 + (5 if template == "flank_then_engage" and cover > 0 else 0) - crisis * (3 if template != "rally" else -2)
	if template == "flank_then_engage": future *= 0.5 + float(skills.get("奇袭",50))/100.0
	if template == "rally": future += (float(skills.get("治军",50))-50)/20.0
	var skill := float(context["officer"].get("skills",{}).get("智计",50))/100.0
	candidate["forecast"] = {"own_loss":int(loss),"enemy_loss":int(kill),"risk":risk,"loss_interval":[int(loss*0.7),int(loss*1.4)],"friendly_ready_strength":int(friendly),"eta_rounds":candidate["eta_rounds"],"future_gain":future*skill,"horizon":2,"personality":p,"uncertainty":uncertainty}
	return {"score":score,"breakdown":b}

static func choose(context: Dictionary) -> Dictionary:
	var ranked := rank(context)
	if ranked.is_empty(): return {"error":"no_legal_action"}
	var best: Dictionary = ranked[0]
	var current: Dictionary = {}
	for entry in ranked:
		if Plan.same(entry["candidate"]["canonical_plan"],context["current_plan"]): current = entry; break
	if not current.is_empty() and not context["crisis"] and (not context.get("review_now",true) or best["score"] - current["score"] < float(context["settings"].get("switch_gain",10))) and int(context["self"].get("blocked_days",0)) < 2: best = current
	var candidate: Dictionary = best["candidate"]
	var why := reason(context,candidate)
	return {"candidate_id":candidate["id"],"reason_summary":why,"source":"safety" if context["crisis"] else "baseline","score":best["score"],"score_breakdown":best["breakdown"],"margin":float(ranked[0]["score"])-float(ranked[1]["score"]) if ranked.size()>1 else 999}

static func reason(context: Dictionary, candidate: Dictionary) -> String:
	match candidate["canonical_plan"]["template"]:
		"rally": return "先脱离眼前接触，在接应位置整顿，组织恢复后重新投入"
		"fire_with_cover": return "保持有效射程与射界，近敌逼近时寻找掩护换位"
		"flank_then_engage": return "选择可通行侧路，等待正面配合后投入；威胁加重时改判"
		"reserve_reinforce": return "已确认友军承压，在授权范围内投入预备补位"
		"cover_ally": return "接应已知友军，保持掩护与退路，任务完成后归位"
		"approach_objective": return "优先争夺职责目标，保留控制位置，避免过量追击"
		"scout": return "敌情不足或已过期，先核实信息再深入"
		"hold_line": return "保持职责与有效威胁，等待配合并检查战线变化"
	return "按已知敌情协同接敌，兼顾损失、支援与退路"
