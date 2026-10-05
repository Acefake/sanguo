extends RefCounted
const Combat = preload("res://scripts/war/combat_system.gd")
const Terrain = preload("res://scripts/war/battle_terrain.gd")
const Formation = preload("res://scripts/war/battle_formation.gd")

static func advantage(armies: Array, faction: String) -> float:
	var total := 0.0
	for army in armies:
		if army.get("faction", "") != faction or army.get("status","active") == "ended": continue
		total += Combat.strength(army) * (0.5+float(army.get("morale",100))/200) * (0.5+float(army.get("organization",100))/200) * Formation.attack(army.merged({"formation_locked":false},true))
	return total
static func visible_advantage(war) -> Dictionary:
	var own: String = war.state["player_faction"]
	var ours := advantage(war.active_armies(own),own)
	var theirs := 0.0
	var seen := {}
	if war.store.battle_test:
		for army in war.active_armies():
			if army["faction"] != own: theirs += advantage([army],army["faction"])
	else:
		for army in war.active_armies(own):
			for enemy in army["intel"]["enemies"].values():
				if seen.has(enemy["id"]) or int(enemy["observed_at"]) != int(war.state["tick"]): continue
				seen[enemy["id"]] = true
				# Enemy morale and organization are not exposed by the scouting contract.
				theirs += float(enemy["strength_estimate"])*0.75*0.75
	return {"ours":ours,"theirs":theirs,"percent":100*ours/maxf(ours+theirs,1),"estimated":not war.store.battle_test}
static func factors(attacker: Dictionary, defender: Dictionary, rules: Dictionary, terrain: String) -> Array:
	var breakdown := Combat.power_breakdown(attacker,rules,terrain,defender)
	var entries := []
	var threshold := float(rules.get("feedback",{}).get("factor_threshold",0.05))
	if terrain != "plains": entries.append({"weight":1.3,"text":"交战地形：%s，防护×%.2f" % [Terrain.name_of(terrain),float(Terrain.settings(terrain,rules).get("defense",1))]})
	var labels := {"morale":"士气","training":"训练","equipment":"军备","organization":"组织","fatigue":"疲劳","command":"指挥","unit_skill":"兵种发挥","terrain":"地形限制","formation":"阵型","delay":"进入地形迟滞","wounded":"主将带伤"}
	for key in labels:
		var value := float(breakdown.get(key,1))
		if absf(value-1) <= threshold: continue
		entries.append({"weight":absf(value-1)+(1.0 if key == "morale" and float(attacker.get("morale",100)) < 50 else 0),"text":"%s%s：输出×%.2f" % [attacker.get("name","攻方"),labels[key],value]})
	var counters: float = breakdown["counters"]
	if counters-1 > threshold: entries.append({"weight":counters-1,"text":"兵种克性：伤害×%.2f" % counters})
	entries.sort_custom(func(a,b): return a["weight"] > b["weight"])
	var output := []
	for entry in entries.slice(0,int(rules.get("feedback",{}).get("max_factors",2))): output.append(entry["text"])
	return output
static func book(war) -> Dictionary:
	if not war.state.get("battlefield", {}).is_empty(): return war.state["battlefield"]
	if not war.state.has("battle_feedback"): war.state["battle_feedback"] = {}
	return war.state["battle_feedback"]
static func loss(war, army: Dictionary, amount: int) -> void:
	if int(army.get("daily_loss_tick", -1)) != int(war.state["tick"]): army["daily_loss"] = 0
	army["daily_loss_tick"] = int(war.state["tick"])
	army["daily_loss"] += amount
static func event(war, kind: String, message: String, faction: String = "") -> void:
	var data := book(war)
	if not data.has("pending_events"): data["pending_events"] = []
	var entry := {"kind":kind,"message":message,"faction":faction}
	if not entry in data["pending_events"]: data["pending_events"].append(entry)
static func snapshot(war) -> Array:
	var sides := {}
	for army in war.state["armies"].values():
		var board: Dictionary = war.state.get("battlefield",{})
		if not board.is_empty() and army.get("battlefield_id","") != board.get("battle_id",""): continue
		var faction: String = army["faction"]
		if not sides.has(faction): sides[faction] = {"faction":faction,"initial":0,"strength":0,"dead":0,"wounded":0,"captured":0,"deposited":0,"morale":0.0,"org":0.0}
		var row: Dictionary = sides[faction]
		var strength := Combat.strength(army)
		for ledger in ["dead","wounded","captured","deposited"]: row[ledger] += int(army.get(ledger,0))
		row["initial"] += int(army.get("initial_strength",0))
		row["strength"] += strength
		row["morale"] += float(army.get("morale",100))*strength
		row["org"] += float(army.get("organization",100))*strength
	for row in sides.values():
		row["morale"] /= maxf(row["strength"],1)
		row["org"] /= maxf(row["strength"],1)
		row["accounted"] = row["strength"]+row["dead"]+row["wounded"]+row["captured"]+row["deposited"]
	return sides.values()
static func record_day(war, before: Array) -> void:
	var data := book(war)
	if not data.has("started_at"): data["started_at"] = int(war.state["tick"]) - 1
	if not data.has("log"): data["log"] = []
	var losses := {}
	var sides := snapshot(war)
	for row in sides:
		var prior := 0
		for previous in before:
			if previous["faction"] == row["faction"]: prior = previous["dead"]+previous["wounded"]+previous["captured"]
		losses[row["faction"]] = maxi(0,int(row["dead"])+int(row["wounded"])+int(row["captured"])-prior)
	var events: Array = data.get("pending_events",[]).duplicate(true)
	data["pending_events"] = []
	var entry := {"tick":war.state["tick"],"sides":sides,"losses":losses,"events":events}
	if not data["log"].is_empty() and int(data["log"][-1]["tick"]) == int(war.state["tick"]):
		for previous in data["log"][-1]["events"]:
			if not previous in entry["events"]: entry["events"].push_front(previous)
		for faction in losses: entry["losses"][faction] = maxi(losses[faction],data["log"][-1]["losses"].get(faction,0))
		data["log"][-1] = entry
	else: data["log"].append(entry)
	while data["log"].size() > int(war.rules.get("feedback",{}).get("max_log",240)): data["log"].pop_front()
static func summary(war) -> Dictionary:
	var data := book(war)
	var log: Array = data.get("log",[])
	var duels: Array = war.state.get("duels",{}).get("records",[]).filter(func(d): return int(d["tick"]) >= int(data.get("started_at",0)))
	var events := []
	for row in log: events.append_array(row["events"])
	var loot := {}
	for corps in war.state["corps"].values():
		var root: Dictionary = war.state["armies"].get(corps["root_id"],{})
		if data.has("battle_id") and root.get("battlefield_id","") != data["battle_id"]: continue
		loot[corps["faction"]] = float(loot.get(corps["faction"],0))+float(corps.get("looted_grain",0))
	return {"days":int(data.get("ended_at",war.state["tick"]))-int(data.get("started_at",0)),"winner":data.get("winner","交战中"),"sides":snapshot(war),"log":log,"duels":duels.filter(func(d):return d["result"] != "refused").size(),"challenges":duels.size(),"overwhelming":duels.filter(func(d):return d["result"] == "overwhelming").size(),"events":events,"loot":loot,"sieges":war.state.get("sieges",{}).values().filter(func(s):return int(s.get("started",0)) >= int(data.get("started_at",0)))}
