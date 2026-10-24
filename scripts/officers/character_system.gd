extends RefCounted

const Model = preload("res://scripts/officers/character_model.gd")
const POTENTIAL := {"S":1.30, "A":1.0, "B":0.75, "C":0.50}
const RELATION_AXES := ["trust", "gratitude", "respect", "interest", "resentment"]
const JOBS := {"commander":{"统兵":0.4, "料敌":0.2, "沉着":0.2, "应变":0.2}, "strategist":{"料敌":0.4, "智计":0.4, "辩论":0.2}, "vanguard":{"机动":0.3, "奇袭":0.3, "统兵":0.2, "沉着":0.2}, "deputy":{"统兵":0.3, "治军":0.3, "机动":0.2, "应变":0.2}, "governor":{"农桑":0.2, "财赋":0.2, "吏治":0.2, "法度":0.2, "仁德":0.2}, "diplomat":{"外交":0.5, "辩论":0.25, "信义":0.25}}
const LEGACY_STATUS := {"dead":"dead", "captured":"prisoner", "available":"serving", "recovering":"serving", "deployed":"serving", "guarding":"serving", "commanding":"serving", "transferring":"serving"}
var definitions: Dictionary = {}
var states: Dictionary = {}
var relations: Dictionary = {}
var migration_audit: Array = []

func setup(war, saved: Dictionary = {}) -> void:
	definitions.clear()
	states = saved.get("states", {}).duplicate(true)
	relations = saved.get("relations", {}).duplicate(true)
	migration_audit = saved.get("migration_audit", []).duplicate(true)
	var cards: Dictionary = {}
	for card in OfficerRepository.cards(): cards[str(card["id"])] = card
	for id in war.roster.officers:
		var officer: Dictionary = war.roster.officers[id]
		var def: Dictionary = Model.definition(cards.get(id, {}), officer)
		# A save freezes its initial definition. Content revisions cannot silently
		# overwrite the attributes on which that campaign's growth was based.
		if saved.get("definitions", {}).has(id): def = saved["definitions"][id].duplicate(true)
		definitions[id] = def
		if not states.has(id):
			states[id] = Model.initial_state(def, officer)
			migration_audit.append({"character_id":id, "version":Model.VERSION, "requires_review":def["calibration_required"].duplicate(), "missing_configuration":Model.validate(def)})
	# People adopted from outside the roster (adopt) keep their frozen definition too.
	for id in saved.get("definitions", {}):
		if not definitions.has(id) and states.has(id): definitions[id] = saved["definitions"][id].duplicate(true)
	sync(war)
	# Keep tactical memories on their original army, and archive them by person
	# exactly once. Migration is not a source of experience points.
	for army in war.state.get("armies", {}).values():
		var id := str(army.get("officer_id", ""))
		if states.has(id) and not army.get("experience", {}).is_empty():
			record(id, "legacy_army:" + str(army["id"]), "legacy_experience", int(war.state["tick"]), {"army_id":army["id"], "snapshot":army["experience"].duplicate(true)})

func ensure(officer: Dictionary) -> void:
	var id := str(officer["id"])
	if definitions.has(id): return
	definitions[id] = Model.definition({}, officer)
	states[id] = Model.initial_state(definitions[id], officer)

# Adopts a person who is not on the war roster (a people-pack character). An id
# already known keeps its definition and state; returns whether it was added.
func adopt(def: Dictionary, officer: Dictionary) -> bool:
	var id := str(def.get("character_id", ""))
	if id.is_empty() or definitions.has(id): return false
	definitions[id] = def.duplicate(true)
	if not states.has(id): states[id] = Model.initial_state(definitions[id], officer)
	return true

func sync(war) -> void:
	for id in war.roster.officers:
		ensure(war.roster.officers[id])
		var state: Dictionary = states[id]
		var availability: Dictionary = war.state.get("officer_states", {}).get(id, {}).duplicate(true)
		state["availability"] = availability
		var old_status := str(state["service_status"])
		var legacy := str(availability.get("status", ""))
		if legacy in ["dead", "captured"]: state["service_status"] = LEGACY_STATUS[legacy]
		elif old_status == "prisoner" and legacy == "recovering": state["service_status"] = "serving"
		if old_status != str(state["service_status"]): record(str(id), "status:%s:%d:%s" % [id, int(war.state["tick"]), state["service_status"]], "service_transition", int(war.state["tick"]), {"before":old_status, "after":state["service_status"], "cause":availability.get("cause", legacy)})
		# During the compatibility phase service changes explicitly update roster.
		war.roster.officers[id]["faction"] = str(state["faction_id"])

