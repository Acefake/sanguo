extends RefCounted

# New attributes are keyed, never identified by a position in a legacy matrix.
const VERSION := 1
const GROUPS := [["统兵", "攻坚", "机动", "奇袭", "治军"], ["智计", "沉着", "料敌", "应变", "辩论"], ["膂力", "体魄", "武艺", "骑术", "射术"], ["农桑", "财赋", "吏治", "法度", "外交"], ["威仪", "仁德", "信义", "名望", "容人"]]
const LEGACY := [["带兵", "布阵", "水练", "奇袭", "治军"], ["智计", "沉着", "料敌", "应变", "辩才"], ["膂力", "体魄", "武艺", "骑术", "箭术"], ["农桑", "商贾", "吏治", "律法", "辞令"], ["威仪", "仁德", "忠义", "名望", "雅量"]]
const DIRECT := {"统兵":"带兵", "奇袭":"奇袭", "治军":"治军", "智计":"智计", "沉着":"沉着", "料敌":"料敌", "应变":"应变", "辩论":"辩才", "膂力":"膂力", "体魄":"体魄", "武艺":"武艺", "骑术":"骑术", "射术":"箭术", "农桑":"农桑", "吏治":"吏治", "法度":"律法", "外交":"辞令", "威仪":"威仪", "仁德":"仁德", "名望":"名望"}
const TROOPS := ["infantry", "cavalry", "archers", "navy", "siege"]
const TERRAINS := ["plains", "hills", "mountains", "canyon", "forest", "river", "wetland", "city", "pass", "water"]

static func keys() -> Array:
	var result: Array = []
	for group in GROUPS: result.append_array(group)
	return result

static func valid_number(value: Variant) -> bool:
	return typeof(value) in [TYPE_FLOAT, TYPE_INT] and not is_nan(float(value)) and not is_inf(float(value)) and float(value) >= 0.0 and float(value) <= 120.0

static func effective(value: float) -> float:
	var x := clampf(value, 0.0, 120.0)
	return x if x <= 100.0 else 100.0 + 5.0 * (1.0 - exp(-(x - 100.0) / 10.0))

static func definition(card: Dictionary, officer: Dictionary) -> Dictionary:
	var attributes: Dictionary = {}
	var provenance: Dictionary = {}
	var issues: Array = []
	var explicit: Dictionary = card.get("base_attributes", {})
	var legacy: Dictionary = officer.get("skills", {})
	for attribute in keys():
		var value: Variant = explicit.get(attribute)
		var origin := "configured"
		if not explicit.has(attribute):
			origin = "legacy_review"
			var old_key := str(DIRECT.get(attribute, ""))
			var source := str(officer.get("data_sources", {}).get("skills", {}).get(old_key, "card"))
			value = legacy.get(old_key) if old_key != "" and source in ["card", "clamped_card"] else null
		if not valid_number(value):
			value = null
			issues.append(attribute)
			origin = "requires_calibration"
		attributes[attribute] = value
		provenance[attribute] = {"origin":origin, "legacy_key":DIRECT.get(attribute), "includes_legacy_trait_bonus":origin == "legacy_review"}
	var aptitudes: Dictionary = {}
	for troop in TROOPS:
		var rank: Variant = card.get("troop_aptitudes", {}).get(troop)
		aptitudes[troop] = rank if rank in ["D", "C", "B", "A", "S"] else null
	var terrains: Dictionary = {}
	for terrain in TERRAINS:
		var rank: Variant = card.get("terrain_experience", {}).get(terrain)
		terrains[terrain] = rank if rank in ["unfamiliar", "familiar", "expert"] else null
	var potential: Dictionary = {}
	for attribute in keys():
		var rank: Variant = card.get("potential_by_attribute", {}).get(attribute)
		potential[attribute] = rank if rank in ["S", "A", "B", "C"] else null
	return {"character_id":str(officer["id"]), "schema_version":VERSION, "design_revision":int(card.get("design_revision", 0)), "name":str(officer["name"]), "courtesy_name":str(card.get("style_name", "")), "base_attributes":attributes, "attribute_provenance":provenance, "calibration_required":issues, "troop_aptitudes":aptitudes, "terrain_experience":terrains, "potential_by_attribute":potential, "birth":card.get("birth", {"year":null, "precision":"unknown"}), "source_url":str(card.get("source", "")), "legacy_card":card.duplicate(true)}

