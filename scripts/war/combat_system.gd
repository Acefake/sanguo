extends RefCounted

const Officer = preload("res://scripts/war/officer_battle.gd")
const Terrain = preload("res://scripts/war/battle_terrain.gd")
const TYPES := ["infantry", "archers", "cavalry"]


# The exchange math lives in campaign_rules.json so balance can be tuned without
# touching code. Every lookup keeps an inline default, so a rules file that predates
# this section still resolves to the previous numbers.
static func settings(config: Dictionary = {}) -> Dictionary:
	return config.get("combat", Terrain.rules().get("combat", {}))


static func _num(section: Dictionary, key: String, fallback: float) -> float:
	return float(section.get(key, fallback))


static func is_ranged(army: Dictionary) -> bool:
	if bool(army.get("melee_attack",false)): return false
	if bool(army.get("ranged_attack", false)): return true
	var total := strength(army)
	return total > 0 and int(army.get("units", {}).get("archers", 0)) == total


static func aggregate(armies: Array) -> Dictionary:
	var combined: Dictionary = {"units": {"infantry": 0, "archers": 0, "cavalry": 0}, "training": 0.0, "equipment": 0.0, "organization": 0.0, "fatigue": 0.0, "morale": 0.0, "skills": {"布阵": 0.0}}
	var total: int = 0
	combined["components"] = armies
	for army in armies:
		var count: int = strength(army)
		total += count
		for type in TYPES: combined["units"][type] += int(army["units"].get(type, 0))
		for field in ["training", "equipment", "organization", "fatigue", "morale"]:
			combined[field] += float(army.get(field, 50)) * count
		for group in preload("res://scripts/agents/officer_context.gd").SKILLS:
			for key in group:
				combined["skills"][key] = float(combined["skills"].get(key, 0)) + float(army.get("skills", {}).get(key, 50)) * count
	for field in ["training", "equipment", "organization", "fatigue", "morale"]:
		combined[field] /= maxf(total, 1)
	for key in combined["skills"]: combined["skills"][key] /= maxf(total, 1)
	return combined


static func strength(army: Dictionary) -> int:
	var count: int = 0
	for value in army.get("units", {}).values():
		count += int(value)
	return count


static func power_breakdown(army: Dictionary, config: Dictionary, terrain: String, defender: Dictionary = {}) -> Dictionary:
	var units: Dictionary = config.get("units", config)
	var attributes: Dictionary = settings(config).get("attributes", {})
	var base := 0.0
	var skilled := 0.0
	var adjusted := 0.0
	for type in TYPES:
		var amount := float(army.get("units", {}).get(type, 0)) * float(units[type]["damage"])
		base += amount
		skilled += amount * Officer.unit_attack(army, type, terrain)
		adjusted += amount * Officer.unit_attack(army, type, terrain) * Terrain.unit_factor(type, terrain, config)
	var ranged: bool = is_ranged(army)
	var section: Dictionary = config.get("officer", {})
	var command := clampf(_num(attributes,"command_base",0.8)+Officer.skill(army,"布阵")/_num(attributes,"command_divisor",250),_num(attributes,"command_min",0.8),_num(attributes,"command_max",1.28))*Officer.factor(army,["带兵","治军"],_num(attributes,"command_weight",0.002))
	var unit_skill := skilled/maxf(base,1)
	# First layer: the officer's own attack composite is deliberately narrow.
	var officer_attack := clampf(unit_skill * command, float(section.get("attack_min",0.8)), float(section.get("attack_max",1.2)))
	command *= officer_attack / maxf(unit_skill * command, 0.0001)
	var result := {"base": base, "morale": clampf(float(army.get("morale",100))/_num(attributes,"morale_divisor",100),_num(attributes,"morale_min",0.25),1), "training": _num(attributes,"training_base",0.6)+float(army.get("training",50))/_num(attributes,"training_divisor",125), "equipment": _num(attributes,"equipment_base",0.7)+float(army.get("equipment",50))/_num(attributes,"equipment_divisor",166.7), "organization":clampf(float(army.get("organization",100))/_num(attributes,"organization_divisor",100),_num(attributes,"organization_min",0.3),1), "fatigue":1-float(army.get("fatigue",0))/_num(attributes,"fatigue_divisor",180), "command": command, "unit_skill":unit_skill, "officer_attack":officer_attack, "terrain": adjusted/maxf(skilled,1), "terrain_class":terrain, "delay":Terrain.entry_factor(army,config), "wounded": float(config.get("duel",Terrain.rules().get("duel",{})).get("wounded_attack",0.9)) if army.get("duel_wounded",false) else 1.0}
	result["power"] = base
	# Counters belong to the exchange, rather than the army's raw attack power.
	result["counters"] = counters(army, defender, config)
	for key in ["morale","training","equipment","organization","fatigue","command","unit_skill","terrain","delay","wounded"]: result["power"] *= float(result[key])
	return result

