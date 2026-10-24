extends RefCounted

# Recruitment is an explicit task followed by a negotiated offer. Soldier
# recruitment remains in the existing city subsystem.
const Model = preload("res://scripts/characters/character_model.gd")
const JOBS := {"governor":"太守", "guard":"守将", "":"待任"}

static func state(war) -> Dictionary:
	if not war.state.has("talent_service"): war.state["talent_service"] = {"known":{}, "tasks":{}, "next_id":1}
	return war.state["talent_service"]

static func known(war, faction: String, id: String) -> bool:
	return state(war)["known"].get(faction, {}).has(id) or str(war.characters.states.get(id, {}).get("faction_id", "")) == faction

static func reveal(war, faction: String, id: String, source: String) -> void:
	var data := state(war)
	if not data["known"].has(faction): data["known"][faction] = {}
	if not data["known"][faction].has(id): data["known"][faction][id] = {"identified_at":int(war.state["tick"]), "source":source, "confirmed_attributes":{}}

static func investigate(war, actor: String, city: String) -> Dictionary:
	if war.store.busy or war.campaign_finished(): return {"ok":false, "message":"当前无法安排寻访"}
	if not war.player_has_city_access(city): return {"ok":false, "message":"请在本方城池安排寻访"}
	if not war.available_officers(str(war.state["player_faction"])).any(func(person): return str(person["id"]) == actor): return {"ok":false, "message":"寻访者正在任职或无法行动"}
	if war.store.action_points <= 0: return {"ok":false, "message":"本月行动力已用尽"}
	var old: Dictionary = war.state["officer_states"].get(actor, {}).duplicate(true)
	var origin := str(old.get("city", city))
	if war.is_besieged(city) or war.is_besieged(origin): return {"ok":false, "message":"围城期间不能安排人员寻访"}
	var travel: int = war.Operations.travel_days(war, origin, city)
	if travel < 0: return {"ok":false, "message":"没有可行的寻访路线"}
	var data := state(war)
	var id := "visit:%d" % int(data["next_id"])
	data["next_id"] += 1
	data["tasks"][id] = {"id":id, "actor":actor, "faction":str(war.state["player_faction"]), "city":city, "origin":origin, "arrival_tick":int(war.state["tick"]) + travel + 3, "return_days":travel, "prior_state":old, "phase":"searching"}
	war.state["officer_states"][actor] = {"status":"talent_task", "city":origin, "task_id":id}
	war.Operations.detach_post(war, actor)
	war.store.city_changed.emit(origin)
	war.store.action_points -= 1
	war.characters.record(actor, id + ":start", "talent_search", int(war.state["tick"]), {"destination":city, "arrival_tick":data["tasks"][id]["arrival_tick"]})
	war.store._save()
	return {"ok":true, "message":"寻访已安排，预计%d日后完成调查，之后返回原城" % (travel + 3)}

static func _local_candidate(war, city: String) -> String:
	var id := "talent:" + city
	if war.characters.states.has(id): return id
	# Explicit generated template, independent of historical biographies. These
	# neutral initial estimates are authored defaults, never inferred from names.
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("talent-template-v1:" + city) & 0x7FFFFFFF
	var attrs: Dictionary = {}
	var potential: Dictionary = {}
	for attribute in Model.keys():
		attrs[attribute] = rng.randi_range(35, 70)
		potential[attribute] = "B"
	var aptitudes: Dictionary = {}
	for troop in Model.TROOPS: aptitudes[troop] = "D"
	var terrains: Dictionary = {}
	for terrain in Model.TERRAINS: terrains[terrain] = "unfamiliar"
	var card := {"base_attributes":attrs, "potential_by_attribute":potential, "troop_aptitudes":aptitudes, "terrain_experience":terrains, "birth":{"year":int(war.store.year) - 25, "precision":"year"}, "design_revision":1}
	var officer := {"id":id, "name":war.graph.name_of(city) + "·地方人才", "faction":"", "skills":{}, "personality":{}, "battle_traits":[], "positions":"地方人才", "generated":true, "design_generated":true, "home":city, "portrait":"", "profile_note":"地区模板生成的非历史人物"}
	for index in Model.GROUPS.size():
		for col in Model.GROUPS[index].size(): officer["skills"][Model.LEGACY[index][col]] = attrs[Model.GROUPS[index][col]]
	for axis in war.roster.AXES: officer["personality"][axis] = 50
	war.roster.officers[id] = officer
	war.state["generated_officers"][id] = officer.duplicate(true)
	war.characters.definitions[id] = Model.definition(card, officer)
	war.characters.states[id] = Model.initial_state(war.characters.definitions[id], officer)
	war.characters.states[id]["availability"] = {"status":"wild", "city":city}
	war.state["officer_states"][id] = {"status":"wild", "city":city}
	return id