func export_state() -> Dictionary:
	return {"schema_version":Model.VERSION, "definitions":definitions.duplicate(true), "states":states.duplicate(true), "relations":relations.duplicate(true), "migration_audit":migration_audit.duplicate(true)}

func view(id: String) -> Dictionary:
	if not definitions.has(id) or not states.has(id): return {}
	return Model.view(definitions[id], states[id])

func record(id: String, event_id: String, kind: String, tick: int, detail: Dictionary = {}) -> bool:
	if not states.has(id) or event_id.is_empty(): return false
	var state: Dictionary = states[id]
	if state["event_keys"].has(event_id): return false
	state["event_keys"][event_id] = true
	state["events"].append({"event_id":event_id, "kind":kind, "tick":tick, "detail":detail.duplicate(true)})
	return true

func relation(from_id: String, to_id: String) -> Dictionary:
	return relations.get(from_id, {}).get(to_id, {}).duplicate(true)

func relation_event(from_id: String, to_id: String, event_id: String, changes: Dictionary, tick: int, confidence: float = 1.0, witnessed: bool = true) -> bool:
	if not states.has(from_id) or not states.has(to_id) or from_id == to_id or event_id.is_empty(): return false
	for axis in changes:
		if axis not in RELATION_AXES or typeof(changes[axis]) not in [TYPE_INT, TYPE_FLOAT] or is_nan(float(changes[axis])) or is_inf(float(changes[axis])): return false
	if not relations.has(from_id): relations[from_id] = {}
	if not relations[from_id].has(to_id): relations[from_id][to_id] = {"trust":50.0, "gratitude":0.0, "respect":50.0, "interest":0.0, "resentment":0.0, "events":{}}
	var edge: Dictionary = relations[from_id][to_id]
	var applied: Dictionary = {}
	for axis in changes:
		var key := event_id + ":" + str(axis)
		if edge["events"].has(key): continue
		var before := float(edge[axis])
		var delta := float(changes[axis]) * clampf(confidence, 0.0, 1.0) * (1.0 if witnessed else 0.5)
		if axis in ["trust", "respect"]: delta *= (1.0 - before / 100.0) if delta >= 0.0 else before / 100.0
		edge[axis] = clampf(before + delta, 0.0, 100.0)
		edge["events"][key] = {"tick":tick, "before":before, "after":edge[axis]}
		applied[axis] = edge["events"][key].duplicate()
	if applied.is_empty(): return false
	record(from_id, "relation:" + to_id + ":" + event_id, "relation", tick, {"target":to_id, "changes":applied})
	return true

func job_fit(id: String, job: String) -> Dictionary:
	var profile: Dictionary = JOBS.get(job, {})
	var person := view(id)
	if profile.is_empty() or person.is_empty(): return {"known":false, "score":null, "missing":[]}
	var score := 0.0
	var missing: Array = []
	for attribute in profile:
		var value: Variant = person["attributes"].get(attribute)
		if value == null: missing.append(attribute)
		else: score += Model.effective(float(value)) / 105.0 * float(profile[attribute])
	return {"known":missing.is_empty(), "score":score if missing.is_empty() else null, "missing":missing, "weights":profile.duplicate()}

func learn(id: String, event_id: String, tick: int, hours: float, weights: Dictionary, learning_weight: float = 1.0) -> bool:
	if not states.has(id) or hours <= 0.0 or is_nan(hours) or is_inf(hours) or weights.is_empty() or weights.size() > 3: return false
	var total := 0.0
	for attribute in weights:
		if attribute not in Model.keys() or typeof(weights[attribute]) not in [TYPE_INT, TYPE_FLOAT] or float(weights[attribute]) < 0.0 or is_nan(float(weights[attribute])) or is_inf(float(weights[attribute])): return false
		total += float(weights[attribute])
	if total <= 0.0 or total > 1.000001: return false
	var state: Dictionary = states[id]
	var day_key := str(tick)
	var usable := minf(hours, maxf(0.0, 8.0 - float(state["daily_hours"].get(day_key, 0.0))))
	if usable <= 0.0: return false
	if not record(id, event_id, "learning", tick, {"hours":usable, "weights":weights, "quality":clampf(learning_weight, 0.0, 1.0)}): return false
	state["daily_hours"][day_key] = float(state["daily_hours"].get(day_key, 0.0)) + usable
	for attribute in weights:
		state["learning"][attribute] = float(state["learning"].get(attribute, 0.0)) + usable * float(weights[attribute]) * clampf(learning_weight, 0.0, 1.0)
	return true