static func initial_state(def: Dictionary, officer: Dictionary) -> Dictionary:
	return {"character_id":def["character_id"], "schema_version":VERSION, "faction_id":str(officer.get("faction", "")), "service_status":"serving" if str(officer.get("faction", "")) != "" else "wild", "growth":{}, "age_modifiers":{}, "injuries":[], "aptitude_points":{}, "terrain_days":{}, "learning":{}, "daily_hours":{}, "career":[], "events":[], "event_keys":{}, "promises":[], "availability":{}, "last_month":"", "last_age_year":null}

static func view(def: Dictionary, state: Dictionary) -> Dictionary:
	var attributes: Dictionary = {}
	var wounds: Dictionary = {}
	for injury in state.get("injuries", []):
		var part := str(injury.get("body_part", "systemic"))
		var group: Dictionary = wounds.get(part, {"severity":0.0,"modifiers":injury.get("modifiers", {})})
		group["severity"] = 1.0 - (1.0 - float(group["severity"])) * (1.0 - float(injury.get("severity", 0.0)))
		wounds[part] = group
	for attribute in keys():
		var base: Variant = def["base_attributes"][attribute]
		if base == null:
			attributes[attribute] = null
			continue
		var value := float(base) + float(state.get("growth", {}).get(attribute, 0.0)) + float(state.get("age_modifiers", {}).get(attribute, 0.0))
		for injury in wounds.values():
			value += float(injury.get("modifiers", {}).get(attribute, 0.0)) * float(injury.get("severity", 0.0))
		attributes[attribute] = clampf(value, 0.0, 120.0)
	var dimensions: Array = []
	for group in GROUPS:
		var total := 0.0
		var complete := true
		for attribute in group:
			if attributes[attribute] == null: complete = false
			else: total += float(attributes[attribute])
		dimensions.append(total / 5.0 if complete else null)
	var aptitudes: Dictionary = def["troop_aptitudes"].duplicate()
	aptitudes.merge(state.get("aptitude_ranks", {}), true)
	var terrains: Dictionary = def["terrain_experience"].duplicate()
	terrains.merge(state.get("terrain_ranks", {}), true)
	return {"character_id":def["character_id"], "name":def["name"], "attributes":attributes, "dimensions":dimensions, "faction_id":state.get("faction_id", ""), "service_status":state.get("service_status", "wild"), "availability":state.get("availability", {}).duplicate(true), "calibration_required":def.get("calibration_required", []).duplicate(), "troop_aptitudes":aptitudes, "terrain_experience":terrains}

static func validate(def: Dictionary) -> Array:
	var errors: Array = []
	if str(def.get("character_id", "")).is_empty(): errors.append("character_id")
	if str(def.get("name", "")).is_empty(): errors.append("name")
	for field in ["base_attributes", "potential_by_attribute", "troop_aptitudes", "terrain_experience"]:
		if not def.get(field) is Dictionary: errors.append("field_type:" + str(field))
	if not errors.is_empty(): return errors
	if def.get("base_attributes", {}).size() != 25: errors.append("attribute_key_count")
	if def.get("potential_by_attribute", {}).size() != 25: errors.append("potential_key_count")
	if def.get("troop_aptitudes", {}).size() != 5: errors.append("aptitude_key_count")
	if def.get("terrain_experience", {}).size() != 10: errors.append("terrain_key_count")
	for attribute in keys():
		if not valid_number(def.get("base_attributes", {}).get(attribute)): errors.append("attribute:" + str(attribute))
	for troop in TROOPS:
		if def.get("troop_aptitudes", {}).get(troop) not in ["D", "C", "B", "A", "S"]: errors.append("aptitude:" + str(troop))
	for terrain in TERRAINS:
		if def.get("terrain_experience", {}).get(terrain) not in ["unfamiliar", "familiar", "expert"]: errors.append("terrain:" + str(terrain))
	for attribute in keys():
		if def.get("potential_by_attribute", {}).get(attribute) not in ["S", "A", "B", "C"]: errors.append("potential:" + str(attribute))
	return errors