static func power(army: Dictionary, config: Dictionary, terrain: String) -> float:
	if army.has("components"):
		var output := 0.0
		for member in army["components"]: output += power(member,config,terrain)
		return output
	return float(power_breakdown(army,config,terrain)["power"])

static func counters(attacker: Dictionary, defender: Dictionary, config: Dictionary = {}) -> float:
	var matrix: Dictionary = settings(config).get("counters", {})
	var count := maxf(strength(attacker), 1)
	var total := maxf(strength(defender), 1)
	var a_inf := float(attacker.get("units",{}).get("infantry",0))/count
	var a_arc := float(attacker.get("units",{}).get("archers",0))/count
	var a_cav := float(attacker.get("units",{}).get("cavalry",0))/count
	var d_inf := float(defender.get("units",{}).get("infantry",0))/total
	var d_arc := float(defender.get("units",{}).get("archers",0))/total
	var d_cav := float(defender.get("units",{}).get("cavalry",0))/total
	# Each pairing is a matchup advantage on both sides, so the reverse legs count too.
	return 1 + _num(matrix,"cavalry_vs_archers",0.15) * a_cav * d_arc \
		+ _num(matrix,"archers_vs_infantry",0.12) * a_arc * d_inf \
		+ _num(matrix,"archers_vs_cavalry",0.08) * a_arc * d_cav \
		+ _num(matrix,"infantry_vs_cavalry",0.08) * a_inf * d_cav

static func personal_power(army: Dictionary, config: Dictionary) -> float:
	if army.has("components"):
		var sum := 0.0
		for member in army["components"]: sum += personal_power(member, config)
		return sum
	if not army.has("officer_id") or army.get("commander_unavailable", false) or army.get("returning", false) or strength(army) <= 0: return 0.0
	var rules: Dictionary = config.get("personal_combat", {})
	var tuning: Dictionary = settings(config).get("personal", {})
	var prowess := (Officer.skill(army, "武艺") * 0.6 + Officer.skill(army, "膂力") * 0.4)
	return clampf((prowess - _num(tuning,"prowess_offset",30)) / _num(tuning,"prowess_divisor",20), 0, float(rules.get("max_damage", 4))) * (1 - float(army.get("fatigue", 0)) / _num(tuning,"fatigue_divisor",150)) * (_num(tuning,"wounded_factor",0.75) if army.get("duel_wounded", false) else 1.0)

