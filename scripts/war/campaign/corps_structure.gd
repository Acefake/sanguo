extends RefCounted

# 自由军团编制：自定义岗位、指挥树（上级/下级）、按节点分配兵力。
# 不设人数硬上限：编制只受现实资源约束（可用将领、集结通道、总兵力与最小分队500人）。
# 旧存档（composition_version < 3）由 army_corps.migrate 升级到本结构，不裁撤任何成员或兵力。

const STRUCTURE_VERSION := 3
const MIN_TROOP := 500
const COMMANDER_ROLE := "主帅"
const DEPUTY_ROLE := "代理主帅"
const ATTACHED_ROLE := "随军"
const STAFF_ROLE := "参军"

# 可自由填写；这些只是 UI 快捷建议，不构成合法岗位白名单。
const SUGGESTED_ROLES := ["主帅", "代理主帅", "副将", "前锋", "护军", "参军", "军师", "都督", "统领", "校尉", "督粮", "随军"]

# 岗位行为归类：指挥/参谋/前锋/护军/其他。自由岗位按关键词归类，未知岗位按普通部将处理。
static func behavior_of(role: String) -> String:
	var text := role.strip_edges()
	if text.is_empty(): return "subordinate"
	match text:
		"主帅", "代理主帅", "都督", "统帅", "总指挥", "大都督": return "command"
		"参军", "军师", "主簿", "司马", "长史", "从事", "军需", "祭酒": return "staff"
		"前锋", "先锋", "陷阵", "奇兵", "突骑", "敢死": return "front"
		"护军", "护卫", "中军", "亲卫", "大营": return "guard"
	if text.contains("参军") or text.contains("军师") or text.contains("主簿") or text.contains("军需") or text.contains("谋士") or text.contains("从事") or text.contains("司马") or text.contains("长史"):
		return "staff"
	if text.contains("前锋") or text.contains("先锋") or text.contains("陷阵") or text.contains("奇"):
		return "front"
	if text.contains("护") or text.contains("卫") or text.contains("中军") or text.contains("大营"):
		return "guard"
	if text.contains("主帅") or text.contains("都督") or text.contains("统帅"):
		return "command"
	return "subordinate"

static func is_staff(role: String) -> bool:
	return behavior_of(role) == "staff"

static func is_commander(role: String) -> bool:
	return behavior_of(role) == "command"

# 补齐结构字段；对任何军团字典幂等可用（旧档、测试夹具、手工构造的军团都适用）。
static func ensure(corps: Dictionary) -> void:
	if not corps.get("appointments") is Dictionary: corps["appointments"] = {}
	if not corps.get("command_tree") is Dictionary: corps["command_tree"] = {}
	if not corps.get("node_strength") is Dictionary: corps["node_strength"] = {}
	if not corps.get("refusals") is Dictionary: corps["refusals"] = {}
	var commander := str(corps.get("commander_id", ""))
	var members: Array = corps.get("members", [])
	for value in members:
		var id := str(value)
		if not corps["appointments"].has(id):
			corps["appointments"][id] = COMMANDER_ROLE if id == commander else ATTACHED_ROLE
		if not corps["node_strength"].has(id): corps["node_strength"][id] = 0
	if not commander.is_empty() and not corps["appointments"].has(commander):
		corps["appointments"][commander] = COMMANDER_ROLE
	corps["node_strength"][commander] = int(corps["node_strength"].get(commander, 0))
	for value in members:
		var id := str(value)
		if id == commander: continue
		if not corps["command_tree"].has(id): corps["command_tree"][id] = commander
	for id in corps["command_tree"].keys():
		if id == commander or not members.has(id):
			corps["command_tree"].erase(id)
			continue
		var parent := str(corps["command_tree"][id])
		if parent != commander and not members.has(parent) and parent != "":
			corps["command_tree"][id] = commander
	for value in members:
		var id := str(value)
		if id == commander or not corps["command_tree"].has(id): continue
		if depth_of(corps, id) < 0: corps["command_tree"][id] = commander

# 返回上级指派不合法原因；空串表示合法。
static func parent_reason(corps: Dictionary, officer: String, parent: String) -> String:
	var members: Array = corps.get("members", [])
	if officer.is_empty() or not members.has(officer): return "not_in_corps"
	if officer == str(corps.get("commander_id", "")): return "commander_root"
	if parent.is_empty(): return "missing_parent"
	if not members.has(parent): return "parent_not_in_corps"
	if parent == officer: return "self_parent"
	# 沿上级链上溯：能回到 officer 说明新边会闭环。
	var cursor := parent
	var seen := {}
	var tree: Dictionary = corps.get("command_tree", {})
	var steps := 0
	while not cursor.is_empty():
		if cursor == officer: return "would_cycle"
		if seen.has(cursor): return "existing_cycle"
		seen[cursor] = true
		steps += 1
		if not tree.has(cursor): return ""
		cursor = str(tree[cursor])
	return ""

static func set_parent(corps: Dictionary, officer: String, parent: String) -> Dictionary:
	var reason := parent_reason(corps, officer, parent)
	if not reason.is_empty(): return {"ok": false, "reason": reason}
	if not corps.get("command_tree") is Dictionary: corps["command_tree"] = {}
	corps["command_tree"][officer] = parent
	return {"ok": true, "reason": ""}

# 指挥层级深度；0=主帅；负数表示检测到环（非法结构）。
static func depth_of(corps: Dictionary, officer: String) -> int:
	var tree: Dictionary = corps.get("command_tree", {})
	var cursor := officer
	var seen := {}
	var depth := 0
	while tree.has(cursor):
		if seen.has(cursor): return -1
		seen[cursor] = true
		cursor = str(tree[cursor])
		depth += 1
	return depth

