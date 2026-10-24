extends SceneTree
const Roles = preload("res://scripts/war/campaign/army_command_roles.gd")
var failures: Array[String] = []
func check(value: bool, text: String) -> void:
	if not value: failures.append(text); push_error(text)
func _initialize() -> void: call_deferred("run")
func run() -> void:
	var store: Node = root.get_node("GameState")
	store.persist_enabled = false
	store.agent.enabled = false
	store.prepare_battle_test(true, "plains_clash", 42)
	var war = store.war
	var corps: Dictionary = war.state["corps"].values()[0]
	var army: Dictionary = war.state["armies"][corps["root_id"]]
	var staff: String = war.Corps.staff_advice(war, corps)["officer_id"]
	check(Roles.resolve(war, army)["commander"]["id"] == army["officer_id"], "旧档主将")
	check(Roles.resolve(war, army)["deputy"].is_empty(), "缺失副将")
	check(Roles.set_deputy(war, army, staff)["ok"], "随军任命")
	var roles := Roles.resolve(war, army)
	check(roles["deputy"]["id"] == staff and not roles["deputy"]["can_command"], "副将权限")
	check(Roles.role_text(roles["deputy"], "副将").contains(roles["deputy"]["name"]), "界面姓名")
	check(not Roles.set_deputy(war, army, army["officer_id"])["ok"], "主副同人")
	check(not Roles.set_deputy(war, army, "missing")["ok"], "无效军官")
	for other in war.active_armies():
		if other["id"] == army["id"]: continue
		check(not Roles.set_deputy(war, army, other["officer_id"])["ok"], "拒绝独立带队或敌方")
	war.state["armies"]["role-duplicate"] = {"id": "role-duplicate", "officer_id": "missing", "status": "active", "command_roles": {"deputy_id": staff}}
	check(not Roles.set_deputy(war, army, staff)["ok"] and Roles.resolve(war, army)["deputy"].is_empty(), "副将重复任职")
	war.state["armies"].erase("role-duplicate")
	war.state["officer_states"][staff]["army_id"] = "other"
	check(Roles.resolve(war, army)["deputy"].is_empty(), "移动部署归属后角色撤去")
	war.state["officer_states"][staff]["army_id"] = army["id"]
	check(roles["commander"]["stats"].has("军事") and roles["deputy"]["skills"].has("智计"), "真实属性和技能")
	for status in ["dead", "captured", "wounded"]:
		war.state["officer_fates"][staff] = {"status": status}
		check(Roles.resolve(war, army)["deputy"].is_empty(), "失效副将:" + status)
		check(army["command_roles"]["deputy_id"] == staff, "配置保留")
	war.state["officer_fates"].erase(staff)
	war.state["officer_states"][staff]["duel_wounded"] = true
	check(Roles.resolve(war, army)["deputy"].is_empty(), "单挑负伤")
	war.state["officer_states"][staff].erase("duel_wounded")
	war.rules["command_roles"] = {"enabled": false}
	check(not Roles.resolve(war, army)["enabled"], "全局开关")
	check(Roles.set_deputy(war, army, "")["ok"], "关闭可清空")
	war.rules["command_roles"]["enabled"] = true
	army["command_roles"]["enabled"] = false
	check(not Roles.resolve(war, army)["enabled"], "部队开关")
	army["command_roles"].erase("enabled")
	var chief: String = army["officer_id"]
	army["officer_id"] = "missing"
	check(Roles.resolve(war, army)["commander"].is_empty(), "缺失主将安全")
	army["officer_id"] = chief
	check(corps["members"].size() == 6, "编制仍六人")
	if failures.is_empty(): print("ARMY_COMMAND_ROLES_OK")
	quit(0 if failures.is_empty() else 1)
