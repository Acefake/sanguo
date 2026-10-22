@abstract
class_name TacticalTargeting
extends "res://scripts/war/battle/tactical_battlefield/board.gd"
## 战术目标与接触：射程、可见目标排序（按日缓存）、锁定目标、接敌状态、敌方控制区（按日缓存）、破城入城落点。


## 两支部队的格距；不在同一战场时为 10000。
static func distance(a: Dictionary, b: Dictionary) -> int:
	if not a.has("tactical") or not b.has("tactical") or str(a.get("battlefield_id", "")) != str(b.get("battlefield_id", "")): return 10000
	return cell_distance(int(a["tactical"]["cell"]), int(b["tactical"]["cell"]))


## 攻击距离：弓兵 2，其余 1。
static func attack_range(army: Dictionary) -> int:
	return 2 if preload("res://scripts/war/battle/troop_roles.gd").kind(army) == "archers" else 1


# Observed enemies, nearest first. Called four to six times per attacker per day from
# ordered_target/move/resolve and again from army_corps, always for the same tick, so
# the result is memoised per (tick, army).
static var _target_cache: Dictionary = {}


static func targets(war, army: Dictionary) -> Array:
	var key := "%d:%d:%s" % [war.get_instance_id(), int(war.state[StateKeys.TICK]), str(army["id"])]
	if _target_cache.has(key):
		return _target_cache[key].filter(func(enemy): return enemy.get("status", "") != "ended" and not enemy.get("tactical",{}).get("placement_invalid",false) and distance(army, enemy) < 10000 and _seen_now(war,army,enemy) and not shield_between(war,army,enemy))
	var result: Array = []
	for enemy in war.active_armies():
		if war.hostile(str(enemy["faction"]), str(army["faction"])) and _seen_now(war,army,enemy) and enemy.has("tactical") and not enemy.get("tactical",{}).get("placement_invalid",false) and distance(army, enemy) < 10000 and not shield_between(war,army,enemy):
			result.append(enemy)
	result.sort_custom(func(a, b):
		var left := _target_priority(war,army,a)
		var right := _target_priority(war,army,b)
		return left > right if not is_equal_approx(left,right) else str(a["id"]) < str(b["id"]))
	_target_cache[key] = result
	return result


static func _seen_now(war, army: Dictionary, enemy: Dictionary) -> bool:
	return int(army.get("intel",{}).get("enemies",{}).get(enemy["id"],{}).get("observed_at",-1)) == int(war.state[StateKeys.TICK])


static func _is_commander(war, army: Dictionary) -> bool:
	return war.state.get(StateKeys.CORPS,{}).get(army.get("corps_id",""),{}).get("root_id","") == army["id"]


static func _target_priority(war, army: Dictionary, enemy: Dictionary) -> float:
	var gap := distance(army,enemy)
	# Handle an adjacent threat before shooting past it. Within that tier prefer
	# an exposed commander, then a recent attacker or a favorable troop matchup.
	var score := 1000.0 if gap == 1 else 500.0 if gap <= attack_range(army) else -float(gap)*10.0
	if gap <= attack_range(army):
		if _is_commander(war,enemy): score += 60
		if army.get("last_enemy_id","") == enemy["id"] and int(war.state[StateKeys.TICK])-int(army.get("last_enemy_tick",-10)) <= 2: score += 18
		if army.get("tactical",{}).get("attack_target","") == enemy["id"]: score += 12
		var known: Dictionary = army["intel"]["enemies"][enemy["id"]]
		var estimate := float(known.get("strength_estimate",10000))
		if estimate < Combat.strength(army)*0.4: score += 10
		if preload("res://scripts/war/battle/troop_roles.gd").kind(army) == "cavalry" and float(known.get("unit_mix_estimate",{}).get("archers",0)) > estimate*0.6: score += 22
	return score


## 清空按日缓存的目标列表（每回合移动和结算开始时调用）。
static func clear_target_cache() -> void:
	_target_cache.clear()