func settle_month(war, period: String) -> void:
	for id in states:
		var state: Dictionary = states[id]
		if state["last_month"] == period: continue
		state["last_month"] = period
		var def: Dictionary = definitions[id]
		for attribute in state["learning"]:
			var rank: Variant = def["potential_by_attribute"].get(attribute)
			var base: Variant = def["base_attributes"].get(attribute)
			if rank == null or base == null: continue
			var permanent := float(base) + float(state["growth"].get(attribute, 0.0))
			var age := age_of(id, int(war.store.year))
			# Unknown age must not be silently converted into a middle-aged person.
			if age < 0: continue
			var coefficient := 0.60 if age < 15 else 1.10 if age < 25 else 1.0 if age < 40 else 0.80 if age < 55 else 0.60 if age < 70 else 0.40
			var growth := minf(0.35 if attribute in Model.GROUPS[2] else 0.30, 0.60 * float(POTENTIAL[rank]) * coefficient * clampf(float(state["learning"][attribute]) / 80.0, 0.0, 1.0) * maxf(0.0, (120.0 - permanent) / 120.0))
			state["growth"][attribute] = float(state["growth"].get(attribute, 0.0)) + growth
			record(str(id), "growth:" + period + ":" + str(attribute), "attribute_growth", int(war.state["tick"]), {"attribute":attribute, "before":permanent, "after":permanent + growth})
		state["learning"] = {}
		state["daily_hours"] = {}
		settle_age(str(id), int(war.store.year), int(war.state["tick"]))
	for from_id in relations:
		for to_id in relations[from_id]:
			var edge: Dictionary = relations[from_id][to_id]
			if edge.get("last_month", "") == period: continue
			edge["last_month"] = period
			edge["trust"] = lerpf(float(edge["trust"]), 50.0, 0.005)
			edge["respect"] = lerpf(float(edge["respect"]), 50.0, 0.002)
			edge["gratitude"] = float(edge["gratitude"]) * 0.995
			edge["resentment"] = float(edge["resentment"]) * 0.99

func age_of(id: String, year: int) -> int:
	var birth: Variant = definitions[id].get("birth", {}).get("year")
	return maxi(0, year - int(birth)) if typeof(birth) in [TYPE_INT, TYPE_FLOAT] else -1

func settle_age(id: String, year: int, tick: int) -> void:
	var age := age_of(id, year)
	if age < 0: return
	var state: Dictionary = states[id]
	# A historical-stage snapshot already embodies the starting age. Only age
	# advances during this save are charged, and each calendar year once.
	if state["last_age_year"] == null:
		state["last_age_year"] = year
		return
	var previous := int(state["last_age_year"])
	if year <= previous: return
	for current_year in range(previous + 1, year + 1):
		var current_age := age_of(id, current_year)
		var modifiers: Dictionary = {}
		if current_age >= 45:
			var factor := 2.0 if current_age >= 60 else 1.0
			modifiers = {"膂力":-0.40 * factor,"体魄":-0.40 * factor,"骑术":-0.15 * factor,"武艺":-0.15 * factor,"射术":-0.15 * factor}
		if current_age >= 70:
			for attribute in ["智计", "料敌", "应变", "辩论"]: modifiers[attribute] = -0.10
		for attribute in modifiers: state["age_modifiers"][attribute] = float(state["age_modifiers"].get(attribute, 0.0)) + float(modifiers[attribute])
		if not modifiers.is_empty(): record(id, "age:%d" % current_year, "age_change", tick, {"age":current_age,"changes":modifiers})
	state["last_age_year"] = year

