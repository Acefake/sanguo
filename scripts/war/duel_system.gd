extends RefCounted
const Officer = preload("res://scripts/war/officer_battle.gd")
const Combat = preload("res://scripts/war/combat_system.gd")
const Fate = preload("res://scripts/war/officer_fate.gd")
const Numeric = preload("res://scripts/war/duel_rules_v2.gd")
const Role = preload("res://scripts/war/officer_role.gd")

static func config(war) -> Dictionary: return war.rules.get("duel", {})
static func journal(war) -> Dictionary:
	if not war.state.has("duels"): war.state["duels"] = {"pairs": {}, "counts": {}, "records": []}
	if not war.state["duels"].has("road_scopes"): war.state["duels"]["road_scopes"] = {}
	if not war.state["duels"].has("stamina"): war.state["duels"]["stamina"] = {}
	var log: Dictionary = war.state["duels"]
	if not log.has("officers"): log["officers"] = {}
	log["version"] = 2
	if not log.has("settlements"): log["settlements"] = {}
	return log
static func stamina(war, army: Dictionary) -> float:
	journal(war)
	return float(Numeric.state(war, army)["hp"])

static func can_initiate(war, army: Dictionary) -> bool:
	return _healthy(war, army) and Role.can_initiate(war, army)

static func can_accept(war, army: Dictionary) -> bool:
	return _healthy(war, army) and Role.can_accept(war, army)

static func _healthy(war, army: Dictionary) -> bool:
	var id := str(army.get("officer_id", ""))
	var personal: Dictionary = war.state.get("officer_states", {}).get(id, {})
	var injury: Variant = personal.get("injury", 0)
	if str(injury) == "重伤" or ((injury is float or injury is int) and float(injury) >= 1.0): return false
	return not id.is_empty() and not Fate.unavailable(war, id) and not army.get("duel_wounded", false) and not personal.get("duel_wounded", false) and personal.get("status", "") not in ["recovering", "dead", "captured"] and stamina(war, army) > 0

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
# 触发条件（顺序即判定顺序，任一不满足即不可单挑）：
#   1. 双方都可战：未阵亡／被俘、未负伤、不同阵营、未在撤退。
#   2. 战场内双方允许近战接敌，动作与近战伤害一致；行军接敌至少一方主动接战。
#   3. 接战判定一致：同为战场格（tactical）或同为行军接敌，且确实相邻接触。
#   4. 地形允许进入；战场格距离为 1；不处于“远射”阶段。
#   5. 本次战斗双方尚未单挑，且每人单挑次数未达上限。
#   6. 角色资格：只有前锋／猛将／守备类角色可单挑，军师与主帅不亲自单挑（见 officer_role.gd）。
#      —— 诸葛亮（武力 48、定位“核心位置：主帅、军师／不宜位置：前锋”）在此被排除。
static func eligible(war, a: Dictionary, b: Dictionary) -> bool:
	if stamina(war, a) <= 0 or stamina(war, b) <= 0: return false
	if Fate.unavailable(war, str(a["officer_id"])) or Fate.unavailable(war, str(b["officer_id"])) or a.get("duel_wounded", false) or b.get("duel_wounded", false): return false
	if not config(war).get("enabled",true) or a["faction"] == b["faction"] or a.get("returning",false) or b.get("returning",false): return false
	if not can_initiate(war, a) or not can_accept(war, b): return false
	if a.get("status", "active") == "ended" or b.get("status","active") == "ended": return false
	if a.has("tactical") != b.has("tactical"): return false
	if a.has("tactical"):
		if not war.Tactical.can_engage(war, a) or not war.Tactical.can_engage(war, b): return false
	elif a.get("action",{}).get("type","") not in ["engage","continue"] and b.get("action",{}).get("type","") not in ["engage","continue"]: return false
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
	var ratio := prowess(war,a,b)/maxf(prowess(war,b,a),1)
	# 角色主导：前锋／猛将更愿意挑起单挑，主帅／军师（若规则放开）远低于基准。
	var role_factor := Role.duel_weight(war,a) / maxf(Role.duel_weight(war,b), 0.01)
	var chance := float(c.get("initiation",0.12)) * float(c.get("initiative_disadvantage",1.5) if ratio < float(c.get("disadvantage_ratio",0.8)) else c.get("initiative_advantage",0.8) if ratio > 1 else 1)
	var p := personality(war,a)
	for row in [["风险承受","risk"],["自尊","pride"],["自制","control"],["耐心","patience"]]:
		if float(p.get(row[0],50)) >= float(c.get("personality_threshold",70)): chance *= float(c[row[1]])
	if Officer.skill(b,"名望") - Officer.skill(a,"名望") >= float(c.get("renown_gap",20)): chance *= float(c.get("renown_penalty",0.3))
	chance *= role_factor
	return clampf(chance,0,1)
