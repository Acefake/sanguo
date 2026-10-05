extends RefCounted
const Officer = preload("res://scripts/war/officer_battle.gd")
const Combat = preload("res://scripts/war/combat_system.gd")

static func config(war) -> Dictionary: return war.rules.get("duel", {})
static func journal(war) -> Dictionary:
	if not war.state.has("duels"): war.state["duels"] = {"pairs": {}, "counts": {}, "records": []}
	if not war.state["duels"].has("road_scopes"): war.state["duels"]["road_scopes"] = {}
	return war.state["duels"]
static func battle_key(war, a: Dictionary, b: Dictionary) -> String:
	if not war.state.get("battlefield",{}).is_empty(): return "field:" + str(war.state["battlefield"].get("battle_id", war.state["battlefield"].get("anchor",0)))
	var locations := [str(a.get("location",{}).get("edge", "")),str(b.get("location",{}).get("edge", ""))]
	if locations[0] == "": locations[0] = a.get("location",{}).get("node",a.get("target",""))
	if locations[1] == "": locations[1] = b.get("location",{}).get("node",b.get("target",""))
	locations.sort()
	# Reinforcements and detachments on the same battle line share officer limits.
	var location_key := ":".join(locations)
	var scopes: Dictionary = journal(war)["road_scopes"]
	var tick: int = war.state["tick"]
	if not scopes.has(location_key) or int(scopes[location_key]["last_tick"]) < tick - 1:
		scopes[location_key] = {"id":"road:%s:%d" % [location_key,tick],"last_tick":tick}
	scopes[location_key]["last_tick"] = tick
	return scopes[location_key]["id"]
static func pair_key(war, a: Dictionary, b: Dictionary) -> String:
	var ids := [str(a["officer_id"]),str(b["officer_id"])]
	ids.sort()
	return battle_key(war,a,b)+":"+":".join(ids)
static func eligible(war, a: Dictionary, b: Dictionary) -> bool:
	if not config(war).get("enabled",true) or a["faction"] == b["faction"] or a.get("returning",false) or b.get("returning",false) or a.get("formation_locked",false) or b.get("formation_locked",false): return false
	if a.get("status", "active") == "ended" or b.get("status","active") == "ended": return false
	if a.get("action",{}).get("type","") not in ["engage","continue"] and b.get("action",{}).get("type","") not in ["engage","continue"]: return false
	if a.has("tactical") != b.has("tactical"): return false
	if not a.has("tactical") and not war._contact(a,b,{}): return false
	if war.Terrain.entry_factor(a,war.rules) <= 0 or war.Terrain.entry_factor(b,war.rules) <= 0: return false
	if a.has("tactical") and b.has("tactical") and war.Tactical.distance(a,b) != 1: return false
	if a.get("tactical",{}).get("phase","") == "远射" or b.get("tactical",{}).get("phase","") == "远射": return false
	if int(a.get("first_contact_effect_tick",-1)) == int(war.state["tick"]) or int(b.get("first_contact_effect_tick",-1)) == int(war.state["tick"]): return false
	var log := journal(war)
	if log["pairs"].has(pair_key(war,a,b)): return false
	for army in [a,b]:
		var key := battle_key(war,a,b)+":"+str(army["officer_id"])
		if int(log["counts"].get(key,0)) >= int(config(war).get("officer_battle_limit",2)): return false
	return true
static func personality(war, army: Dictionary) -> Dictionary:
	return war.roster.officers.get(army["officer_id"],{}).get("personality",{})
static func initiation(war, a: Dictionary, b: Dictionary) -> float:
	var c := config(war)
	var ratio := Combat.power(a,war.rules,"plains")/maxf(Combat.power(b,war.rules,"plains"),1)
	var chance := float(c.get("initiation",0.12)) * float(c.get("initiative_disadvantage",1.5) if ratio < float(c.get("disadvantage_ratio",0.8)) else c.get("initiative_advantage",0.8) if ratio > 1 else 1)
	var p := personality(war,a)
	for row in [["风险承受","risk"],["自尊","pride"],["自制","control"],["耐心","patience"]]:
		if float(p.get(row[0],50)) >= float(c.get("personality_threshold",70)): chance *= float(c[row[1]])
	if Officer.skill(b,"名望") - Officer.skill(a,"名望") >= float(c.get("renown_gap",20)): chance *= float(c.get("renown_penalty",0.3))
	return clampf(chance,0,1)
static func acceptance(war, defender: Dictionary, challenger: Dictionary) -> float:
	var c := config(war)
	var chance := float(c.get("acceptance",0.55))
	var p := personality(war,defender)
	for row in [["忠义","accept_loyalty"],["自尊","accept_pride"],["自制","accept_control"]]:
		if float(p.get(row[0],50)) >= float(c.get("personality_threshold",70)): chance *= float(c[row[1]])
	if Combat.power(defender,war.rules,"plains") / maxf(Combat.power(challenger,war.rules,"plains"),1) < float(c.get("disadvantage_ratio",0.8)): chance *= float(c.get("accept_disadvantage",0.8))
	return clampf(chance,0,1)
