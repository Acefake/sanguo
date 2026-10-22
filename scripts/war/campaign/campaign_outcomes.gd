class_name CampaignOutcomes
extends RefCounted
## 战果：围城破口与攻占、溃败与主帅失位、胜负记入经验。
##
## 所有函数都是静态的，第一个参数 war 是 CampaignState 实例（不标类型，避免与它互相引用）。

const Traits = preload("res://scripts/officers/trait_registry.gd")
const Fate = preload("res://scripts/war/campaign/officer_fate.gd")
const Combat = preload("res://scripts/war/battle/combat_system.gd")
const Corps = preload("res://scripts/war/campaign/army_corps.gd")
const Tactical = preload("res://scripts/war/battle/tactical_battlefield.gd")
const Siege = preload("res://scripts/war/battle/siege_system.gd")
const Experience = preload("res://scripts/agents/experience.gd")
const StateKeys = preload("res://scripts/war/campaign/war_state_keys.gd")


## 结算围城，城防出现破口时通知本方参战部队。
static func _resolve_sieges(war) -> void:
	Siege.resolve(war)
	for node in war.state[StateKeys.SIEGES]:
		var siege: Dictionary = war.state[StateKeys.SIEGES][node]
		if float(siege.get("wall", 1)) > 0 and float(siege.get("gate", 1)) > 0: continue
		for id in siege.get("participants", []):
			var army: Dictionary = war.state[StateKeys.ARMIES].get(id, {})
			if army.is_empty() or army["faction"] != war.state[StateKeys.PLAYER_FACTION]: continue
			war._report(army, "破城", war.graph.name_of(str(node)) + "防线已出现破口，部队可进入城内作战。", true, "siege:%s:%s" % [node, siege.get("started", 0)])
			break


## 攻占城池：俘获守军与武将、留兵驻防、各胜方部队完成目标。
static func _capture_city(war, army: Dictionary, besiegers: Array, node: String, city: Dictionary) -> void:
	var old_faction := str(city.get("faction", ""))
	var guard := str(war.state[StateKeys.GARRISON_COMMANDERS].get(node, {}).get("officer_id", ""))
	for id in war.state[StateKeys.OFFICER_STATES]:
		var officer: Dictionary = war.state[StateKeys.OFFICER_STATES][id]
		if id == guard or officer.get("status", "") not in ["available", "recovering"] or officer.get("city", "") != node or war.roster.officers.get(id, {}).get("faction", "") != old_faction: continue
		war.state[StateKeys.OFFICER_FATES][id] = {"officer_id": id, "name": war.roster.officers[id]["name"], "faction": old_faction, "status": "captured", "tick": int(war.state[StateKeys.TICK]), "cause": "城池失守", "captor_id": army["officer_id"], "captor_faction": army["faction"], "city": node}
	Fate.restore(war)
	city["prisoners"] = int(city.get("prisoners", 0)) + int(city["garrison"]) + int(city.get("wounded", 0))
	city["wounded"] = 0
	city["wounded_units"] = {"infantry": 0, "archers": 0, "cavalry": 0}
	city["garrison"] = 0
	city["units"] = {"infantry": 0, "archers": 0, "cavalry": 0}
	city["faction"] = army["faction"]
	war.roster.ensure_factions(war.store.scenario)
	for id in war.roster.officers:
		if war.roster.officers[id].get("generated", false): war.state[StateKeys.GENERATED_OFFICERS][id] = war.roster.officers[id].duplicate(true)
	city["last_volley_tick"] = -10
	city["governor_id"] = ""
	city["occupied_at"] = int(war.state[StateKeys.TICK])
	var left := 0
	for unit in besiegers:
		var remaining := mini(Combat.strength(unit), maxi(1, int(Combat.strength(unit) * 0.15)))
		var deposited := remaining
		for type in Combat.TYPES:
			var take := mini(remaining, int(unit["units"][type]))
			unit["units"][type] -= take
			city["units"][type] += take
			remaining -= take
		unit["deposited"] += deposited
		left += deposited
	city["garrison"] = left
	if city.has("population"):
		for officer in war.available_officers(str(army["faction"])):
			city["governor_id"] = officer["id"]
			break
	var winners := {}
	for victor in besiegers:
		_battle_victory(war, victor)
		winners[victor["id"]] = victor
		var corps: Dictionary = war.state[StateKeys.CORPS].get(victor.get("corps_id", ""), {})
		for id in corps.get("units", []): winners[id] = war.state[StateKeys.ARMIES][id]
	for unit in winners.values():
		if unit["status"] == "ended": continue
		unit["objective_complete"] = true
		unit["outcome"] = "攻取成功"
		if war._has_independent_action(unit): continue
		if war.orders_for(unit)["after_battle"] == "withdraw": war._execute(unit, {"type": "withdraw"})
		else: unit["action"] = {"type": "hold"}
	war._report(army, "占领", "%s攻取%s，留下%d人驻防。" % [army["name"], war.graph.name_of(node), left], true)
	if war.state.get(StateKeys.BATTLEFIELD, {}).get("objectives", {}).has(node):
		war.state[StateKeys.BATTLEFIELD]["winner"] = army["faction"]
		war.state[StateKeys.BATTLEFIELD]["ended_at"] = war.state[StateKeys.TICK]