# 按指挥树广度优先展开成员（父先于子），用于面板显示与测试断言。
static func tree_rows(corps: Dictionary) -> Array:
	var commander := str(corps.get("commander_id", ""))
	var members: Array = corps.get("members", [])
	var tree: Dictionary = corps.get("command_tree", {})
	var kids := {}
	for value in members:
		var id := str(value)
		if id == commander: continue
		var parent := str(tree.get(id, commander))
		if parent == "" or (not members.has(parent) and parent != commander) or parent == id: parent = commander
		if not kids.has(parent): kids[parent] = []
		kids[parent].append(id)
	for key in kids.keys():
		kids[key].sort()
	var rows: Array = []
	var seen := {}
	var queue: Array = [[commander, 0]]
	while not queue.is_empty():
		var entry: Array = queue.pop_front()
		var id := str(entry[0])
		var depth := int(entry[1])
		if id.is_empty() or seen.has(id): continue
		seen[id] = true
		rows.append({"id": id, "depth": depth})
		for child in kids.get(id, []):
			if seen.has(child): continue
			queue.append([str(child), depth + 1])
	for value in members:
		var id := str(value)
		if not seen.has(id): rows.append({"id": id, "depth": 0})
	return rows

# 将玩家/UI 的编制方案规范化到实际随军名单：过滤非法成员，修岗位、上级与兵力分配。
# 兵力分配只受两个现实约束：每支独立分队至少 MIN_TROOP；主帅至少保留 MIN_TROOP。
static func normalize_plan(war, commander: String, member_ids: Array, plan: Dictionary, strength: int) -> Dictionary:
	var entries: Array = []
	var seen := {}
	for value in plan.get("members", []):
		if not value is Dictionary: continue
		var id := str(value.get("id", ""))
		if id.is_empty() or id == commander or seen.has(id) or not member_ids.has(id): continue
		seen[id] = true
		entries.append(value)
	for value in member_ids:
		var id := str(value)
		if id == commander or seen.has(id): continue
		seen[id] = true
		entries.append({"id": id})
	var roles := {commander: COMMANDER_ROLE}
	var parents := {}
	var strengths := {commander: int(strength)}
	var budget := maxi(0, int(strength) - MIN_TROOP)
	for value in entries:
		var id := str(value.get("id", ""))
		var role := str(value.get("role", ATTACHED_ROLE)).strip_edges()
		if role.is_empty(): role = ATTACHED_ROLE
		roles[id] = role
		var parent := str(value.get("parent", commander))
		if parent.is_empty(): parent = commander
		parents[id] = parent
		var count := int(value.get("strength", 0))
		if count < MIN_TROOP: count = 0
		count = mini(count, budget)
		budget -= count
		strengths[id] = count
	strengths[commander] = int(strength) - (maxi(0, int(strength) - MIN_TROOP) - budget)
	# 上级必须落在随军名单内且不能闭环；不合法的直接挂到主帅。
	var probe := {"members": member_ids, "command_tree": parents, "commander_id": commander}
	for id in parents.keys():
		var reason := parent_reason(probe, str(id), str(parents[id]))
		if reason in ["parent_not_in_corps", "self_parent", "would_cycle", "existing_cycle", "missing_parent"]:
			parents[id] = commander
	for value in member_ids:
		var id := str(value)
		if id == commander or not parents.has(id): continue
		if depth_of(probe, id) < 0: parents[id] = commander
	return {"roles": roles, "parents": parents, "strengths": strengths, "budget": maxi(0, int(strength) - MIN_TROOP)}

static func tree_parent(corps: Dictionary, officer: String) -> String:
	var tree: Dictionary = corps.get("command_tree", {})
	if not tree.has(officer): return str(corps.get("commander_id", ""))
	return str(tree[officer])

static func children_of(corps: Dictionary, officer: String) -> Array:
	var result: Array = []
	var tree: Dictionary = corps.get("command_tree", {})
	for value in corps.get("members", []):
		var id := str(value)
		if id == officer: continue
		if str(tree.get(id, "")) == officer: result.append(id)
	result.sort()
	return result

# Reject invalid player input before deployment; never silently trim allocations.
static func validate_plan(commander: String, members: Array, plan: Dictionary, strength: int) -> Dictionary:
	if str(plan.get("commander", commander)) != commander: return {"ok": false, "message": "编制主帅不匹配"}
	var tree: Dictionary = {}
	var seen: Dictionary = {}
	var allocated: int = 0
	for value in plan.get("members", []):
		if not value is Dictionary: return {"ok": false, "message": "编制节点无效"}
		var id: String = str(value.get("id", ""))
		if id == commander or not members.has(id) or seen.has(id): return {"ok": false, "message": "成员不可用或重复"}
		seen[id] = true
		tree[id] = str(value.get("parent", commander))
		var count: int = int(value.get("strength", 0))
		if count < 0 or (count > 0 and count < MIN_TROOP): return {"ok": false, "message": "独立分队至少%d人，无兵节点填0" % MIN_TROOP}
		allocated += count
	if allocated > strength - MIN_TROOP: return {"ok": false, "message": "分配兵力超过总兵力，主帅至少保留%d人" % MIN_TROOP}
	var probe: Dictionary = {"members": members, "commander_id": commander, "command_tree": tree}
	for id in tree:
		if not parent_reason(probe, str(id), str(tree[id])).is_empty(): return {"ok": false, "message": "上级不在编制内或指挥关系成环"}
	return {"ok": true}