static func prowess(war, a: Dictionary, b: Dictionary) -> float:
	var c := config(war)
	var value := 0.0
	for name in ["武艺","膂力","体魄"]: value += Officer.skill(a,name)*float(c["weights"][name])
	if int(a.get("units",{}).get("cavalry",0)) > 0: value += Officer.skill(a,"骑术")*float(c["weights"]["骑术"])
	var aura := clampf((Officer.skill(a,"威仪")-Officer.skill(b,"威仪"))/float(c.get("aura_scale",100)), -1,1)
	return value*(1+aura*float(c.get("aura_percent",0.05)))
static func contest(war, a: Dictionary, b: Dictionary) -> Dictionary:
	var wins := [0,0]
	var rounds := []
	var noise := float(config(war).get("round_noise",15))
	for round_index in range(3):
		var left: float = prowess(war,a,b)+war.rng.randf_range(-noise,noise)
		var right: float = prowess(war,b,a)+war.rng.randf_range(-noise,noise)
		var winner := -1 if absf(left-right) <= float(config(war).get("draw_margin",1)) else 0 if left > right else 1
		if winner >= 0: wins[winner] += 1
		rounds.append({"a":left,"b":right,"winner":winner})
		if wins[0] == 2 or wins[1] == 2: break
	var winner := -1 if wins[0] == wins[1] else 0 if wins[0] > wins[1] else 1
	var overwhelming: bool = winner >= 0 and wins[winner] == 2 and wins[1-winner] == 0
	return {"result":"draw" if winner < 0 else "overwhelming" if overwhelming else "win", "winner":winner,"rounds":rounds}
static func apply_result(war, a: Dictionary, b: Dictionary, outcome: Dictionary) -> void:
	var result: String = outcome["result"]
	var effect: Dictionary = config(war)["effects"][result]
	if result == "refused":
		a["morale"] = maxf(0,float(a["morale"])-float(effect["challenger_morale"]))
		b["morale"] = maxf(0,float(b["morale"])-float(effect["defender_morale"]))
	elif result == "draw":
		for army in [a,b]: army["morale"] = clampf(float(army["morale"])+war.rng.randf_range(-float(effect["morale"]),float(effect["morale"])),0,100)
	else:
		var winner: Dictionary = a if int(outcome["winner"]) == 0 else b
		var loser: Dictionary = b if int(outcome["winner"]) == 0 else a
		loser["morale"] = maxf(0,float(loser["morale"])-float(effect["loser_morale"]))
		loser["organization"] = maxf(0,float(loser["organization"])-float(effect["loser_org"]))
		winner["morale"] = minf(100,float(winner["morale"])+float(effect["winner_morale"]))
		if result == "overwhelming":
			loser["duel_wounded"] = true
			war.state["officer_states"].get(loser["officer_id"],{})["duel_wounded"] = true
	if result == "refused": return
	for army in [a,b]:
		army["duel_tick"] = int(war.state["tick"])
		army["duel_opponent"] = b["id"] if army == a else a["id"]
static func challenge(war, a: Dictionary, b: Dictionary, force_initiation: bool = false) -> Dictionary:
	if not eligible(war,a,b): return {}
	if not force_initiation and war.rng.randf() >= initiation(war,a,b): return {}
	var log := journal(war)
	log["pairs"][pair_key(war,a,b)] = int(war.state["tick"])
	for army in [a,b]:
		var key := battle_key(war,a,b)+":"+str(army["officer_id"])
		log["counts"][key] = int(log["counts"].get(key,0))+1
	var outcome := contest(war,a,b) if war.rng.randf() < acceptance(war,b,a) else {"result":"refused","winner":-1,"rounds":[]}
	apply_result(war,a,b,outcome)
	var message := "%s向%s挑战，%s。" % [a["name"],b["name"],"避战回营，双方军心受挫" if outcome["result"] == "refused" else "鏖战不分胜负" if outcome["result"] == "draw" else "胜者击落对手（负伤，带伤指挥）" if outcome["result"] == "overwhelming" else "胜者技高一筹，败者回阵"]
	if int(outcome["winner"]) >= 0: message += " 胜者：" + str(a["name"] if int(outcome["winner"]) == 0 else b["name"])
	outcome.merge({"tick":war.state["tick"],"a":a["officer_id"],"b":b["officer_id"],"message":message})
	log["records"].append(outcome)
	while log["records"].size() > int(war.rules["feedback"]["max_log"]): log["records"].pop_front()
	for army in [a,b]: war._report(army,"单挑",message,true)
	return outcome