## 决定武将命运时面对的敌人：当日交手者、相邻敌军或守将。
static func _fate_enemy(war, army: Dictionary) -> Dictionary:
	var recent: Dictionary = war.state[StateKeys.ARMIES].get(army.get("last_enemy_id", ""), {})
	if int(army.get("last_enemy_tick", -1)) == int(war.state[StateKeys.TICK]) and not recent.is_empty() and recent["faction"] != army["faction"]: return recent
	for enemy in war.active_armies():
		if not war.hostile(str(enemy["faction"]), str(army["faction"])) or enemy["returning"]: continue
		if army.has("tactical") and enemy.has("tactical"):
			if Tactical.distance(army, enemy) <= 1: return enemy
		elif war._contact(army, enemy, {}): return enemy
	var guard: Dictionary = war.state[StateKeys.GARRISON_COMMANDERS].get(army["target"], {})
	if not guard.is_empty() and guard["faction"] != army["faction"] and Siege.at_city(war, army, army["target"]):
		var defender := guard.duplicate(true)
		defender["units"] = war.store.city_state(army["target"]).get("units", {})
		return defender
	return {}


## 检查覆没与溃败；有友军掩护时可能改为归建整阵。
static func _check_rout(war, army: Dictionary) -> void:
	if army["status"] == "ended": return
	if Combat.strength(army) <= 0:
		Fate.encounter(war, army, _fate_enemy(war, army), "destroyed", 1.0)
		war.state[StateKeys.BATTLE_VICTORIES].erase(str(army["officer_id"]))
		army["victory_chain"] = false
		war._finish(army, "军队覆没")
		return
	if army["returning"]: return
	var morale := float(army["morale"])
	var organization := float(army["organization"])
	var aura_shift := float(army.get("aura", 0.0)) * float(war.rules.get("officer", {}).get("aura_rout_shift", 20))
	if morale >= 25.0 - aura_shift and organization >= 20:
		army.erase("rout_crisis_since")
		return
	if not army.has("rout_crisis_since"): army["rout_crisis_since"] = int(war.state[StateKeys.TICK])
	# A disordered but supplied force can rally behind nearby healthy allies.
	# Hard panic still routs; manpower alone never makes a shattered army invincible.
	var supported := false
	if army.has("tactical"):
		for friend in war.active_armies(str(army["faction"])):
			if friend["id"] != army["id"] and not friend["returning"] and friend.has("tactical") and float(friend["morale"]) >= 35 and float(friend["organization"]) >= 30 and Tactical.distance(army, friend) <= 3:
				supported = true
				break
	var substantial := Combat.strength(army) >= maxf(500, float(army.get("initial_strength", 0)) * 0.4)
	var corps: Dictionary = war.state[StateKeys.CORPS].get(army.get("corps_id", ""), {})
	var can_regroup: bool = not corps.is_empty() and army["id"] != corps["root_id"]
	var rally_window := int(war.state[StateKeys.TICK]) - int(army["rout_crisis_since"]) < 6
	if supported and substantial and can_regroup and rally_window and morale > 10 and organization > 8 and (not war.supply_enabled() or float(army.get("grain", 0)) >= war.daily_food(army)):
		var reason := "友军掩护，主帅令本队归建整阵，仍留在战场"
		var regroup_result := Corps.issue(war, corps, {"type": "assign_task", "unit": army["id"], "task": "regroup"}, reason)
		if regroup_result.get("ok", false):
			army["last_reason"] = reason
			army["rally_requested"] = int(war.state[StateKeys.TICK])
			return
	if supported and morale > 10 and organization > 8 and int(war.state[StateKeys.TICK]) == int(army["rout_crisis_since"]):
		army["last_reason"] = "友军接应稳住阵线，等待主帅接替"
		return
	army["returning"] = true
	army["outcome"] = "溃败撤退"
	Fate.encounter(war, army, _fate_enemy(war, army), "rout", 1.0)
	army["retreat_reason"] = "军心崩溃（士气%d）" % int(morale) if morale < 25 else "阵形崩溃（组织%d）" % int(organization)
	army["last_reason"] = army["retreat_reason"]
	war.state[StateKeys.BATTLE_VICTORIES].erase(str(army["officer_id"]))
	army["victory_chain"] = false
	war._report(army, "溃败", "%s所部%s，剩余%d人，正在有序脱离。" % [army["name"], army["retreat_reason"], Combat.strength(army)], true)
	_remember_loss(war, army, "军心崩溃")
	war._start_return(army)


