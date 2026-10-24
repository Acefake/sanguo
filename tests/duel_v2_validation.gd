extends SceneTree
const D = preload("res://scripts/war/duel_system.gd")
const N = preload("res://scripts/war/duel_rules_v2.gd")
const War = preload("res://scripts/war/campaign_state.gd")
const Role = preload("res://scripts/war/officer_role.gd")
const Card = preload("res://scripts/war/duel_map_card.gd")
var failures: Array[String] = []
var checks := 0
var summaries: Array = []

func _initialize() -> void: call_deferred("run")
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures.append(message)
		push_error(message)

func fighter(war, id: String, score: float) -> Dictionary:
	var skills := {}
	for name in ["武艺","膂力","体魄","骑术","箭术"]: skills[name] = score
	for name in ["沉着","应变","威仪"]: skills[name] = 70.0
	war.roster.officers[id] = {"id":id,"name":id,"stats":[50,50,score,50,50],"skills":skills,"positions":"核心位置：前锋","faction":"liu_bei","battle_traits":[]}
	war.state["generated_officers"][id] = war.roster.officers[id]
	return {"id":"army_"+id,"officer_id":id,"name":id,"skills":skills.duplicate(),"faction":"liu_bei","morale":80.0,"organization":80.0,"action":{"type":"hold"}}

func run() -> void:
	var store = root.get_node("GameState")
	store.persist_enabled = false
	store.agent.enabled = false
	store.prepare_battle_test(true)
	var war = store.war
	if "--edges-only" in OS.get_cmdline_user_args():
		edges(war,store)
		print("DUEL_V2_EDGES checks=%d failures=%d" % [checks,failures.size()])
		quit(0 if failures.is_empty() else 1)
		return
	for scores in [[90,90],[90,70],[105,70],[110,50]]:
		simulate(war, fighter(war,"left",scores[0]), fighter(war,"right",scores[1]), "%d/%d" % scores)
	var real: Array = []
	for name in ["关羽","颜良"]:
		for info in war.roster.officers.values():
			if info["name"] == name: real.append({"id":name,"officer_id":info["id"],"name":name,"skills":info["skills"],"faction":info["faction"]})
	check(real.size() == 2, "Real roster sample missing")
	if real.size() == 2: simulate(war,real[0],real[1],"关羽/颜良")
	var technical := fighter(war,"technical",90)
	var powerful := fighter(war,"powerful",90)
	war.roster.officers["technical"]["skills"]["武艺"] = 110.0
	war.roster.officers["technical"]["skills"]["膂力"] = 70.0
	war.roster.officers["powerful"]["skills"]["武艺"] = 70.0
	war.roster.officers["powerful"]["skills"]["膂力"] = 110.0
	simulate(war,technical,powerful,"技巧/力量")
	var durable := fighter(war,"durable",90)
	war.roster.officers["durable"]["skills"]["体魄"] = 120.0
	simulate(war,durable,fighter(war,"balanced",90),"耐战/均衡")
	var rider := fighter(war,"rider",90)
	war.roster.officers["rider"]["skills"]["骑术"] = 120.0
	simulate(war,rider,fighter(war,"balanced",90),"骑战/均衡")
	war.rules["duel"]["mode"] = "foot_melee"
	simulate(war,rider,fighter(war,"balanced",90),"步战骑术/均衡")
	war.rules["duel"]["mode"] = "mounted_melee"
	edges(war,store)
	var output := "res://docs/validation/duel-v2-2026-10-09"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output))
	var file := FileAccess.open(output+"/numeric-results.json",FileAccess.WRITE)
	file.store_string(JSON.stringify({"samples":summaries,"checks":checks,"failures":failures},"  "))
	print("DUEL_V2_OK checks=%d failures=%d" % [checks,failures.size()])
	quit(0 if failures.is_empty() else 1)

