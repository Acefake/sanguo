extends RefCounted
const Officer = preload("res://scripts/war/officer_battle.gd")
const Combat = preload("res://scripts/war/combat_system.gd")
const Fate = preload("res://scripts/war/officer_fate.gd")

static func config(war) -> Dictionary: return war.rules.get("duel", {})
static func journal(war) -> Dictionary:
	if not war.state.has("duels"): war.state["duels"] = {"pairs": {}, "counts": {}, "records": []}
	if not war.state["duels"].has("road_scopes"): war.state["duels"]["road_scopes"] = {}
	return war.state["duels"]
static func battle_key(war, a: Dictionary, b: Dictionary) -> String:
	if not war.state.get("battlefield",{}).is_empty(): return "field:" + str(war.state["battlefield"].get("battle_id", war.state["battlefield"].get("anchor",0)))
	var location_key := _location_key(a,b)
	# Pure read: eligible() is a predicate and must not advance the scope lifetime.
	# enter_scope() is the only writer, and only challenge() calls it.
	var scopes: Dictionary = journal(war)["road_scopes"]
	var tick: int = int(war.state["tick"])
	if scopes.has(location_key) and int(scopes[location_key]["last_tick"]) >= tick - 1:
		return str(scopes[location_key]["id"])
	return "road:%s:%d" % [location_key,tick]

static func _location_key(a: Dictionary, b: Dictionary) -> String:
	var locations := [str(a.get("location",{}).get("edge", "")),str(b.get("location",{}).get("edge", ""))]
	if locations[0] == "": locations[0] = a.get("location",{}).get("node",a.get("target",""))
	if locations[1] == "": locations[1] = b.get("location",{}).get("node",b.get("target",""))
	locations.sort()
	# Reinforcements and detachments on the same battle line share officer limits.
	return ":".join(locations)

# The single writer of road_scopes, so eligibility checks stay side-effect free.
static func enter_scope(war, a: Dictionary, b: Dictionary) -> void:
	var scopes: Dictionary = journal(war)["road_scopes"]
	var tick: int = int(war.state["tick"])
	var key := _location_key(a,b)
	if not scopes.has(key) or int(scopes[key]["last_tick"]) < tick - 1:
		scopes[key] = {"id":"road:%s:%d" % [key,tick],"last_tick":tick}
	else:
		scopes[key]["last_tick"] = tick
static func pair_key(war, a: Dictionary, b: Dictionary) -> String:
	var ids := [str(a["officer_id"]),str(b["officer_id"])]
	ids.sort()
	return battle_key(war,a,b)+":"+":".join(ids)