static func acceptance(war, defender: Dictionary, challenger: Dictionary) -> float:
	var c := config(war)
	var chance := float(c.get("acceptance",0.55))
	# 应战同样受角色主导：前锋更愿意接战，主帅／军师倾向避战。
	chance *= Role.duel_weight(war,defender) / maxf(Role.duel_weight(war,challenger), 0.01)
	var p := personality(war,defender)
	for row in [["忠义","accept_loyalty"],["自尊","accept_pride"],["自制","accept_control"]]:
		if float(p.get(row[0],50)) >= float(c.get("personality_threshold",70)): chance *= float(c[row[1]])
	if prowess(war,defender,challenger) / maxf(prowess(war,challenger,defender),1) < float(c.get("disadvantage_ratio",0.8)): chance *= float(c.get("accept_disadvantage",0.8))
	return clampf(chance,0,1)
static func prowess(war, a: Dictionary, _b: Dictionary) -> float:
	journal(war)
	return float(Numeric.profile(war, a, str(a.get("duel_mode", config(war).get("mode", "mounted_melee"))), float(Numeric.state(war, a)["fatigue"]))["score"])

static func contest(war, a: Dictionary, b: Dictionary) -> Dictionary:
	journal(war)
	return Numeric.contest(war, a, b)

static func recover(war) -> void:
	journal(war)
	Numeric.recover(war)

static func apply_result(war, a: Dictionary, b: Dictionary, outcome: Dictionary) -> void:
	var log := journal(war)
	var duel_id := str(outcome.get("duel_id", ""))
	if outcome.get("settled", false) or (not duel_id.is_empty() and log["settlements"].has(duel_id)): return
	if outcome.has("final_hp"):
		for index in range(2):
			var army: Dictionary = [a, b][index]
			var value := Numeric.state(war, army)
			value["hp"] = clampf(float(outcome["final_hp"][index]), 0, float(value["max_hp"]))
			value["fatigue"] = float(outcome.get("final_fatigue", [value["fatigue"], value["fatigue"]])[index])
			value["last_duel_tick"] = int(war.state["tick"])
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
			var id := str(loser["officer_id"])
			if not war.state["officer_states"].has(id): war.state["officer_states"][id] = {}
			war.state["officer_states"][id]["duel_wounded"] = true
			outcome["fate"] = Fate.encounter(war, loser, winner, "duel", 1.0)
	outcome["settled"] = true
	outcome["presentation_pending"] = true
	outcome["presentation_confirmed"] = false
	if not duel_id.is_empty(): log["settlements"][duel_id] = true
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
	outcome["duel_id"] = "%s:%d:%s:%s:%d" % [battle_key(war,a,b), int(war.state["tick"]), left_id, right_id, int(log.get("sequence", 0))]
	log["sequence"] = int(log.get("sequence", 0)) + 1
	outcome["factions"] = [a["faction"], b["faction"]]
	apply_result(war,a,b,outcome)
	var fate: Dictionary = outcome.get("fate", {})
	var message := "%s向%s挑战，%s。" % [left_name,right_name,"避战回营，双方军心受挫" if outcome["result"] == "refused" else "交锋%d回合仍未分胜负" % outcome["rounds"].size() if outcome["result"] == "draw" else "败将被斩杀" if fate.get("status", "") == "dead" else "败将被擒" if fate.get("status", "") == "captured" else "败将重伤，所部军心动摇" if outcome["result"] == "overwhelming" else "对手退让，所部军心动摇"]
	if int(outcome["winner"]) >= 0: message += " 胜者：" + (left_name if int(outcome["winner"]) == 0 else right_name)
	outcome.merge({"tick":war.state["tick"],"a":left_id,"b":right_id,"message":message})
	log["records"].append(outcome)
	while log["records"].size() > int(config(war).get("max_records", war.rules["feedback"]["max_log"])):
		var removable := -1
		for index in range(log["records"].size()):
			if not log["records"][index].get("presentation_pending", false):
				removable = index
				break
		if removable < 0: break
		log["records"].remove_at(removable)
	for army in [a,b]: war._report(army,"单挑",message,true)
	return outcome