static func advance(war) -> void:
	var data := state(war)
	for id in data["tasks"]:
		var task: Dictionary = data["tasks"][id]
		if task["phase"] == "complete" or int(task["arrival_tick"]) > int(war.state["tick"]): continue
		var actor := str(task["actor"])
		var binding: Dictionary = war.state["officer_states"].get(actor, {})
		if binding.get("task_id", "") != id or war.Fate.unavailable(war, actor):
			task["phase"] = "complete"
			war.characters.record(actor, str(id) + ":interrupted", "talent_search_interrupted", int(war.state["tick"]))
			continue
		if task["phase"] == "searching":
			if war.store.city_state(str(task["city"])).get("faction", "") == task["faction"]:
				var discovered := _local_candidate(war, str(task["city"]))
				reveal(war, str(task["faction"]), discovered, str(id))
				war.characters.relation_event(discovered, actor, str(id), {"respect":4.0}, int(war.state["tick"]))
				war.characters.record(actor, str(id) + ":found", "talent_discovered", int(war.state["tick"]), {"target":discovered})
				war.Feedback.event(war, "寻访完成", "%s发现了%s，可在人才面板接洽。" % [war.roster.officers[actor]["name"], war.roster.officers[discovered]["name"]], str(task["faction"]))
				task["target"] = discovered
			task["phase"] = "returning"
			task["arrival_tick"] = int(war.state["tick"]) + int(task["return_days"])
		if task["phase"] == "returning" and int(task["arrival_tick"]) <= int(war.state["tick"]):
			war.state["officer_states"][actor] = task["prior_state"].duplicate(true)
			task["phase"] = "complete"
			war.Operations.residence(war)

static func offer(war, id: String, city: String, job: String = "", actor: String = "") -> Dictionary:
	var faction := str(war.state["player_faction"])
	if war.store.busy or war.campaign_finished(): return {"ok":false, "message":"当前无法接洽人才"}
	if not known(war, faction, id) or not war.characters.states.has(id): return {"ok":false, "message":"尚未发现此人"}
	var person: Dictionary = war.characters.states[id]
	if person["service_status"] != "wild": return {"ok":false, "message":"此人当前无法接受在野招募"}
	if job not in JOBS or not war.player_has_city_access(city): return {"ok":false, "message":"招募岗位或城池无效"}
	if war.is_besieged(city): return {"ok":false, "message":"围城期间无法接洽并任命人员"}
	if str(person["availability"].get("city", "")) != city: return {"ok":false, "message":"请在人才所在地接洽"}
	if job == "governor" and str(war.store.city_state(city).get("governor_id", "")) != "": return {"ok":false, "message":"太守岗位已有任职者"}
	if job == "guard" and not war.state["garrison_commanders"].get(city, {}).is_empty(): return {"ok":false, "message":"守将岗位已有任职者"}
	if not war.available_officers(faction).any(func(officer): return str(officer["id"]) == actor and str(war.state["officer_states"].get(actor, {}).get("city", "")) == city): return {"ok":false, "message":"需要一位本城可用人员接洽"}
	if war.store.action_points <= 0: return {"ok":false, "message":"本月行动力已用尽"}
	var relation: Dictionary = war.characters.relation(id, actor)
	# Transparent initial TaskProfile. Acceptance is a person decision, not a
	# random success roll; unknown preferences do not grant a high affinity.
	var fit: Dictionary = war.characters.job_fit(id, "governor" if job == "governor" else "commander")
	var match_score := float(fit["score"]) if fit["known"] else 0.5
	var score := 0.30 * match_score + 0.20 * 0.6 + 0.15 * 0.5 + 0.15 * (float(relation.get("trust", 50.0)) + float(relation.get("respect", 50.0))) / 200.0 + 0.10 * 0.5 + 0.10
	war.store.action_points -= 1
	var event_id := "offer:%s:%d:%d" % [id, int(war.state["tick"]), war.store.action_points]
	war.characters.record(id, event_id, "recruitment_offer", int(war.state["tick"]), {"city":city, "job":job, "actor":actor, "score":score, "accepted":score >= 0.55, "profile_version":1})
	if score < 0.55:
		war.store._save()
		return {"ok":false, "message":"对方暂未接受当前岗位条件，可改为待任或选择更匹配的岗位", "score":score}
	person["service_status"] = "serving"
	person["faction_id"] = faction
	war.roster.officers[id]["faction"] = faction
	war.state["generated_officers"][id] = war.roster.officers[id].duplicate(true)
	war.state["officer_states"][id] = {"status":"available", "city":city}
	war.Operations._appoint(war, id, city, job)
	person["promises"].append({"id":event_id, "kind":"initial_post", "city":city, "job":job, "status":"fulfilled", "tick":int(war.state["tick"])})
	war.characters.relation_event(id, actor, event_id + ":fulfilled", {"trust":4.0}, int(war.state["tick"]))
	war.characters.sync(war)
	war.store._save()
	return {"ok":true, "message":"人才已接受条件并到任：" + str(JOBS[job]), "score":score}