static func eligible(war, a: Dictionary, b: Dictionary) -> bool:
	if Fate.unavailable(war, str(a["officer_id"])) or Fate.unavailable(war, str(b["officer_id"])) or a.get("duel_wounded", false) or b.get("duel_wounded", false): return false
	if not config(war).get("enabled",true) or a["faction"] == b["faction"] or a.get("returning",false) or b.get("returning",false): return false
	if a.get("status", "active") == "ended" or b.get("status","active") == "ended": return false
	if a.get("action",{}).get("type","") not in ["engage","continue"] and b.get("action",{}).get("type","") not in ["engage","continue"]: return false
	if a.has("tactical") != b.has("tactical"): return false
	if not a.has("tactical") and not war._contact(a,b,{}): return false
	if war.Terrain.entry_factor(a,war.rules) <= 0 or war.Terrain.entry_factor(b,war.rules) <= 0: return false
	if a.has("tactical") and b.has("tactical") and war.Tactical.distance(a,b) != 1: return false
	if a.get("tactical",{}).get("phase","") == "远射" or b.get("tactical",{}).get("phase","") == "远射": return false
	if int(a.get("first_contact_effect_tick",-1)) == int(war.state["tick"]) or int(b.get("first_contact_effect_tick",-1)) == int(war.state["tick"]): return false
	var log := journal(war)
	var scope := battle_key(war,a,b)
	if log["pairs"].has(pair_key(war,a,b)): return false
	for army in [a,b]:
		var key := scope+":"+str(army["officer_id"])
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
	var health := [100.0, 100.0]
	var rounds := []
	var noise := float(config(war).get("round_noise",15))
	for round_index in range(30):
		var left: float = prowess(war,a,b)+war.rng.randf_range(-noise,noise)
		var right: float = prowess(war,b,a)+war.rng.randf_range(-noise,noise)
		var winner := -1 if absf(left-right) <= float(config(war).get("draw_margin",1)) else 0 if left > right else 1
		if winner >= 0:
			var gap := absf(left - right)
			var damage := clampf(4.0 + maxf(0.0, gap - 7.0) * 0.35 + war.rng.randf_range(0.4, 2.5), 4.5, 12.0)
			health[1 - winner] = maxf(0.0, health[1 - winner] - damage)
		rounds.append({"a":left,"b":right,"winner":winner,"hp_a":health[0],"hp_b":health[1]})
		if health[0] <= 0.0 or health[1] <= 0.0: break
	var winner := 0 if health[1] <= 0.0 else 1 if health[0] <= 0.0 else -1
	# A knockout is overwhelming; a duel that simply ran out of rounds is a plain win.
	# Without the margin test every decided duel routed the loser through the
	# overwhelming block (the loop breaks the instant either side hits 0), so
	# effects.win was unreachable and every loser took the 18%斩 / 27%俘 roll.
	var result := "draw"
	if winner >= 0:
		result = "overwhelming" if health[1 - winner] <= 0.0 else "win"
	elif absf(health[0] - health[1]) >= float(config(war).get("decision_margin", 15.0)):
		winner = 0 if health[0] > health[1] else 1
		result = "win"
	return {"result":result, "winner":winner,"rounds":rounds}
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
			outcome["fate"] = Fate.encounter(war, loser, winner, "duel", 1.0)
	if result == "refused": return
	for army in [a,b]:
		army["duel_tick"] = int(war.state["tick"])
		army["duel_opponent"] = b["id"] if army == a else a["id"]
static func challenge(war, a: Dictionary, b: Dictionary, force_initiation: bool = false) -> Dictionary:
	if not eligible(war,a,b): return {}
	if not force_initiation and war.rng.randf() >= initiation(war,a,b): return {}
	var log := journal(war)
	enter_scope(war,a,b)
	log["pairs"][pair_key(war,a,b)] = int(war.state["tick"])
	for army in [a,b]:
		var key := battle_key(war,a,b)+":"+str(army["officer_id"])
		log["counts"][key] = int(log["counts"].get(key,0))+1
	var outcome := contest(war,a,b) if war.rng.randf() < acceptance(war,b,a) else {"result":"refused","winner":-1,"rounds":[]}
	var left_id: String = str(a["officer_id"])
	var right_id: String = str(b["officer_id"])
	var left_name: String = str(a["name"])
	var right_name: String = str(b["name"])
	apply_result(war,a,b,outcome)
	var fate: Dictionary = outcome.get("fate", {})
	var message := "%s向%s挑战，%s。" % [left_name,right_name,"避战回营，双方军心受挫" if outcome["result"] == "refused" else "交锋三十回合仍未分胜负" if outcome["result"] == "draw" else "败将被斩杀" if fate.get("status", "") == "dead" else "败将被擒" if fate.get("status", "") == "captured" else "败将重伤，所部军心动摇"]
	if int(outcome["winner"]) >= 0: message += " 胜者：" + (left_name if int(outcome["winner"]) == 0 else right_name)
	outcome.merge({"tick":war.state["tick"],"a":left_id,"b":right_id,"message":message})
	log["records"].append(outcome)
	while log["records"].size() > int(config(war).get("max_records", war.rules["feedback"]["max_log"])): log["records"].pop_front()
	for army in [a,b]: war._report(army,"单挑",message,true)
	return outcome