func simulate(war, a: Dictionary, b: Dictionary, label: String) -> void:
	var wins := [0,0]
	var draws := 0
	var first_round := 0
	var lengths: Array = []
	var remaining := 0.0
	var events_count := 0
	var blocks := 0
	var criticals := 0
	var counters := 0
	var fates := {"dead":0,"captured":0,"survived":0}
	var p: Dictionary = war.rules["officer_fate"]
	var fate_rng := RandomNumberGenerator.new()
	fate_rng.seed = 2409
	for sample in range(1000):
		war.state["duels"] = {"pairs":{},"counts":{},"records":[]}
		war.rng.seed = sample + 1
		var result := D.contest(war,a,b)
		lengths.append(result["rounds"].size())
		if result["winner"] < 0: draws += 1
		else:
			wins[result["winner"]] += 1
			remaining += float(result["final_hp"][result["winner"]]) / float(result["max_hp"][result["winner"]])
		if result["result"] == "overwhelming":
			var roll := fate_rng.randf()
			fates["dead" if roll < float(p["duel_death"]) else "captured" if roll < float(p["duel_death"])+float(p["duel_capture"]) else "survived"] += 1
		if result["rounds"].size() == 1 and result["result"] == "overwhelming": first_round += 1
		var hp: Array = result["initial_hp"].duplicate()
		for row in result["rounds"]:
			for event in row["events"]:
				check(hp[0] > 0 and hp[1] > 0,"Attack after knockout")
				var actor := int(event["attacker"])
				var target := 1-actor
				check(not event["blocked"] or (event["hit"] and not event["critical"]),"Contradictory block")
				check(event["hit"] or event["applied_damage"] == 0,"Dodge caused damage")
				check(is_equal_approx(float(hp[target])-float(event["applied_damage"]),float(event["hp_after"][target])) and event["hp_after"][actor] == hp[actor],"Damage ledger mismatch")
				check(float(event["raw_damage"]) >= float(event["applied_damage"]) and event["hp_after"][target] >= 0,"Invalid capped damage")
				hp = event["hp_after"].duplicate()
				events_count += 1
				if event["blocked"]: blocks += 1
				if event["critical"]: criticals += 1
				if event["type"] == "counter": counters += 1
		check(hp == result["final_hp"],"Final HP mismatch")
	lengths.sort()
	var row := {"pair":label,"samples":1000,"wins":wins,"draws":draws,"rounds_p10":lengths[100],"rounds_median":lengths[500],"rounds_p90":lengths[900],"first_round_knockout_rate":first_round/1000.0,"winner_hp_ratio":remaining/maxi(1,wins[0]+wins[1]),"block_rate":blocks/float(events_count),"critical_rate":criticals/float(events_count),"counters":counters,"fate_sampling":fates}
	summaries.append(row)
	print(JSON.stringify(row))
	if label == "90/90": check(wins[0]/float(maxi(1,wins[0]+wins[1])) >= .45 and wins[0]/float(maxi(1,wins[0]+wins[1])) <= .55,"Mirror matchup biased")
	if label == "110/50": check(first_round >= 900,"Extreme matchup first-round KO below 90%")

