extends RefCounted

# Personal duel rules. Army combat intentionally keeps Officer.skill().
static func parameters(war) -> Dictionary:
	return war.rules["duel"]["numeric"]

static func card(war, army: Dictionary) -> Dictionary:
	var roster = war.get("roster")
	return roster.officers.get(str(army.get("officer_id", army.get("id", ""))), army) if roster != null else army

static func skill(war, army: Dictionary, name: String) -> float:
	return clampf(float(card(war, army).get("skills", army.get("skills", {})).get(name, 50)), 0, float(parameters(war)["attribute_max"]))

static func max_hp(war, army: Dictionary) -> float:
	var p := parameters(war)
	return clampf(float(p["hp_base"]) + skill(war, army, "体魄") * float(p["hp_physique"]), float(p["hp_min"]), float(p["hp_max"]))

static func state(war, army: Dictionary) -> Dictionary:
	var log: Dictionary = war.state["duels"]
	var id := str(army.get("officer_id", army.get("id", "")))
	assert(not id.is_empty(), "Duel state requires a stable officer ID")
	var maximum := max_hp(war, army)
	if not log["officers"].has(id):
		var legacy := clampf(float(log.get("stamina", {}).get(id, 100)), 0, 100)
		log["officers"][id] = {"hp":maximum * legacy / 100.0, "max_hp":maximum, "fatigue":0.0, "last_duel_tick":-1, "last_recovery_tick":int(war.state.get("tick", 0))}
	var value: Dictionary = log["officers"][id]
	if not is_equal_approx(float(value["max_hp"]), maximum):
		value["hp"] = maximum * clampf(float(value["hp"]) / maxf(float(value["max_hp"]), 1), 0, 1)
		value["max_hp"] = maximum
	return value

static func profile(war, army: Dictionary, mode: String, fatigue: float) -> Dictionary:
	var p := parameters(war)
	var skills := {}
	for name in ["武艺", "膂力", "体魄", "骑术", "箭术", "沉着", "应变", "威仪"]:
		skills[name] = skill(war, army, name)
	var q := 0.0
	for name in p["weights"][mode]: q += float(skills[name]) * float(p["weights"][mode][name])
	var stats: Array = card(war, army).get("stats", army.get("stats", []))
	var fallback := stats.size() < 3
	var courage := q if fallback else clampf(float(stats[2]), 0, float(p["attribute_max"]))
	var personal: Dictionary = war.state.get("officer_states", {}).get(str(army.get("officer_id", "")), {})
	var injury := clampf(float(personal.get("injury", 0.0)), 0, 1) if personal.get("injury", 0.0) is float or personal.get("injury", 0.0) is int else float(p["injury_labels"].get(str(personal.get("injury", "")), 0.0))
	var k := clampf(1.0 - float(p["fatigue_penalty"]) * fatigue / 100.0 - float(p["injury_penalty"]) * injury, float(p["state_min"]), 1)
	var score := (float(p["main_weight"]) * courage + float(p["sub_weight"]) * q) * k
	var traits: Array = card(war, army).get("battle_traits", army.get("battle_traits", []))
	var modifiers := {"attack":1.0, "hit":1.0, "block":1.0, "counter":1.0}
	for name in p["traits"]:
		var rule: Dictionary = p["traits"][name]
		if name not in traits or (rule.has("mode") and rule["mode"] != mode): continue
		if rule.has("weapon") and rule["weapon"] != card(war, army).get("weapon_type", ""): continue
		modifiers[rule["effect"]] *= probability(float(rule["factor"]), p["trait_factor_bounds"])
	var attack := (score * float(p["attack"][0]) + float(skills["膂力"]) * float(p["attack"][1]) + float(skills["武艺"]) * float(p["attack"][2])) * float(modifiers["attack"])
	var defense := score * float(p["defense"][0]) + float(skills["武艺"]) * float(p["defense"][1]) + float(skills["体魄"]) * float(p["defense"][2])
	return {"courage":courage, "sub_score":q, "score":score, "state_factor":k, "main_stat_fallback":fallback, "skills":skills, "attack":attack, "defense":defense, "fatigue":fatigue, "injury":injury, "modifiers":modifiers}

static func initiative(profile: Dictionary, hp: float, maximum: float, mode: String, p: Dictionary) -> float:
	var s: Dictionary = profile["skills"]
	var w: Array = p["initiative_weights"]
	return (float(profile["score"]) * float(w[0]) + float(s["骑术" if mode == "mounted_melee" else "武艺"]) * float(w[1]) + float(s["应变"]) * float(w[2]) + float(s["沉着"]) * float(w[3])) * (float(p["initiative_hp_base"]) + float(p["initiative_hp_weight"]) * hp / maximum)

