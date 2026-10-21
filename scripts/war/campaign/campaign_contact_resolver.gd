class_name CampaignContactResolver
extends RefCounted
## 行军与接敌结算：道路行军、接触判定、道路交战结算、首次接敌特效与地形查询。
##
## 所有函数都是静态的，第一个参数 war 是 CampaignState 实例（不标类型，避免与它互相引用）。

const Process = preload("res://scripts/officers/officer_process.gd")
const Signature = preload("res://scripts/officers/signature_traits.gd")
const Explain = preload("res://scripts/officers/officer_explain.gd")
const Fate = preload("res://scripts/war/campaign/officer_fate.gd")
const Combat = preload("res://scripts/war/battle/combat_system.gd")
const Tactical = preload("res://scripts/war/battle/tactical_battlefield.gd")
const Duel = preload("res://scripts/war/duel/duel_system.gd")
const Feedback = preload("res://scripts/war/battle/battle_feedback.gd")
const Battlefields = preload("res://scripts/war/campaign/campaign_battlefields.gd")


## 节点地形：关隘为山地，其余按地区。
static func _terrain(war, node: String) -> String:
	var place: Dictionary = war.graph.places.get(node, {})
	if str(place.get("type", "")) == "pass":
		return "mountains"
	return str(war.rules["terrain_regions"].get(str(place.get("region_id", "")), "plains"))


## 推进一日行军，返回各军移动前后位置；有战术战场时交给战术层。
static func _move_all(war) -> Dictionary:
	if war.state.has("battlefield"): return Tactical.move(war)
	var motions: Dictionary = Battlefields.run(war, "move")
	for army in war.active_armies():
		if army.has("tactical"): continue
		if not war.ready(army): continue
		var location: Dictionary = army["location"]
		var before: Dictionary = location.duplicate(true)
		if str(location.get("edge", "")) != "" and str(army["action"]["type"]) in ["march", "continue", "withdraw"]:
			var edge: Dictionary = war.graph.edges.get(location["edge"], {})
			if war.graph.blocked.has(location["to"]) or war.graph.blocked.has(location["from"]):
				army["action"] = {"type": "hold"}
				war._report(army, "通路受阻", "%s行军通路受阻，正在重新判断。" % army["name"], true)
			else:
				var leader: Dictionary = army
				if army.has("corps_id"): leader = war.state["armies"][war.state["corps"][army["corps_id"]]["root_id"]]
				var speed: float = Process.march_speed(leader, _terrain(war, str(location["node"])))
				location["progress"] = minf(1.0, float(location["progress"]) + speed / maxf(float(edge.get("cost", 1)) * float(war.rules["route_days_per_cost"]), 1))
				army["fatigue"] = minf(100, float(army["fatigue"]) + Process.fatigue_cost(army, 3.0))
				if float(location["progress"]) >= 1.0:
					location["node"] = location["to"]
					location["edge"] = ""
					location["progress"] = 0.0
		motions[army["id"]] = {"before": before, "after": location.duplicate(true)}
	return motions


## 位置在所在道路上的坐标（0 为道路起点）。
static func _edge_coordinate(war, location: Dictionary) -> float:
	var edge: Dictionary = war.graph.edges.get(location.get("edge", ""), {})
	return float(location.get("progress", 0)) if str(location.get("from", "")) == str(edge.get("from", "")) else 1.0 - float(location.get("progress", 0))


## 两军今日是否接触，含道路上相向穿过。
static func _contact(war, a: Dictionary, b: Dictionary, motions: Dictionary) -> bool:
	var la: Dictionary = a["location"]
	var lb: Dictionary = b["location"]
	if str(la.get("edge", "")) == "" and str(lb.get("edge", "")) == "":
		return str(la["node"]) == str(lb["node"])
	var ma: Dictionary = motions.get(a["id"], {"before": la, "after": la})
	var mb: Dictionary = motions.get(b["id"], {"before": lb, "after": lb})
	var ea: String = str(ma["before"].get("edge", ""))
	var eb: String = str(mb["before"].get("edge", ""))
	if ea == "": ea = str(la.get("edge", ""))
	if eb == "": eb = str(lb.get("edge", ""))
	if ea == "" or ea != eb:
		return false
	var aa: Dictionary = ma["before"] if str(ma["before"].get("edge", "")) != "" else la
	var bb: Dictionary = mb["before"] if str(mb["before"].get("edge", "")) != "" else lb
	var old_delta: float = _edge_coordinate(war, aa) - _edge_coordinate(war, bb)
	var a_end: float = _edge_coordinate(war, la) if str(la.get("edge", "")) != "" else (1.0 if str(la["node"]) == str(war.graph.edges[ea]["to"]) else 0.0)
	var b_end: float = _edge_coordinate(war, lb) if str(lb.get("edge", "")) != "" else (1.0 if str(lb["node"]) == str(war.graph.edges[ea]["to"]) else 0.0)
	return absf(a_end - b_end) < 0.13 or old_delta * (a_end - b_end) <= 0


