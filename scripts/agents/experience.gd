extends RefCounted

# Structured military experience: bounded notes about enemies, a short battle log
# and a bounded personality drift that only changes the *effective* personality
# used at decision time. Original character cards are never modified.

const Policy = preload("res://scripts/agents/baseline_policy.gd")
const LOSS_DRIFT := {"风险承受": -3.0, "自制": 3.0, "耐心": 2.0}
const WIN_DRIFT := {"风险承受": 3.0, "自制": -3.0, "决断": 2.0}


static func ensure(army: Dictionary) -> Dictionary:
	if not army.get("experience", null) is Dictionary:
		army["experience"] = {"enemy_notes": {}, "battle_log": [], "streak": {"wins": 0, "losses": 0}, "drift": {}}
	var experience: Dictionary = army["experience"]
	if not experience.get("enemy_notes", null) is Dictionary: experience["enemy_notes"] = {}
	if not experience.get("battle_log", null) is Array: experience["battle_log"] = []
	if not experience.get("streak", null) is Dictionary: experience["streak"] = {"wins": 0, "losses": 0}
	if not experience.get("drift", null) is Dictionary: experience["drift"] = {}
	return experience


static func settings() -> Dictionary:
	return Policy.weights().get("experience", {})


static func record_win(war, army: Dictionary, enemy_id: String, cause: String) -> void:
	war.characters.record(str(army.get("officer_id", "")), "battle:%s:%d:win" % [army["id"], int(war.state["tick"])], "battle_result", int(war.state["tick"]), {"army_id":army["id"], "result":"win", "cause":cause})
	var experience := ensure(army)
	var limits := settings()
	experience["streak"]["wins"] = int(experience["streak"].get("wins", 0)) + 1
	experience["streak"]["losses"] = 0
	_log(experience, war, "win", cause)
	_apply_drift(experience, WIN_DRIFT)
	if enemy_id != "": _note(experience, war, enemy_id, false, limits)


static func record_loss(war, army: Dictionary, enemy_id: String, cause: String) -> void:
	war.characters.record(str(army.get("officer_id", "")), "battle:%s:%d:loss" % [army["id"], int(war.state["tick"])], "battle_result", int(war.state["tick"]), {"army_id":army["id"], "result":"loss", "cause":cause})
	var experience := ensure(army)
	var limits := settings()
	experience["streak"]["losses"] = int(experience["streak"].get("losses", 0)) + 1
	experience["streak"]["wins"] = 0
	_log(experience, war, "loss", cause)
	_apply_drift(experience, LOSS_DRIFT)
	if enemy_id != "": _note(experience, war, enemy_id, true, limits)


static func _note(experience: Dictionary, war, enemy_id: String, beat_us: bool, limits: Dictionary) -> void:
	var notes: Dictionary = experience["enemy_notes"]
	var note: Dictionary = notes.get(enemy_id, {"tendency": "", "last_seen": 0, "beat_us": false})
	note["last_seen"] = int(war.state.get("tick", 0))
	if beat_us: note["beat_us"] = true
	notes[enemy_id] = note
	var cap := int(limits.get("enemy_notes", 6))
	while notes.size() > cap:
		var oldest := ""
		var oldest_seen := 1 << 30
		for id in notes:
			if int(notes[id].get("last_seen", 0)) < oldest_seen: oldest_seen = int(notes[id].get("last_seen", 0)); oldest = str(id)
		if oldest == "": break
		notes.erase(oldest)


static func _log(experience: Dictionary, war, result: String, cause: String) -> void:
	experience["battle_log"].append({"tick": int(war.state.get("tick", 0)), "result": result, "cause": cause})
	var cap := int(settings().get("battle_log", 10))
	while experience["battle_log"].size() > cap: experience["battle_log"].pop_front()


static func _apply_drift(experience: Dictionary, table: Dictionary) -> void:
	var limits := settings()
	if not bool(limits.get("drift_enabled", false)): return
	var cap := float(limits.get("drift_cap", 12))
	var drift: Dictionary = experience["drift"]
	for axis in table:
		drift[axis] = clampf(float(drift.get(axis, 0)) + float(table[axis]), -cap, cap)


static func decay(war) -> void:
	var limits := settings()
	var rate := float(limits.get("decay_per_day", 0.15))
	for army in war.state.get("armies", {}).values():
		if army.has("battle_ai"):
			var notes: Array = army["battle_ai"].get("memory",[])
			while not notes.is_empty() and int(war.state["battle_round"])-int(notes[0]["round"]) > 20: notes.pop_front()
		if not army.get("experience", null) is Dictionary: continue
		var drift: Dictionary = army["experience"].get("drift", {})
		for axis in drift.keys():
			var next := move_toward(float(drift[axis]), 0.0, rate)
			if is_zero_approx(next): drift.erase(axis)
			else: drift[axis] = next


static func summary(army: Dictionary) -> Dictionary:
	var experience := ensure(army)
	var recent: Array = experience["battle_log"].slice(maxi(0, experience["battle_log"].size() - 3))
	return {"drift": experience["drift"].duplicate(), "enemy_notes": experience["enemy_notes"].duplicate(true), "streak": experience["streak"].duplicate(), "recent": recent}

static func tactical_result(war, army: Dictionary) -> void:
	if not army.has("battle_ai") or not army.has("tactical"): return
	var ai: Dictionary = army["battle_ai"]
	var entries: Array = ai.get("memory",[])
	var event := "blocked" if army["tactical"].get("blocked",false) else "under_pressure" if int(army.get("last_enemy_tick",-100)) == int(war.state["tick"]) else ""
	if not event.is_empty():
		var note := {"round":war.state["battle_round"],"event":event,"target":army.get("last_enemy_id",""),"template":ai.get("plan",{}).get("template",""),"source":"personal_experience","army_id":army["id"]}
		entries.append(note)
		var agent := preload("res://scripts/agents/officer_brain.gd").ensure(war,str(army["officer_id"]))
		agent["memory"].append(note.duplicate(true))
		while agent["memory"].size() > 6: agent["memory"].pop_front()
	while entries.size() > 10: entries.pop_front()
	ai["memory"] = entries