func professional_duty(id: String, event_id: String, tick: int, hours: float, troop: String, terrain: String, task_id: String, route_id: String) -> bool:
	if not states.has(id) or troop not in Model.TROOPS or terrain not in Model.TERRAINS or task_id.is_empty() or route_id.is_empty() or hours < 2.0 or is_nan(hours) or is_inf(hours): return false
	var state: Dictionary = states[id]
	if not state.has("professional_hours"): state["professional_hours"] = {}
	var usable := minf(hours, maxf(0.0, 8.0 - float(state["professional_hours"].get(str(tick), 0.0))))
	if usable < 2.0 or not record(id, event_id, "professional_experience", tick, {"hours":usable,"troop":troop,"terrain":terrain,"task_id":task_id,"route_id":route_id}): return false
	state["professional_hours"][str(tick)] = float(state["professional_hours"].get(str(tick), 0.0)) + usable
	var aptitude: Dictionary = state["aptitude_points"].get(troop, {"points":0.0,"tasks":{}})
	aptitude["points"] = float(aptitude["points"]) + usable
	aptitude["tasks"][task_id] = true
	state["aptitude_points"][troop] = aptitude
	var terrain_progress: Dictionary = state["terrain_days"].get(terrain, {"days":{},"routes":{}})
	terrain_progress["days"][str(tick)] = true
	terrain_progress["routes"][route_id] = true
	state["terrain_days"][terrain] = terrain_progress
	var rank: Variant = definitions[id]["troop_aptitudes"].get(troop)
	if rank != null:
		var ranks := ["D", "C", "B", "A", "S"]
		var current: int = ranks.find(rank)
		var costs := [80.0, 160.0, 320.0, 640.0]
		var promoted := current
		var points := float(aptitude["points"])
		while promoted < 4 and points >= float(costs[promoted]) and aptitude["tasks"].size() >= 3 * (promoted - current + 1):
			points -= float(costs[promoted])
			promoted += 1
		if not state.has("aptitude_ranks"): state["aptitude_ranks"] = {}
		state["aptitude_ranks"][troop] = ranks[promoted]
	var experience: Variant = definitions[id]["terrain_experience"].get(terrain)
	if experience != null:
		var days: int = terrain_progress["days"].size()
		var routes: int = terrain_progress["routes"].size()
		var result: String = str(experience)
		if experience == "unfamiliar" and days >= 20 and routes >= 2: result = "familiar"
		if (experience == "unfamiliar" and days >= 80 and routes >= 5) or (experience == "familiar" and days >= 60 and routes >= 5): result = "expert"
		if not state.has("terrain_ranks"): state["terrain_ranks"] = {}
		state["terrain_ranks"][terrain] = result
	return true

static func normalize_terrain(terrain: String) -> String:
	return str({"marsh":"wetland", "ford":"river"}.get(terrain, terrain))

func recover_injuries(id: String, event_id: String, tick: int, care: float, rest: float) -> bool:
	if not states.has(id) or not record(id, event_id, "recovery", tick, {"care":clampf(care, 0.0, 1.0),"rest":clampf(rest, 0.0, 1.0)}): return false
	for wound in states[id]["injuries"]:
		if not wound["permanent"]: wound["severity"] = maxf(0.0, float(wound["severity"]) - 0.10 * clampf(care, 0.0, 1.0) * clampf(rest, 0.0, 1.0))
	return true

func relation_label(from_id: String, to_id: String) -> String:
	var edge := relation(from_id, to_id)
	if edge.is_empty(): return "中立"
	if float(edge["resentment"]) >= 60.0: return "宿怨"
	if float(edge["trust"]) < 30.0: return "猜忌"
	if float(edge["trust"]) >= 70.0 and float(edge["resentment"]) < 20.0: return "同袍"
	return "中立"

func apply_definition_revision(id: String, revision: Dictionary, tick: int) -> Dictionary:
	if not states.has(id): return {"ok":false, "errors":["unknown_character"]}
	if str(revision.get("character_id", "")) != id: return {"ok":false, "errors":["id_mismatch"]}
	if int(revision.get("schema_version", -1)) != Model.VERSION: return {"ok":false, "errors":["schema_version"]}
	var errors := Model.validate(revision)
	if not errors.is_empty(): return {"ok":false, "errors":errors}
	if int(revision.get("design_revision", 0)) <= int(definitions[id].get("design_revision", 0)): return {"ok":false, "errors":["revision_not_newer"]}
	var prior: Dictionary = definitions[id]
	definitions[id] = revision.duplicate(true)
	definitions[id]["calibration_required"] = []
	record(id, "definition:%d" % int(revision["design_revision"]), "definition_migration", tick, {"before_revision":prior.get("design_revision", 0), "after_revision":revision["design_revision"], "prior_attributes":prior["base_attributes"].duplicate(true)})
	return {"ok":true, "errors":[]}

