extends SceneTree
const F = preload("res://scripts/war/battle_formation.gd")
const C = preload("res://scripts/war/combat_system.gd")
const War = preload("res://scripts/war/campaign_state.gd")
var failures: Array[String] = []
func _initialize(): call_deferred("run")
func check(ok: bool, message: String):
	if not ok: failures.append(message); push_error(message)
func run():
	var store = root.get_node("GameState")
	store.persist_enabled = false
	store.prepare_battle_test(true)
	var war = store.war
	var corps: Dictionary = war.state["corps"].values()[0]
	var root_army: Dictionary = war.state["armies"][corps["root_id"]]
	var baseline := C.power(root_army,war.rules,"plains")
	F.set_initial(war,corps,"fish_scale")
	check(C.power(root_army,war.rules,"plains") > baseline,"鱼鳞没有加强正面攻击")
	var plain := root_army.duplicate(true)
	plain["formation"] = "none"
	check(F.received(root_army,"plains",false,true) > F.received(plain,"plains",false,true),"鱼鳞被侧击没有付出代价")
	check(F.proficiency({"skills":{"布阵":100}}) > F.proficiency({"skills":{"布阵":50}}),"熟练度没有属性差异")
	for definition in F.definitions(war.rules):
		var example := plain.duplicate(true)
		example["formation"] = definition
		check(F.attack(example,false,war.rules) > 0 and F.received(example,"plains",false,false,war.rules) > 0,"阵型倍率无效")
	var example := plain.duplicate(true)
	example["formation"] = "wild_goose"
	check(F.attack(example,true,war.rules) > F.attack(example,false,war.rules) and F.received(example,"plains",false,false,war.rules) > 1,"雁行没有远射优势或近战代价")
	example["formation"] = "arrowhead"
	example["formation_contact_days"] = 2
	var opening := F.attack(example,false,war.rules)
	example["formation_contact_days"] = 3
	check(F.attack(example,false,war.rules) < opening,"锋矢第三日仍然保持冲击加成")
	example["formation"] = "long_snake"
	example["tactical"]["terrain_delay"] = "mountains"
	check(F.received(example,"forest",false,false,war.rules) < 1 and war.Terrain.entry_factor(example,war.rules) == 1,"长蛇山林防护或迟滞免疫未生效")
	example["tactical"]["terrain_delay"] = "ford"
	check(war.Terrain.entry_factor(example,war.rules) == 0,"长蛇错误绕过渡河禁止攻击")
	var org: float = root_army["organization"]
	check(F.change(war,corps,"crane_wing","测试")["ok"],"不能战中变阵")
	check(is_equal_approx(root_army["organization"],org-10) and root_army["formation_locked"],"变阵没有组织成本和当日封锁")
	check(C.power(root_army,war.rules,"plains") == 0,"整阵日仍能攻击")
	var fake_adapter = store.agent
	var signature: String = war.Corps.decision_authority_signature(war.Corps.decision_signature(war,corps,fake_adapter))
	corps["formation"] = "fish_scale"
	check(war.Corps.decision_authority_signature(war.Corps.decision_signature(war,corps,fake_adapter)) != signature,"变阵后后台旧决策没有失效")
	corps["formation"] = "crane_wing"
	var cell: int = root_army["tactical"]["cell"]
	war.Tactical.move(war)
	check(root_army["tactical"]["cell"] == cell,"整阵日仍能移动")
	check(not F.change(war,corps,"long_snake","冷却测试")["ok"],"变阵冷却未生效")
	var child: String = corps["units"][1]
	check(war.Corps.issue(war,corps,{"type":"assign_task","unit":child,"task":"rear_guard"},"紧急掩护")["ok"],"变阵冷却错误阻止紧急军令")
	war.state["tick"] += 3
	F.sync(war)
	var context: Dictionary = war.Corps.commander_context(war,corps)
	for option in context["candidates"]:
		if option["action"]["type"] != "set_formation": continue
		check(F.can_change(war,corps,option["action"]["formation"]),"主帅候选阵型不合法")
	check(context.has("unit_mix") and context.has("terrain"),"主帅没有收到兵种及地形适配提示")
	check(context.has("enemy_unit_mix_estimate") and not context["local_map"].has("log"),"阵型判断缺少敌兵种侦察或携带完整战斗日志")
	var saved: Dictionary = war.export_state()
	var restored = War.new()
	restored.setup(store,saved)
	check(restored.state["corps"][corps["id"]]["formation"] == "crane_wing","阵型没有往返保存")
	saved["corps"][corps["id"]].erase("formation")
	restored.setup(store,saved)
	check(restored.state["corps"][corps["id"]]["formation"] == "none","旧档没有回退无阵")
	var next_cells := {}
	for unit_id in corps["units"]: next_cells[unit_id] = war.state["armies"][unit_id]["tactical"]["cell"]
	check(war.command_formation(root_army["id"],"long_snake")["ok"],"玩家不能下令变阵")
	await war.step(null)
	check(root_army["formation_locked"] and C.power(root_army,war.rules,"plains") == 0,"玩家变阵下一执行日没有封锁")
	for unit_id in corps["units"]: check(war.state["armies"][unit_id]["tactical"]["cell"] == next_cells[unit_id],"玩家变阵日分队仍然移动")
	await war.step(null)
	check(not root_army["formation_locked"],"玩家变阵超过一日仍不能行动")
	store.restore_battle_test()
	print("FORMATION_OK: attack, weakness, proficiency, cost, lock, cooldown, emergency orders, candidates and saves" if failures.is_empty() else "FORMATION_FAILED")
	quit(0 if failures.is_empty() else 1)
