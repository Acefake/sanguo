class_name CampaignLogistics
extends RefCounted
## 粮草与兵员：补给开关、每日耗粮、兵员账本、每日给养结算，以及城内兵种库存。
##
## 所有函数都是静态的，第一个参数 war 是 CampaignState 实例（不标类型，避免与它互相引用）。

const Process = preload("res://scripts/officers/officer_process.gd")
const Combat = preload("res://scripts/war/battle/combat_system.gd")
const Tactical = preload("res://scripts/war/battle/tactical_battlefield.gd")
const Terrain = preload("res://scripts/war/battle/battle_terrain.gd")


## 规则是否启用粮草补给。
static func supply_enabled(war) -> bool:
	return bool(war.rules.get("supply_enabled", false))


## 军队每日耗粮（现存兵力加伤兵）。
static func daily_food(war, army: Dictionary) -> float:
	return (Combat.strength(army) + int(army.get("wounded", 0))) * float(war.rules["grain_per_soldier_day"])


## 携粮还能支撑的天数；未启用补给时为 999。
static func food_days(war, army: Dictionary) -> float:
	return float(army.get("grain", 0)) / maxf(daily_food(war, army), 0.001) if supply_enabled(war) else 999.0


# 兵员账本：出征兵力必须等于 现存 + 留驻 + 阵亡 + 伤兵 + 被俘 + 溃散。
# 任何一条收束路径漏记都会在这里暴露为非零 missing。
static func ledger(war, army: Dictionary) -> Dictionary:
	var accounted: int = Combat.strength(army) + int(army.get("deposited", 0)) + int(army.get("dead", 0)) + int(army.get("wounded", 0)) + int(army.get("captured", 0)) + int(army.get("dispersed", 0))
	var initial := int(army.get("initial_strength", 0))
	return {"initial": initial, "accounted": accounted, "missing": initial - accounted}


## 每日结算：给养、疲劳与恢复、期限与目标达成后的回师，最后检查溃败。
static func _upkeep(war) -> void:
	for army in war.active_armies():
		Process.end_day(army)
		if army.has("tactical"):
			var terrain := Tactical.terrain_class(army["tactical"]["cell"])
			army["fatigue"] = minf(100, float(army["fatigue"])+float(Terrain.settings(terrain,war.rules).get("daily_fatigue",0)))
		var needed: float = 0
		var provided: float = 0
		if supply_enabled(war):
			needed = daily_food(war, army)
			provided = minf(float(army["grain"]), needed)
			army["grain"] = maxf(0, float(army["grain"]) - provided)
			if provided + 0.001 < needed:
				army["morale"] = maxf(0, float(army["morale"]) - 8)
				army["organization"] = maxf(0, float(army["organization"]) - 5)
				Combat.apply_loss(army, int(ceil(Combat.strength(army) * 0.005)))
				war._report(army, "缺粮", "%s所部携粮耗尽，士气与组织持续下降。" % army["name"], true)
		var resting: bool = int(army.get("combat_tick", -1)) != int(war.state["tick"]) and (str(army["action"]["type"]) in ["hold", "scout", "resupply", "request_support"] or (army.has("tactical") and int(army["tactical"].get("moved_tick", -1)) != int(war.state["tick"])))
		if resting:
			var recovery := Process.recovery(army)
			army["fatigue"] = maxf(0, float(army["fatigue"]) - float(recovery["fatigue"]))
			if provided >= needed:
				army["organization"] = minf(100, float(army["organization"]) + float(recovery["organization"]))
				army["morale"] = minf(100, float(army["morale"]) + float(recovery["morale"]))
		if int(war.state["tick"]) >= int(army["deadline"]):
			army["returning"] = true
			if str(army["outcome"]) == "": army["outcome"] = "任务期限已到"
		if str(army["mission_type"]) == "capture" and not war._has_independent_action(army) and str(war.store.city_state(str(army["target"])).get("faction", "")) == str(army["faction"]) and not bool(army["returning"]) and war.orders_for(army)["after_battle"] == "withdraw":
			army["returning"] = true
			army["outcome"] = "目标已由本方控制"
		if str(army["location"].get("edge", "")) == "" and str(army["location"]["node"]) == str(army["target"]) and not army.has("arrived_at"):
			army["arrived_at"] = int(war.state["tick"])
		if str(army["mission_type"]) == "defend" and army.has("arrived_at") and int(war.state["tick"]) >= int(army["arrived_at"]) + 15 and army["intel"]["enemies"].is_empty():
			army["returning"] = true
			army["outcome"] = "守援完成"
		if bool(army["returning"]) and str(army["location"].get("edge", "")) == "":
			war._start_return(army)
		war._check_rout(army)


## 把城内兵种与伤兵库存对齐到 garrison/wounded 总数。
static func _sync_inventory(war, city: Dictionary) -> void:
	if not city.get("wounded_units") is Dictionary: city["wounded_units"] = {"infantry": int(city.get("wounded", 0)), "archers": 0, "cavalry": 0}
	var wounded_count := 0
	for type in Combat.TYPES:
		city["wounded_units"][type] = maxi(0, int(city["wounded_units"].get(type, 0)))
		wounded_count += int(city["wounded_units"][type])
	if wounded_count < int(city.get("wounded", 0)): city["wounded_units"]["infantry"] += int(city["wounded"]) - wounded_count
	var total: int = int(city.get("garrison", 0))
	if not city.get("units", null) is Dictionary:
		city["units"] = {"infantry": total, "archers": 0, "cavalry": 0}
	var counted: int = 0
	for type in Combat.TYPES:
		city["units"][type] = maxi(0, int(city["units"].get(type, 0)))
		counted += int(city["units"][type])
	if counted < total:
		city["units"]["infantry"] += total - counted
	elif counted > total:
		var excess: int = counted - total
		for type in Combat.TYPES:
			var loss: int = mini(excess, int(city["units"][type]))
			city["units"][type] -= loss
			excess -= loss


## 征兵后按训练与装备把一部分新步兵换成弓兵、骑兵。
static func recruit_units(war, city: Dictionary, count: int) -> void:
	_sync_inventory(war, city)
	# The city's garrison has already increased; replace part of the new infantry.
	var archers: int = int(count * 0.2) if int(city.get("training", 0)) >= 50 else 0
	var cavalry: int = int(count * 0.1) if int(city.get("equipment", 0)) >= 70 else 0
	city["units"]["infantry"] -= archers + cavalry
	city["units"]["archers"] += archers
	city["units"]["cavalry"] += cavalry