static func losses_detail(attacker: Dictionary, defender: Dictionary, config: Dictionary, terrain: String, random_factor: float = 1.0, fortification: float = 1.0, attacker_terrain: String = "") -> Dictionary:
	var total := strength(defender)
	# The attacker's own ground drives its attack modifiers; the defender's own ground
	# drives cover. Passing one tile for both read a cavalry army's terrain bonus off a
	# mountain it was not standing on.
	var ground: String = terrain if attacker_terrain.is_empty() else attacker_terrain
	var output := power(attacker, config, ground)
	if total <= 0 or output <= 0:
		return {"loss": 0, "raw": 0.0, "factors": {}}
	var rules: Dictionary = config.get("units", config)
	var tuning := settings(config)
	var attack_data := Terrain.settings(ground, config)
	var data := Terrain.settings(terrain, config)
	# Share of the attacker that can be brought to bear, independent of the defender.
	var frontage := minf(1.0, float(attack_data.get("capacity", 1)))
	var toughness := 0.0
	for type in TYPES: toughness += float(defender.get("units", {}).get(type, 0)) * float(rules[type]["toughness"])
	toughness /= total
	var counter_factor := counters(attacker, defender, config)
	var ranged: bool = is_ranged(attacker)
	var ranged_factor := float(attack_data.get("ranged_attack", 1)) if ranged else 1.0
	var section: Dictionary = config.get("officer", {})
	var officer_defense := Officer.defense(defender, terrain, config)
	var edge_attack := clampf(float(attacker.get("edge_attack", 1.0)), float(section.get("total_min", 0.6)), float(section.get("total_max", 1.6)))
	var edge_defense := clampf(float(defender.get("edge_defense", 1.0)), float(section.get("total_min", 0.6)), float(section.get("total_max", 1.6)))
	# Defensive officer effects are received-loss multipliers.
	var defense := toughness * fortification * officer_defense * float(data.get("defense", 1))
	var received := edge_defense
	var role_rules = preload("res://scripts/war/troop_roles.gd")
	if not ranged:
		var bow_share := float(defender.get("units",{}).get("archers",0))/maxf(strength(defender),1)
		received *= lerpf(1.0,float(role_rules.traits(config).get("archers",{}).get("melee_received",1.2)),bow_share)
		output *= role_rules.exchange_factor(attacker,true,ground,config)
	var tactic := clampf(Officer.tactic(attacker, defender) * edge_attack, float(section.get("total_min", 0.6)), float(section.get("total_max", 1.6)))
	var raw := output * frontage * counter_factor * _num(tuning, "damage_scale", 0.035) * random_factor * ranged_factor * received * tactic / maxf(defense, 0.2)
	# A distinct melee strike by the commander, not a share of soldiers' attack.
	var personal := 0.0 if ranged else personal_power(attacker, config) * random_factor / maxf(defense, 0.2)
	raw += personal
	# Factor contributions are ratios around 1.0 so a report can name the largest few.
	var factors := {"地形": float(data.get("defense", 1)), "远射": ranged_factor, "展开": frontage, "兵种克制": counter_factor, "承受": received, "将领防御": maxf(officer_defense, 0.2), "将领进攻": tactic, "工事": fortification}
	if ground != terrain: factors["进攻地形"] = float(attack_data.get("attack", 1)) * (float(attack_data.get("cavalry_attack", 1)) if float(attacker.get("units", {}).get("cavalry", 0)) > 0 else 1.0)
	if not is_equal_approx(edge_attack, 1.0): factors["专长进攻"] = edge_attack
	if not is_equal_approx(edge_defense, 1.0): factors["专长守御"] = edge_defense
	var floor_loss := mini(int(tuning.get("min_loss", 1)), total)
	var result := {"loss": clampi(int(raw), floor_loss, total), "raw": raw, "personal_fraction": personal / maxf(raw, 0.001), "factors": factors}
	return result


static func losses(attacker: Dictionary, defender: Dictionary, config: Dictionary, terrain: String, random_factor: float, fortification: float = 1.0) -> int:
	return int(losses_detail(attacker,defender,config,terrain,random_factor,fortification)["loss"])


static func apply_loss(army: Dictionary, amount: int, captured: bool = false, morale_scale: float = 1.0, aura: float = 0.0, aura_org_scale: float = 0.5, config: Dictionary = {}) -> int:
	var attributes: Dictionary = settings(config).get("attributes", {})
	var dead_ratio := float(settings(config).get("death_ratio", 0.65))
	var remaining: int = mini(maxi(amount, 0), strength(army))
	var actual: int = remaining
	var total: int = strength(army)
	var losses_by_type := {}
	for index in range(TYPES.size()):
		var type: String = TYPES[index]
		var count: int = int(army["units"].get(type, 0))
		var loss: int = mini(count, remaining if index == TYPES.size() - 1 else int(ceil(float(actual) * count / maxf(total, 1))))
		loss = mini(loss, remaining)
		army["units"][type] = count - loss
		losses_by_type[type] = loss
		remaining -= loss
	if captured:
		army["captured"] = int(army.get("captured", 0)) + actual
	else:
		var dead: int = int(ceil(actual * dead_ratio))
		army["dead"] = int(army.get("dead", 0)) + dead
		army["wounded"] = int(army.get("wounded", 0)) + actual - dead
		if not army.get("wounded_units") is Dictionary: army["wounded_units"] = {"infantry": int(army["wounded"]) - actual + dead, "archers": 0, "cavalry": 0}
		var left := actual - dead
		for index in range(TYPES.size()):
			var type: String = TYPES[index]
			var wounded := mini(left, int(losses_by_type[type])) if index == TYPES.size() - 1 else mini(left, int(floor(float(actual - dead) * int(losses_by_type[type]) / maxf(actual, 1))))
			army["wounded_units"][type] = int(army["wounded_units"].get(type, 0)) + wounded
			left -= wounded
		for type in TYPES:
			if left <= 0: break
			var extra: int = mini(left, int(losses_by_type[type]))
			army["wounded_units"][type] += extra
			left -= extra
	# The 小霸王 opening shock is set before the exchange and settled afterwards.
	# Every real path calls apply_loss first and battle_morale second, so the marker
	# is moved rather than dropped here; leaving it on the army let it survive the
	# day and re-trigger later. The two morale terms are mutually exclusive:
	 # morale_scale is 0 exactly when battle_morale runs, so the shock lands once.
	var shock := float(army.get("incoming_shock", army.get("morale_shock", 1.0)))
	if army.has("incoming_shock") or army.has("morale_shock"): army["morale_shock"] = shock
	army.erase("incoming_shock")
	army["morale"] = maxf(0, float(army.get("morale", 100)) - float(actual) / maxf(total, 1) * _num(attributes,"morale_loss_weight",85.0) * morale_scale * shock / Officer.factor(army, ["沉着", "威仪", "忠义"], 0.003) / (1.0 + aura))
	army["organization"] = maxf(0, float(army.get("organization", 100)) - float(actual) / maxf(total, 1) * _num(attributes,"organization_loss_weight",70.0) / Officer.factor(army, ["治军", "应变"], 0.004) / (1.0 + aura * aura_org_scale))
	return actual