## 军团主帅覆没或撤退时，其余各部士气与组织下降一次。
static func _check_leader_lost(war) -> void:
	var section: Dictionary = war.rules.get("officer", {})
	for corps in war.state[StateKeys.CORPS].values():
		if corps.get("ended", false): continue
		var root: Dictionary = war.state[StateKeys.ARMIES].get(str(corps.get("root_id", "")), {})
		if root.is_empty(): continue
		if not (str(root.get("status", "")) == "ended" or bool(root.get("returning", false))): continue
		if str(corps.get("leader_lost_for", "")) == str(corps.get("commander_id", "")): continue
		corps["leader_lost_for"] = str(corps.get("commander_id", ""))
		corps["leader_lost"] = true
		var sample := {}
		for id in corps.get("units", []):
			var unit: Dictionary = war.state[StateKeys.ARMIES].get(str(id), {})
			if unit.is_empty() or str(unit["status"]) == "ended" or unit["id"] == root["id"]: continue
			unit["morale"] = maxf(0.0, float(unit["morale"]) - float(section.get("leader_loss_morale", 8)))
			unit["organization"] = maxf(0.0, float(unit["organization"]) - float(section.get("leader_loss_org", 4)))
			if sample.is_empty(): sample = unit
		if not sample.is_empty():
			war._report(sample, "主帅失位", "主帅失位：%s所部军心动摇，全军士气下降。" % str(corps.get("name", "")), true)


## 记一次交战胜利，维持连胜特性的计时。
static func _battle_victory(war, army: Dictionary) -> void:
	_remember_win(war, army, "交战取胜")
	if not Traits.mechanism(army, "victory_chain").is_empty() and army.get("mission_type", "") == "capture" and not army.get("returning", false) and army.get("status", "") != "ended":
		war.state[StateKeys.BATTLE_VICTORIES][str(army["officer_id"])] = int(war.state[StateKeys.TICK])


## 胜利写入经验，每日最多一次。
static func _remember_win(war, army: Dictionary, cause: String) -> void:
	if int(army.get("experience_tick", -1)) == int(war.state[StateKeys.TICK]): return
	army["experience_tick"] = int(war.state[StateKeys.TICK])
	Experience.record_win(war, army, _nearest_enemy_id(war, army), cause)


## 失利写入经验，每日最多一次。
static func _remember_loss(war, army: Dictionary, cause: String) -> void:
	if int(army.get("experience_tick", -1)) == int(war.state[StateKeys.TICK]): return
	army["experience_tick"] = int(war.state[StateKeys.TICK])
	Experience.record_loss(war, army, _nearest_enemy_id(war, army), cause)


## 最近的敌军 id。
static func _nearest_enemy_id(war, army: Dictionary) -> String:
	var best := ""
	var closest := 1 << 30
	for other in war.active_armies():
		if not war.hostile(str(other.get("faction", "")), str(army.get("faction", ""))): continue
		var distance := 1
		if army.has("tactical") and other.has("tactical"): distance = Tactical.distance(army, other)
		elif str(army.get("location", {}).get("node", "")) == str(other.get("location", {}).get("node", "")): distance = 0
		if distance < closest: closest = distance; best = str(other.get("id", ""))
	return best