func injury(id: String, event_id: String, tick: int, body_part: String, severity: float, permanent: bool = false) -> bool:
	if not states.has(id) or body_part not in ["upper", "lower", "systemic"] or severity <= 0.0 or severity > 1.0 or is_nan(severity): return false
	if not record(id, event_id, "injury", tick, {"body_part":body_part, "severity":severity, "permanent":permanent}): return false
	var modifiers: Dictionary = {"upper":{"膂力":-12.0,"武艺":-8.0,"射术":-12.0}, "lower":{"骑术":-10.0,"体魄":-8.0}, "systemic":{"体魄":-15.0}}[body_part]
	# Same-location conditions combine severity rather than independently stacking
	# the same injury penalty. Permanent records cannot be healed by rest.
	for existing in states[id]["injuries"]:
		if existing["body_part"] == body_part and existing["permanent"] == permanent:
			existing["severity"] = 1.0 - (1.0 - float(existing["severity"])) * (1.0 - severity)
			existing["event_ids"].append(event_id)
			return true
	states[id]["injuries"].append({"body_part":body_part, "severity":severity, "permanent":permanent, "modifiers":modifiers.duplicate(), "event_ids":[event_id], "started":tick})
	return true

func can_personally_act(id: String, action: String) -> bool:
	if not states.has(id) or states[id]["service_status"] in ["dead", "prisoner"]: return false
	for wound in states[id]["injuries"]:
		if float(wound["severity"]) >= 0.7:
			if wound["body_part"] == "upper" and action in ["shoot", "melee"]: return false
			if wound["body_part"] == "lower" and action == "ride": return false
			if wound["body_part"] == "systemic": return false
	return true

func service_review(id: String) -> Dictionary:
	if not states.has(id): return {}
	var factors := {"kept_promises":0.0, "broken_promises":0.0, "recognition":0.0, "mistreatment":0.0}
	for promise in states[id]["promises"]:
		if promise.get("status", "") == "fulfilled": factors["kept_promises"] += 0.05
		elif promise.get("status", "") == "broken": factors["broken_promises"] -= 0.20
	for event in states[id]["events"]:
		if event["kind"] == "reward": factors["recognition"] += 0.05
		elif event["kind"] == "humiliation": factors["mistreatment"] -= 0.15
	var value := 0.5
	for factor in factors: value += float(factors[factor])
	return {"satisfaction":clampf(value, 0.0, 1.0), "factors":factors, "requires_review":value < 0.35, "automatic_betrayal":false}

func promise_event(id: String, promise_id: String, status: String, tick: int) -> bool:
	if not states.has(id) or status not in ["fulfilled", "broken"]: return false
	for promise in states[id]["promises"]:
		if promise.get("id", "") != promise_id or promise.get("status", "") == status: continue
		if not record(id, "promise:%s:%s" % [promise_id, status], "promise_resolution", tick, {"status":status}): return false
		promise["status"] = status
		return true
	return false

func task_event(war, id: String, event_id: String, kind: String, attributes: Dictionary, hours: float = 2.0) -> void:
	if not states.has(id): return
	learn(id, event_id, int(war.state["tick"]), hours, attributes)
	record(id, event_id + ":career", "duty", int(war.state["tick"]), {"task":kind, "attributes":attributes})

func after_day(war) -> void:
	sync(war)
	for army in war.active_armies():
		var id := str(army.get("officer_id", ""))
		var action := str(army.get("action", {}).get("type", "hold"))
		var weights: Dictionary = {"治军":1.0}
		if action in ["march", "continue", "withdraw", "reposition"]: weights = {"机动":0.5, "统兵":0.5}
		elif action in ["engage", "flank", "pursue"]: weights = {"统兵":0.5, "应变":0.5}
		elif action == "besiege": weights = {"攻坚":1.0}
		# Only actual deployed duty counts; waiting for mobilisation is not learning.
		if int(army.get("departure_at", -1)) > int(war.state["tick"]): continue
		task_event(war, id, "duty:%s:%d" % [army["id"], int(war.state["tick"])], action, weights)
		if action == "hold": continue
		var terrain: String = war.Tactical.terrain_class(int(army.get("tactical", {}).get("cell", -1))) if army.has("tactical") else ""
		terrain = normalize_terrain(terrain)
		var troop := ""
		var count := 0
		for kind in ["infantry", "cavalry", "archers"]:
			if int(army.get("units", {}).get(kind, 0)) > count: troop = kind; count = int(army["units"][kind])
		if troop != "" and terrain in Model.TERRAINS:
			professional_duty(id, "professional:%s:%d" % [army["id"], int(war.state["tick"])], int(war.state["tick"]), 2.0, troop, terrain, str(army["id"]), str(army.get("home", "")) + ":" + str(army.get("target", "")))
