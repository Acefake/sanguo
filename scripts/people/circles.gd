class_name PeopleCircles
extends RefCounted
## 圈子成员解析（04-关系与圈子）。P1 只实现成员查询，供开局记忆和校验用；传播与派系在 P3。
##
## 圈子定义来自 data/people/circles.json：要么列出 members，要么给 members_rule（按出身郡、出身阶层筛选）。
## 规则只对在场人物（有 PersonState 的人）求值；不在场人物只能靠显式 members 入圈。不写任何状态。


## 圈子成员 id，显式名单按文件顺序，规则成员按 persons 的插入顺序。
static func members(circle: Dictionary, persons: Dictionary) -> Array[String]:
	var out: Array[String] = []
	if circle.has("members"):
		out.assign(circle["members"])
		return out
	var rule: Dictionary = circle.get("members_rule", {})
	for id in persons:
		if matches_rule(rule, persons[id].origin): out.append(id)
	return out


## 出身是否满足 members_rule：origin.commandery / origin.commandery_in / origin.class_in，全部条件都要满足。
static func matches_rule(rule: Dictionary, origin: Dictionary) -> bool:
	var commandery := str(origin.get("commandery", ""))
	if rule.has("origin.commandery") and commandery != str(rule["origin.commandery"]): return false
	if rule.has("origin.commandery_in") and commandery not in rule["origin.commandery_in"]: return false
	if rule.has("origin.class_in") and str(origin.get("class", "")) not in rule["origin.class_in"]: return false
	return true
