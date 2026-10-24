extends SceneTree

# 自由编制专用验证：>6人、多级指挥树、非法循环/跨军团拒绝、每节点兵力、
# 旧存档兼容（不裁人）、存读档往返。禁止固定六人上限。

const Corps = preload("res://scripts/war/army_corps.gd")
const Structure = preload("res://scripts/war/corps_structure.gd")
var failures: Array[String] = []

func _initialize() -> void: call_deferred("run")

func check(value: bool, message: String) -> void:
	if not value: failures.append(message); push_error(message)

func ledger(war, corps: Dictionary) -> Array:
	var total := [0, 0.0, 0, 0, 0]
	for id in corps["units"]:
		var army: Dictionary = war.state["armies"][id]
		if army["status"] == "ended": continue
		total[0] += war.Combat.strength(army)
		total[1] += float(army["grain"])
		total[2] += int(army["dead"])
		total[3] += int(army["wounded"])
		total[4] += int(army["captured"])
	return total

func run() -> void:
	var store: Node = root.get_node("GameState")
	store.persist_enabled = false
	store.agent.enabled = false
	store._load_demo()
	var war = store.war
	var city: Dictionary = store.city_state("luoyang")
	city.merge({"faction": "liu_bei", "garrison": 30000, "units": {"infantry": 30000, "archers": 0, "cavalry": 0}}, true)
	var leaders: Array = war.available_officers("liu_bei").map(func(o): return o["id"])
	var commander: String = ""
	if not leaders.is_empty(): commander = Corps.best_member(war, leaders, "主帅")
	check(commander != "", "演示剧本缺少可用主帅")
	var companions: Array = []
	for id in leaders:
		if str(id) == commander or companions.size() >= 9: continue
		if war.Operations.assembly_days(war, "luoyang", [id]) < 0: continue
		companions.append(str(id))
	check(companions.size() >= 6, "可用随军武将不足6人（%d），无法验证>6编制" % companions.size())
	if commander == "" or companions.size() < 6:
		quit(1)
		return
	# 自由编制方案：>6名成员、自定义岗位、三级指挥树、每节点兵力。
	var plan := {"commander": commander, "members": []}
	var role_list := ["帐下都督", "先锋", "前锋", "护军", "参军", "军师", "校尉", "督粮", "随军"]
	for index in range(companions.size()):
		var role: String = role_list[index] if index < role_list.size() else "随军"
		plan["members"].append({"id": companions[index], "role": role, "parent": commander, "strength": 0})
	# 三级链：2 -> 1 -> 0 -> 主帅
	plan["members"][1]["parent"] = companions[0]
	plan["members"][2]["parent"] = companions[1]
	var maximum := int(war.preview_dispatch("luoyang", "hongnong", commander).get("maximum", 0))
	check(maximum >= 5000, "洛阳可动员兵力不足：%d" % maximum)
	var strength := maximum
	var troop_indices: Array = []
	for index in [0, 1, 2, 3, 6, 7, 8]:
		if index < companions.size(): troop_indices.append(index)
	var share := maxi(500, int(strength / 8.0))
	for index in range(companions.size()):
		plan["members"][index]["strength"] = share if troop_indices.has(index) else 0
	war.state["pending_corps_plan"] = plan
	var preview: Dictionary = war.preview_dispatch("luoyang", "hongnong", commander, false, strength)
	check(preview.get("ok", false), "自由编制出征预览失败：" + str(preview.get("message", "")))
	if not preview.get("ok", false):
		war.state.erase("pending_corps_plan")
		quit(1)
		return
	strength = int(preview["strength"])
	var result: Dictionary = war.dispatch("luoyang", "hongnong", commander, companions, true, strength)
	check(result.get("ok", false), "自由编制出征失败：" + str(result.get("message", "")))
	if not result.get("ok", false):
		quit(1)
		return
	var root_army: Dictionary = war.state["armies"][result["army_id"]]
	var corps: Dictionary = war.state["corps"][root_army["corps_id"]]
	var member_count: int = corps["members"].size()
	check(member_count > 6, "自由编制仍被人为限员：%d 人" % member_count)
	check(member_count == 1 + companions.size(), "方案成员未被完整保留：%d/%d" % [member_count, 1 + companions.size()])
	check(corps["appointments"].size() == member_count, "存在未任职成员")
	check(str(corps["appointments"].get(companions[0], "")) == "帐下都督", "自定义岗位未生效")
	check(Structure.depth_of(corps, companions[2]) == 3, "指挥层级不是3级：%d" % Structure.depth_of(corps, companions[2]))
	check(Structure.depth_of(corps, companions[1]) == 2, "指挥层级不是2级：%d" % Structure.depth_of(corps, companions[1]))
	# 非法循环：把链首的上级设为其孙辈，必须拒绝且不破坏结构。
	var cycle: Dictionary = Structure.set_parent(corps, companions[0], companions[2])
	check(not cycle.get("ok", false) and str(cycle.get("reason", "")) == "would_cycle", "非法循环未被拒绝：%s" % str(cycle))
	check(Structure.depth_of(corps, companions[0]) == 1, "循环校验后结构被破坏")
	# 非法跨军团上级：不在随军名单内必须拒绝。
	var foreign: Dictionary = Structure.set_parent(corps, companions[0], "not-in-corps")
	check(not foreign.get("ok", false) and str(foreign.get("reason", "")) == "parent_not_in_corps", "跨军团上级未被拒绝：%s" % str(foreign))
	# 每节点兵力落地与总兵力守恒。
	check(int(corps["node_strength"].get(companions[0], 0)) == share, "节点兵力未按方案分配")
	var staff: String = companions[4]
	var staff_has_unit := false
	var total := 0
	for id in corps["units"]:
		var army: Dictionary = war.state["armies"][id]
		if army["status"] == "ended": continue
		total += war.Combat.strength(army)
		if str(army["officer_id"]) == staff: staff_has_unit = true
	check(total == strength, "自由编制总兵力不守恒：%d != %d" % [total, strength])
	check(not staff_has_unit, "无兵参军被分配了分队")
	check(int(corps["units"].size()) >= 7, "独立分队数量少于分配节点：%d" % corps["units"].size())
	# 旧存档：抹去自由编制字段后迁移，成员/兵力/伤兵/粮草必须守恒，且不得压缩回6人。
	var before := ledger(war, corps)
	corps.erase("composition_version")
	corps.erase("command_tree")
	corps.erase("node_strength")
	corps.erase("refusals")
	Corps.migrate(war, corps)
	check(int(corps.get("composition_version", 0)) == Structure.STRUCTURE_VERSION, "旧档未升级到自由编制结构")
	check(corps["members"].size() == member_count, "旧档迁移改变了成员数：%d -> %d" % [member_count, corps["members"].size()])
	check(ledger(war, corps) == before, "旧档迁移丢失兵员、伤兵或粮草")
	check(Structure.depth_of(corps, companions[0]) >= 1, "旧档迁移后指挥树缺失")
	# 迁移后重设三级指挥树，验证存档往返完整保留层级。
	check(Structure.set_parent(corps, companions[1], companions[0]).get("ok", false), "迁移后无法重设上级")
	check(Structure.set_parent(corps, companions[2], companions[1]).get("ok", false), "迁移后无法重设二级上级")
	check(Structure.depth_of(corps, companions[2]) == 3, "迁移后重设的层级不正确")
	# 存档往返：>6人与三级指挥树保持。
	var saved: Dictionary = war.export_state()
	war.setup(store, saved)
	var reloaded: Dictionary = war.state["corps"][corps["id"]]
	check(reloaded["members"].size() > 6, "存档重读后自由编制丢失：%d 人" % reloaded["members"].size())
	check(Structure.depth_of(reloaded, companions[2]) == 3, "存档重读后指挥树丢失")
	if failures.is_empty():
		print("FREE_CORPS_STRUCTURE_OK: %d members (>6), 3-level tree, cycle/cross-corps rejection, per-node strength, legacy keep-all migration, save round trip" % member_count)
	quit(0 if failures.is_empty() else 1)