func edges(war,store) -> void:
	war.state["duels"] = {"pairs":{},"counts":{},"records":[],"stamina":{"migrate":64.0}}
	var a := fighter(war,"migrate",90)
	var b := fighter(war,"other",70)
	check(is_equal_approx(D.stamina(war,a),80.0),"64 percent legacy migration failed")
	var serialized: Dictionary = JSON.parse_string(JSON.stringify(war.state["duels"]))
	war.state["duels"] = serialized
	check(is_equal_approx(D.stamina(war,a),80.0),"Repeated migration altered HP")
	war.roster.officers[a["officer_id"]]["skills"]["体魄"] = 120
	check(is_equal_approx(D.stamina(war,a),89.6),"HP upgrade lost remaining ratio")
	war.roster.officers[a["officer_id"]]["skills"]["体魄"] = 90
	war.rng.seed = 18
	var result := D.contest(war,a,b)
	result["duel_id"] = "edge:1"
	war.rules["officer_fate"]["duel_death"] = 0.0
	war.rules["officer_fate"]["duel_capture"] = 0.0
	D.apply_result(war,a,b,result)
	var settled: Dictionary = war.state.duplicate(true)
	D.apply_result(war,a,b,result)
	check(war.state == settled,"Duplicate settlement mutated state")
	var replay: Dictionary = result.duplicate(true)
	replay["settled"] = false
	D.apply_result(war,a,b,replay)
	check(war.state == settled,"Duplicate duel ID settled twice")
	var next := D.contest(war,a,b)
	check(next["initial_hp"] == result["final_hp"] and next["initial_fatigue"] == result["final_fatigue"],"Consecutive duel reset status")
	var ui := Card.new()
	ui.configure(result)
	ui.elapsed = float(ui.timeline[0]["at"]) + .14
	check(is_equal_approx(ui.health_at(0,ui.playback()),float(result["initial_hp"][0])) and is_equal_approx(ui.health_at(1,ui.playback()),float(result["initial_hp"][1])),"UI deducted HP before impact")
	ui.elapsed = ui.result_at
	check(is_equal_approx(ui.health_at(0,ui.playback()),float(result["final_hp"][0])) and is_equal_approx(ui.health_at(1,ui.playback()),float(result["final_hp"][1])),"UI final HP diverged")
	ui.free()
	var state := N.state(war,a)
	state["hp"] = 20.0
	state["fatigue"] = 40.0
	var low := N.profile(war,a,"mounted_melee",0)
	var tired := N.profile(war,a,"mounted_melee",100)
	check(tired["score"] < low["score"],"Fatigue does not lower score")
	var before := float(state["hp"])
	war.state["officer_states"][a["officer_id"]] = {"status":"available","city":"xiaopei"}
	# Use a real friendly city, not an assumed place ID.
	for city in store.scenario["places"]:
		if store.city_state(city).get("faction", "") == "liu_bei": war.state["officer_states"][a["officer_id"]]["city"] = city; break
	war.state["tick"] += 1
	D.recover(war)
	check(state["hp"] > before and state["fatigue"] == 32,"Rest day did not recover status")
	var recovered := state.duplicate()
	D.recover(war)
	check(state == recovered,"Repeated recovery granted extra rest")
	war.state["officer_states"][a["officer_id"]]["status"] = "captured"
	war.state["tick"] += 1
	D.recover(war)
	check(state["hp"] == recovered["hp"],"Captured officer recovered")
	check(not D.can_initiate(war,a),"Captured officer allowed to duel")
	war.state["officer_states"][a["officer_id"]] = {"injury":"重伤"}
	check(not D.can_accept(war,a),"Severely injured officer accepted")
	war.state["officer_states"][a["officer_id"]] = {}
	var weak := fighter(war,"weak",50)
	check(not D.can_initiate(war,weak) and D.can_accept(war,weak),"Challenge and acceptance thresholds not split")
	war.roster.officers["weak"]["positions"] = "核心位置：军师\n不宜位置：前锋"
	check(not D.can_accept(war,weak),"Strategist accepted a duel")
	var strong :=  fighter(war,"super",120)
	check(N.profile(war,strong,"mounted_melee",0)["courage"] == 120 and N.skill(war,strong,"武艺") == 120,"Over-100 stat compressed")
	var foot := N.profile(war,strong,"foot_melee",0)
	war.roster.officers["super"]["skills"]["骑术"] = 0
	check(N.profile(war,strong,"foot_melee",0)["score"] == foot["score"],"Foot duel benefited from riding")
	var fallback := fighter(war,"fallback",65)
	war.roster.officers["fallback"].erase("stats")
	check(N.profile(war,fallback,"mounted_melee",0)["main_stat_fallback"],"Missing main stat not flagged")
	var healthy := fighter(war,"healthy",90)
	var base := N.profile(war,healthy,"mounted_melee",0)
	war.roster.officers["healthy"]["battle_traits"] = ["刀术"]
	check(N.profile(war,healthy,"mounted_melee",0)["attack"] == base["attack"],"Weapon trait inferred from portrait")
	war.roster.officers["healthy"]["weapon_type"] = "blade"
	check(N.profile(war,healthy,"mounted_melee",0)["attack"] > base["attack"],"Explicit weapon trait not applied")
	war.roster.officers["healthy"]["battle_traits"] = ["武圣"]
	check(N.skill(war,healthy,"武艺") == 90,"Permanent trait bonus counted twice")
	war.state["officer_states"]["healthy"] = {"injury":1}
	check(not D.can_accept(war,healthy),"Numeric severe injury accepted")
	war.state["officer_states"]["healthy"] = {"status":"dead"}
	check(not D.can_accept(war,healthy),"Dead officer accepted")
	war.state["officer_states"]["healthy"] = {}
	var guard_id: String = war.roster.militia("liu_bei","fixture")
	check(Role.can_accept(war,{"officer_id":guard_id}),"Generated low-score guard was classified as civil")
	# The explicit toggle must suppress a guaranteed death at the fate entrance.
	var real_a: Dictionary = war.active_armies("liu_bei")[0]
	var real_b: Dictionary = war.active_armies("yuan_shao")[0]
	war.rules["duel"]["allow_death"] = false
	war.rules["officer_fate"]["duel_death"] = 1.0
	war.rules["officer_fate"]["duel_capture"] = 0.0
	var disabled_fate: Dictionary = D.Fate.encounter(war,real_b,real_a,"duel",1)
	check(disabled_fate.is_empty(),"allow_death=false did not suppress death")
	war.rules["duel"]["allow_death"] = true
	war.rules["officer_fate"]["duel_death"] = .18
	# Export/reload of the actual campaign preserves pending settlement and personal state.
	war.state["duels"]["records"] = [result]
	var saved: Dictionary = war.export_state()
	var restored = War.new()
	restored.setup(store,saved)
	check(restored.state["duels"]["records"][0]["presentation_pending"],"Pending presentation lost on load")
	check(restored.state["duels"]["officers"] == war.state["duels"]["officers"],"Personal state lost on load")