## 结算一日接敌：追击、道路会战、伤亡与士气。
static func _resolve_contacts(war, motions: Dictionary) -> void:
	if war.state.has("battlefield"):
		Tactical.resolve(war)
		return
	Battlefields.prepare(war)
	Battlefields.roads(war, motions)
	Battlefields.run(war, "resolve")
	var armies: Array = war.active_armies().filter(func(army): return not army.has("tactical") and war.ready(army))
	var engaged: Dictionary = {}
	for i in range(armies.size()):
		for j in range(i + 1, armies.size()):
			var a: Dictionary = armies[i]
			var b: Dictionary = armies[j]
			if not war.hostile(str(a["faction"]), str(b["faction"])) or engaged.has(a["id"]) or engaged.has(b["id"]) or not _contact(war, a, b, motions):
				continue
			if not bool(war.orders_for(a)["engage"]) or not bool(war.orders_for(b)["engage"]):
				var initiated := false
				for side in [a, b]:
					var type: String = side["action"]["type"]
					initiated = initiated or (type == "engage" and bool(war.orders_for(side)["engage"])) or (type == "pursue" and bool(war.orders_for(side)["pursue"]))
				if not initiated: continue
			engaged[a["id"]] = true
			engaged[b["id"]] = true
			if bool(a["returning"]) or bool(b["returning"]):
				var fleeing: Dictionary = a if bool(a["returning"]) else b
				var pursuer: Dictionary = b if bool(a["returning"]) else a
				if bool(war.orders_for(pursuer)["pursue"]) and str(pursuer["action"]["type"]) in ["pursue", "engage"]:
					pursuer["combat_tick"] = int(war.state["tick"])
					var chased: int = Combat.apply_loss(fleeing, mini(Combat.strength(fleeing), int(Combat.strength(pursuer) * Process.pursuit_rate(pursuer, fleeing))), true)
					war._report(fleeing, "遭遇追击", Explain.signed(fleeing, "withdraw撤离", "%s撤退途中被追击，%d人被俘。" % [fleeing["name"], chased]), true)
					war._report(pursuer, "追击", Explain.signed(pursuer, "pursuit追击", "追击%s，俘获%d人。" % [fleeing["name"], chased]), false)
					war._remember_loss(fleeing, "遭遇追击")
					pursuer["fatigue"] = minf(100, float(pursuer["fatigue"]) + Process.fatigue_cost(pursuer, 8, true))
				continue
			# Freeze road movement at the contact point for the next day's battle.
			var edge_id: String = str(a["location"].get("edge", ""))
			if edge_id != "" and str(b["location"].get("edge", "")) == edge_id:
				var coordinate: float = (_edge_coordinate(war, a["location"]) + _edge_coordinate(war, b["location"])) * 0.5
				for combatant in [a, b]:
					combatant["location"]["progress"] = coordinate if str(combatant["location"]["from"]) == str(war.graph.edges[edge_id]["from"]) else 1.0 - coordinate
			var side_a: Array = [a]
			var side_b: Array = [b]
			for support in armies:
				if engaged.has(support["id"]) or bool(support["returning"]): continue
				if str(support["faction"]) == str(a["faction"]) and _contact(war, support, b, motions):
					side_a.append(support)
					engaged[support["id"]] = true
				elif str(support["faction"]) == str(b["faction"]) and _contact(war, support, a, motions):
					side_b.append(support)
					engaged[support["id"]] = true
			var terrain: String = _terrain(war, str(a["location"]["node"]))
			for attacker in side_a:
				for defender in side_b: _battle_contact(war, attacker, defender)
			for attacker in side_b:
				for defender in side_a: _battle_contact(war, attacker, defender)
			if not side_a.is_empty() and not side_b.is_empty(): Duel.challenge(war, side_a[0], side_b[0])
			var combined_a: Dictionary = Combat.aggregate(side_a)
			var combined_b: Dictionary = Combat.aggregate(side_b)
			var hit_a := Combat.losses_detail(combined_b, combined_a, war.rules, terrain, war.rng.randf_range(0.9, 1.1))
			var loss_a: int = int(hit_a["loss"])
			var hit_b := Combat.losses_detail(combined_a, combined_b, war.rules, terrain, war.rng.randf_range(0.9, 1.1))
			var loss_b: int = int(hit_b["loss"])
			var report_losses := {}
			var credit_a := {}
			var credit_b := {}
			var commanders := {}
			for member in side_a + side_b: commanders[member["id"]] = member["officer_id"]
			for member in side_a: credit_a[member["id"]] = Combat.strength(member)
			for member in side_b: credit_b[member["id"]] = Combat.strength(member)
			var personal_a := Fate.personal_weights(side_a, credit_a, float(hit_b.get("personal_fraction", 0)), war.rules)
			var personal_b := Fate.personal_weights(side_b, credit_b, float(hit_a.get("personal_fraction", 0)), war.rules)
			var sides := [[side_a, loss_a, loss_b, Combat.strength(combined_b)], [side_b, loss_b, loss_a, Combat.strength(combined_a)]]
			for side_index in sides.size():
				var side: Array = sides[side_index]
				var members: Array = side[0]
				# Index, not members == side_a: Array equality is a deep value compare.
				var enemy_members: Array = sides[1 - side_index][0]
				var total_strength: int = Combat.strength(Combat.aggregate(members))
				var remaining: int = int(side[1])
				for member in members:
					member["battle_factors"] = Feedback.factors(enemy_members[0], member, war.rules, terrain)
					member["combat_tick"] = int(war.state["tick"])
					var loss: int = mini(remaining, int(ceil(float(side[1]) * Combat.strength(member) / maxf(total_strength, 1))))
					var before_strength := Combat.strength(member)
					var dead_before := int(member["dead"])
					loss = Combat.apply_loss(member, loss, false, 0.0, 0.0, 0.5, war.rules)
					Fate.credit(war, credit_b if side_index == 0 else credit_a, int(member["dead"]) - dead_before, commanders, personal_b if side_index == 0 else personal_a)
					report_losses[member["id"]] = loss
					Feedback.loss(war, member, loss)
					Combat.battle_morale(member, loss, float(side[2]) * before_strength / maxf(total_strength, 1), before_strength, float(side[3]), total_strength, float(side[3]), false, 0.0, 0.5, war.rules)
					remaining -= loss
					member["fatigue"] = minf(100, float(member["fatigue"]) + Process.fatigue_cost(member, 5, true))
					war._check_rout(member)
					if member["returning"] or member["status"] == "ended":
						for winner in enemy_members: war._battle_victory(winner)

			for member in side_a + side_b:
				var loss: int = int(report_losses.get(member["id"], 0))
				war._report(member, "交战", "%s与敌军交战，本日损失%d人，士气%d。" % [member["name"], loss, int(member["morale"])], true)


## 记录首次近战并触发署名特性的接敌效果。
static func _battle_contact(war, attacker: Dictionary, defender: Dictionary, melee: bool = true) -> void:
	if melee and not attacker.has("first_melee_tick"): attacker["first_melee_tick"] = war.state["tick"]
	if melee and not defender.has("first_melee_tick"): defender["first_melee_tick"] = war.state["tick"]
	if melee and Signature.opening(attacker, defender):
		war._report(attacker, "小霸王连胜", "%s小霸王：连续主动出战，首次接敌士气冲击提高8%%。" % attacker["name"], false)
	if Signature.first_contact(attacker, defender, melee):
		attacker["first_contact_effect_tick"] = war.state["tick"]
		defender["first_contact_effect_tick"] = war.state["tick"]
		war._report(defender, "武圣威压", "%s武圣：与%s首次正面交锋，%s士气下降8。" % [attacker["name"], defender["name"], defender["name"]], true)