static func probability(value: float, bounds: Array) -> float:
	return clampf(value, float(bounds[0]), float(bounds[1]))

static func attack(rng: RandomNumberGenerator, profiles: Array, hp: Array, attacker: int, p: Dictionary, counter: bool = false) -> Dictionary:
	var defender := 1 - attacker
	var a: Dictionary = profiles[attacker]
	var b: Dictionary = profiles[defender]
	var s: Dictionary = a["skills"]
	var t: Dictionary = b["skills"]
	var hit_chance := probability((float(p["hit_base"]) + float(p["hit_attack"]) * (float(a["attack"]) - float(b["defense"])) + float(p["hit_skill"]) * (float(s["武艺"]) - float(t["武艺"])) + float(p["hit_calm"]) * (float(s["沉着"]) - float(t["沉着"]))) * float(a["modifiers"]["hit"]), p["hit_bounds"])
	var block_chance := probability((float(p["block_base"]) + float(p["block_skill"]) * (float(t["武艺"]) - float(s["武艺"])) + float(p["block_calm"]) * (float(t["沉着"]) - float(s["沉着"])) - float(p["block_strength"]) * (float(s["膂力"]) - float(t["膂力"]))) * float(b["modifiers"]["block"]), p["block_bounds"])
	var critical_chance := probability(float(p["critical_base"]) + float(p["critical_strength"]) * maxf(0, float(s["膂力"]) - float(t["膂力"])) + float(p["critical_skill"]) * maxf(0, float(s["武艺"]) - float(t["武艺"])), p["critical_bounds"])
	var hit := rng.randf() < hit_chance
	var blocked := hit and rng.randf() < block_chance
	var critical := hit and not blocked and rng.randf() < critical_chance
	var ratio := float(a["attack"]) / maxf(float(b["defense"]), float(p["defense_floor"]))
	var suppression := 1.0 + maxf(0, float(a["score"]) - float(b["score"])) / float(p["suppression_scale"])
	var resistance := probability(1.0 - float(p["resistance_physique"]) * (float(t["体魄"]) - float(p["resistance_base"])), p["resistance_bounds"])
	var noise := rng.randf_range(float(p["damage_noise"][0]), float(p["damage_noise"][1]))
	var base := float(p["damage_base"]) * pow(ratio, float(p["damage_exponent"])) * suppression * resistance * noise
	var raw := maxf(float(p["damage_min"]), base * (float(p["block_damage"]) if blocked else float(p["critical_damage"]) if critical else 1.0) * (float(p["counter_damage"]) if counter else 1.0)) if hit else 0.0
	var applied := minf(float(hp[defender]), raw)
	hp[defender] = maxf(0, float(hp[defender]) - applied)
	return {"type":"counter" if counter else "attack", "attacker":attacker, "defender":defender, "hit":hit, "blocked":blocked, "critical":critical, "raw_damage":raw, "applied_damage":applied, "hp_after":hp.duplicate(), "hit_chance":hit_chance, "block_chance":block_chance, "critical_chance":critical_chance, "inputs":[a.duplicate(true), b.duplicate(true)], "damage_parts":{"ratio":ratio, "suppression":suppression, "resistance":resistance, "noise":noise, "base":base}}

