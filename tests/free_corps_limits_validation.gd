extends SceneTree

const Structure = preload("res://scripts/war/campaign/corps_structure.gd")
var failures: Array[String] = []
func _initialize() -> void: call_deferred("run")
func check(ok: bool, message: String) -> void:
	if not ok: failures.append(message); push_error(message)

func run() -> void:
	var members: Array = ["root"]
	var tree: Dictionary = {}
	var plan: Dictionary = {"commander": "root", "members": []}
	for index in range(160):
		var id: String = "officer-%d" % index
		var parent: String = "root" if index == 0 else "officer-%d" % (index - 1)
		members.append(id)
		tree[id] = parent
		plan["members"].append({"id": id, "parent": parent, "role": "玩家自定义的长名称指挥岗位", "strength": 500})
	var corps: Dictionary = {"commander_id": "root", "members": members, "command_tree": tree}
	Structure.ensure(corps)
	check(Structure.depth_of(corps, "officer-159") == 160, "合法深层指挥树被128层限制截断")
	check(Structure.tree_rows(corps).size() == 161, "展开指挥树裁剪成员")
	check(Structure.validate_plan("root", members, plan, 80500).get("ok", false), "合法161人编制不被接受")
	var normalized: Dictionary = Structure.normalize_plan(null, "root", members, plan, 80500)
	check(normalized["roles"]["officer-159"] == "玩家自定义的长名称指挥岗位", "玩家岗位被8字符限制截断")
	check(int(normalized["strengths"]["root"]) == 500, "主帅余兵错误")
	check(not Structure.set_parent(corps, "root", "officer-159").get("ok", true), "主帅根节点可被挂入下级形成环")
	check(not Structure.set_parent(corps, "officer-0", "officer-159").get("ok", true), "深层循环未被拒绝")
	check(not Structure.validate_plan("root", members, plan, 80499).get("ok", true), "超额兵力分配未被拒绝")
	plan["members"][0]["strength"] = -500
	check(not Structure.validate_plan("root", members, plan, 80500).get("ok", true), "负数兵力未被拒绝")
	plan["members"][0]["strength"] = 100
	check(not Structure.validate_plan("root", members, plan, 80500).get("ok", true), "不足独立分队最低兵力未被拒绝")
	plan["members"][0]["strength"] = 500
	plan["members"][0]["parent"] = "foreign"
	check(not Structure.validate_plan("root", members, plan, 80500).get("ok", true), "外部上级未被拒绝")
	if failures.is_empty(): print("FREE_CORPS_LIMITS_OK: 161 members, 160-level tree, long custom role, root/cycle/foreign-parent/invalid-troop rejection")
	quit(0 if failures.is_empty() else 1)