## 本回合该军要攻击的目标：接触中的旧目标优先，否则保留短期锁定，再否则取排序第一。
static func ordered_target(war, army: Dictionary) -> Dictionary:
	var available := targets(war, army)
	if available.is_empty(): return {}
	var tactical: Dictionary = army["tactical"]
	# Contact has priority; otherwise keep an observed target for a short order.
	# Merely becoming one tile nearer does not justify crossing another unit's line.
	var previous: Dictionary = war.state[StateKeys.ARMIES].get(tactical.get("attack_target", ""), {})
	if not previous.is_empty() and previous["status"] != "ended" and war.hostile(str(previous["faction"]), str(army["faction"])) and _seen_now(war,army,previous):
		if distance(army, previous) <= attack_range(army) and _target_priority(war,army,previous) >= _target_priority(war,army,available[0]): return previous
		if distance(army, available[0]) > attack_range(army) and int(war.state[StateKeys.TICK]) < int(tactical.get("target_until", 0)): return previous
	var selected: Dictionary = available[0]
	if selected["id"] != tactical.get("attack_target", ""):
		tactical["target_until"] = int(war.state[StateKeys.TICK]) + 4
	return selected


## 该军当前的接敌情况：是否被夹击、接敌部队、掩护数、撤离所需准备回合。
static func contact_state(war, army: Dictionary) -> Dictionary:
	# Positions, assignments and returns can change within the same campaign day.
	# Contact is a current rule query, not a day-level observation cache.
	var attackers: Array = []
	var cover := 0
	for other in participants(war):
		if other["id"] == army["id"] or not other.has("tactical") or distance(army, other) > 1: continue
		if shield_between(war, army, other): continue
		if war.hostile(str(other["faction"]), str(army["faction"])) and not bool(other["returning"]) and bool(war.orders_for(other)["engage"]): attackers.append(other["id"])
		elif other["faction"] == army["faction"] and not bool(other["returning"]) and other.get("operation", {}).get("role", "") == "rear_guard": cover += 1
	var flanked := false
	for first in attackers:
		for second in attackers:
			if first != second and distance(war.state[StateKeys.ARMIES][first], war.state[StateKeys.ARMIES][second]) >= 2: flanked = true
	# One rear-guard cancelled the whole penalty regardless of how many attackers there
	# were, so the second and third rear-guard units were dead weight. Cover now offsets
	# one attacker each, capped so it can never make disengaging free.
	return {"flanked": flanked, "engaged_by": attackers, "adjacent_enemies": attackers.size(), "covered_by": cover, "required_preparation": maxi(1, 1 + maxi(0, attackers.size() - cover))}


static func _enemy_control(war, army: Dictionary) -> Dictionary:
	var key := "%d:%d:%s" % [war.get_instance_id(), int(war.state[StateKeys.TICK]), str(army["id"])]
	if _enemy_control_cache.has(key):
		return _enemy_control_cache[key]
	var result := _cached_enemy_control(war, army)
	_enemy_control_cache[key] = result
	return result


static func _cached_enemy_control(war, army: Dictionary) -> Dictionary:
	var controlled := {}
	for enemy in participants(war):
		if not war.hostile(str(enemy["faction"]), str(army["faction"])) or bool(enemy["returning"]) or not enemy.has("tactical") or not bool(war.orders_for(enemy)["engage"]): continue
		if shield_between(war, army, enemy): continue
		for cell in neighbors(int(enemy["tactical"]["cell"])): controlled[cell] = true
	return controlled


static func _enemy_control_cache_clear() -> void:
	_enemy_control_cache.clear()


static var _enemy_control_cache: Dictionary = {}


# 破口开放后，非弓兵部队从缺口入城：先走缺口外侧落点，再进缺口格；
# 已入城则向城心推进。城内其余格仍由 blocked_for 控制，通道只在破口走廊。
# 返回 -1 表示保持原有城下位置（尚未破城或该兵种应留在城下）。
static func siege_entry_goal(war, army: Dictionary, board: Dictionary) -> int:
	if attack_range(army) > 1: return -1
	var node := str(army["target"])
	var breach: int = Defense.breach_cell(war, node)
	if breach < 0: return -1
	var legal: Dictionary = Fort.movement_board(war, board, str(army["faction"]))
	var start := int(army["tactical"]["cell"])
	if Fort.inside_city(board, start) == node:
		var center := int(board.get("objectives", {}).get(node, breach))
		return center if in_battlefield(legal, center) else start
	if not in_battlefield(legal, breach): return -1
	if cell_distance(start, breach) <= 1: return breach
	# 城外远处：先到缺口外侧的落点，避免直线穿墙导致寻路卡死。
	var outside := -1
	var best := 10000
	for neighbor in neighbors(breach):
		var cell := int(neighbor)
		if not in_battlefield(legal, cell) or Fort.inside_city(board, cell) != "": continue
		var gap := cell_distance(start, cell)
		if gap < best:
			best = gap
			outside = cell
	return outside if outside >= 0 else breach