static func contest(war, a: Dictionary, b: Dictionary) -> Dictionary:
	var p := parameters(war)
	var mode := str(a.get("duel_mode", war.rules["duel"].get("mode", "mounted_melee")))
	if not p["weights"].has(mode): mode = "mounted_melee"
	var states := [state(war, a), state(war, b)]
	var hp := [float(states[0]["hp"]), float(states[1]["hp"])]
	var initial := hp.duplicate()
	var maximum := [float(states[0]["max_hp"]), float(states[1]["max_hp"])]
	var fatigue := [float(states[0]["fatigue"]), float(states[1]["fatigue"])]
	var initial_fatigue := fatigue.duplicate()
	var profiles := [profile(war, a, mode, fatigue[0]), profile(war, b, mode, fatigue[1])]
	var initial_profiles := profiles.duplicate(true)
	var seed_value: int = war.rng.randi()
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var rounds := []
	for index in range(int(p["max_rounds"])):
		if hp[0] <= 0 or hp[1] <= 0: break
		profiles = [profile(war, a, mode, fatigue[0]), profile(war, b, mode, fatigue[1])]
		var first_chance := probability(float(p["initiative_base"]) + float(p["initiative_difference"]) * (initiative(profiles[0], hp[0], maximum[0], mode, p) - initiative(profiles[1], hp[1], maximum[1], mode, p)), p["initiative_bounds"])
		var first := 0 if rng.randf() < first_chance else 1
		var events := []
		for actor in [first, 1 - first]:
			if hp[0] <= 0 or hp[1] <= 0: break
			var event := attack(rng, profiles, hp, actor, p)
			event["first"] = first
			events.append(event)
			add_fatigue(fatigue, profiles, actor, event, p)
			var defender: int = 1 - actor
			if p["counter_enabled"] and not event["hit"] and hp[0] > 0 and hp[1] > 0:
				var sa: Dictionary = profiles[actor]["skills"]
				var sb: Dictionary = profiles[defender]["skills"]
				var chance := probability((float(p["counter_base"]) + float(p["counter_skill"]) * (float(sb["武艺"]) - float(sa["武艺"])) + float(p["counter_adapt"]) * (float(sb["应变"]) - float(sa["应变"]))) * float(profiles[defender]["modifiers"]["counter"]), p["counter_bounds"])
				if rng.randf() < chance:
					var response := attack(rng, profiles, hp, defender, p, true)
					response["first"] = first
					response["counter_chance"] = chance
					events.append(response)
					add_fatigue(fatigue, profiles, defender, response, p)
		var damage := [0.0, 0.0]
		for event in events: damage[event["defender"]] += float(event["applied_damage"])
		rounds.append({"index":index + 1, "first":first, "first_chance":first_chance, "events":events, "hp_a":hp[0], "hp_b":hp[1], "damage_a":damage[0], "damage_b":damage[1], "fatigue":fatigue.duplicate(), "a":profiles[0]["score"], "b":profiles[1]["score"]})
	var winner := 0 if hp[1] <= 0 and hp[0] > 0 else 1 if hp[0] <= 0 and hp[1] > 0 else -1
	var result := "overwhelming" if winner >= 0 else "draw"
	var difference: float = hp[0] / maximum[0] - hp[1] / maximum[1]
	if winner < 0 and absf(difference) >= float(p["decision_ratio"]):
		winner = 0 if difference > 0 else 1
		result = "win"
	return {"rules_version":2, "mode":mode, "seed":str(seed_value), "result":result, "winner":winner, "rounds":rounds, "initial_hp":initial, "final_hp":hp, "max_hp":maximum, "profiles":initial_profiles, "initial_fatigue":initial_fatigue, "final_fatigue":fatigue, "settled":false, "presentation_pending":true, "presentation_confirmed":false, "presentation":war.rules["duel"]["presentation"].duplicate(true)}

static func add_fatigue(fatigue: Array, profiles: Array, actor: int, event: Dictionary, p: Dictionary) -> void:
	var cost := probability(float(p["fatigue_base"]) - float(p["fatigue_physique"]) * float(profiles[actor]["skills"]["体魄"]), p["fatigue_bounds"])
	fatigue[actor] = minf(100, float(fatigue[actor]) + cost * (1.0 + float(p["critical_fatigue"]) if event["critical"] else 1.0))

static func recover(war) -> void:
	var p := parameters(war)
	var log: Dictionary = war.state["duels"]
	var tick := int(war.state["tick"])
	for id in log["officers"]:
		var value: Dictionary = log["officers"][id]
		if int(value["last_recovery_tick"]) >= tick: continue
		# Always consume this day, including days spent marching or fighting.
		value["last_recovery_tick"] = tick
		var personal: Dictionary = war.state.get("officer_states", {}).get(id, {})
		if personal.get("status", "") in ["dead", "captured"] or war.state.get("officer_fates", {}).get(id, {}).get("status", "") in ["dead", "captured"]: continue
		if int(value["last_duel_tick"]) >= tick: continue
		var city := str(personal.get("city", ""))
		var resting: bool = not city.is_empty() and personal.get("status", "") in ["available", "recovering", "guarding"]
		for army in war.state.get("armies", {}).values():
			if army.get("status", "") == "ended": continue
			var corps: Dictionary = war.state.get("corps", {}).get(army.get("corps_id", ""), {})
			if army.get("officer_id", "") != id and id not in corps.get("members", []): continue
			city = str(army.get("location", {}).get("node", ""))
			resting = not city.is_empty() and str(army.get("location", {}).get("edge", "")).is_empty() and not army.has("tactical") and army.get("action", {}).get("type", "") in ["hold", "rest", "resupply"]
			if not resting: break
		var location: Dictionary = war.store.city_state(city) if not city.is_empty() else {}
		if not resting or location.is_empty() or location.get("faction", "") != card(war, {"officer_id":id}).get("faction", ""): continue
		var current := state(war, {"officer_id":id})
		current["hp"] = minf(float(current["max_hp"]), float(current["hp"]) + float(current["max_hp"]) * float(p["recovery_hp"]))
		current["fatigue"] = maxf(0, float(current["fatigue"]) - float(p["recovery_fatigue"]))