static func battle_morale(army: Dictionary, received: int, inflicted: float, before: int, enemy_before: float, friendly_strength: float, enemy_strength: float, flanked: bool = false, aura: float = 0.0, aura_org_scale: float = 0.5, config: Dictionary = {}) -> float:
	var mood: Dictionary = settings(config).get("morale", {})
	# An unclosed opening strike is settled here, because battle_morale is the only
	# place that actually moves morale; apply_loss is called with morale_scale 0.
	var shock := float(army.get("morale_shock", army.get("incoming_shock", 1.0)))
	army.erase("morale_shock")
	army.erase("incoming_shock")
	var hurt := float(received) / maxf(before, 1)
	var success := inflicted / maxf(enemy_before, 1)
	var advantage := friendly_strength / maxf(enemy_strength, 1)
	var resilience := Officer.factor(army, ["沉着", "威仪", "忠义"], 0.003)
	var change := (success * _num(mood,"success_weight",50.0) - hurt * _num(mood,"hurt_weight",85.0) * clampf(1.0 / maxf(advantage, 0.1), _num(mood,"advantage_floor",0.65), _num(mood,"advantage_ceiling",1.5))) / resilience
	# Winning a light exchange sustains morale; heavy losses still shake a larger army.
	if inflicted >= received and hurt <= _num(mood,"comfort_hurt",0.03) and advantage >= _num(mood,"comfort_advantage",0.9):
		change = maxf(change, minf(_num(mood,"comfort_gain_cap",2.5), _num(mood,"comfort_gain_base",0.6) + success * _num(mood,"comfort_gain_per_success",25.0)))
		army["organization"] = minf(100, float(army["organization"]) + _num(mood,"comfort_organization",1.5) * Officer.factor(army, ["治军", "应变"], 0.004))
	if hurt >= _num(mood,"panic_hurt",0.08): change = minf(change, -hurt * _num(mood,"panic_weight",65.0) / resilience)
	# A commander's aura steadies morale losses within range.
	if aura > 0.0 and change < 0.0: change /= (1.0 + aura)
	if shock > 1.0 and change < 0.0: change *= shock
	if flanked:
		change -= _num(mood,"flank_penalty",2.0)
		army["organization"] = maxf(0, float(army["organization"]) - _num(mood,"flank_penalty",2.0) / (1.0 + aura * aura_org_scale))
	change = clampf(change, _num(mood,"floor",-20.0), _num(mood,"ceiling",3.0))
	army["morale"] = clampf(float(army["morale"]) + change, 0, 100)
	army["morale_change"] = change
	army["morale_reason"] = "伤亡过重" if hurt >= _num(mood,"panic_hurt",0.08) else "遭到夹击" if flanked else "首战受挫" if shock > 1.0 and change < 0.0 else "占优稳住军心" if change >= 0 else "本日交战不利"
	return change
