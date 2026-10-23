class_name BattleSides
extends RefCounted
## 战场分边：按数据声明的参战势力把名册里的人分到各方，并定主帅。
##
## 声明格式（每方一项）：{"faction": 势力 id, "role": "defender" | "attacker", "leader": 人物 id 或 ""}。
## 人物归哪方只看名册里的 faction（名册建立时已由人物卡的 faction_id 或 faction_mapping 换算成势力 id），
## 不改任何人的势力；未声明的势力不参战。
##
## 一方没有人物卡武将时，用名册里该势力的生成将补位（filled = true）并给出告警；
## 生成将也没有时返回 error，sides 为空，调用方不得开战。

## 返回 {"sides": [{faction, role, members, leader, filled}], "warnings": [String], "error": String}。
## pick_leader(members: Array) -> String 在声明的主帅缺省或不在本方时择帅。
static func plan(officers: Dictionary, declared: Array, pick_leader: Callable) -> Dictionary:
	var error := _check(declared)
	if not error.is_empty(): return {"sides": [], "warnings": [], "error": error}
	var sides: Array = []
	var warnings: Array = []
	for spec in declared:
		var faction := str(spec["faction"])
		var named: Array = []
		var generated: Array = []
		for officer in officers.values():
			var id := str(officer["id"])
			if str(officer.get("faction", "")) != faction or id.begins_with("militia:"): continue
			(generated if officer.get("generated", false) else named).append(id)
		var members: Array = named if not named.is_empty() else generated
		if members.is_empty():
			return {"sides": [], "warnings": warnings, "error": "参战势力 %s 名册里没有任何武将（人物卡与生成将都没有），不能开战" % faction}
		if named.is_empty(): warnings.append("参战势力 %s 没有人物卡武将，用 %d 名生成将补位" % [faction, members.size()])
		var leader := str(spec.get("leader", ""))
		if not members.has(leader):
			if not leader.is_empty(): warnings.append("声明的主帅 %s 不在 %s 方，改由本方择帅" % [leader, faction])
			leader = str(pick_leader.call(members))
		sides.append({"faction": faction, "role": str(spec["role"]), "members": members, "leader": leader, "filled": named.is_empty()})
	return {"sides": sides, "warnings": warnings, "error": ""}


## 声明本身的错误：要恰好一守一攻，势力不重复。
static func _check(declared: Array) -> String:
	var roles: Array = declared.map(func(spec): return str(spec.get("role", "")))
	roles.sort()
	if roles != ["attacker", "defender"]: return "参战声明须恰好一方 defender、一方 attacker：%s" % str(roles)
	var factions: Array = declared.map(func(spec): return str(spec.get("faction", "")))
	if factions[0] == factions[1] or factions.has(""): return "参战双方须是两个不同的势力：%s" % str(factions)
	return ""
