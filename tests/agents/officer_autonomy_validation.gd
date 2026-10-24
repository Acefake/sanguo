extends SceneTree

# 独立自主决策专用验证：每名武将（含无兵参军）独立立场、
# 服从/异议/自行行动、拒命同回合与下回合不被主帅覆盖、自行行动执行本地合法动作、
# 生死继任与兵力台账守恒。

const Corps = preload("res://scripts/war/campaign/army_corps.gd")
const Structure = preload("res://scripts/war/campaign/corps_structure.gd")
const Autonomy = preload("res://scripts/agents/officer_autonomy.gd")
var failures: Array[String] = []

func _initialize() -> void: call_deferred("run")

func check(value: bool, message: String) -> void:
	if not value: failures.append(message); push_error(message)

func snapshot(war, corps: Dictionary) -> Dictionary:
	var strengths := {}
	var members: Array = corps["members"].duplicate()
	for id in corps["units"]:
		var army: Dictionary = war.state["armies"][id]
		strengths[id] = war.Combat.strength(army)
	return {"members": members, "strengths": strengths, "dead": int(war.state["armies"][corps["root_id"]].get("dead", 0))}

func run() -> void:
	var store: Node = root.get_node("GameState")
	store.persist_enabled = false
	store.agent.enabled = false
	store.prepare_battle_test(true, "plains_clash", 42)
	var war = store.war
	var corps: Dictionary = war.state["corps"].values()[0]
	var commander: String = str(corps["commander_id"])
	var staff := ""
	for id in corps["members"]:
		if Structure.behavior_of(str(corps["appointments"].get(id, ""))) == "staff": staff = str(id); break
	check(staff != "", "战斗军团缺少参军")
	var target := ""
	for id in corps["units"]:
		var unit: Dictionary = war.state["armies"][id]
		if str(id) == str(corps["root_id"]) or unit["status"] == "ended" or unit["returning"]: continue
		target = str(id)
		break
	check(target != "", "战斗军团缺少分队")
	if staff == "" or target == "":
		quit(1)
		return
	var base_tick: int = int(war.state["tick"])

	# —— 阶段一：强制异议。全员（含参军）独立表态，参军不会自行领兵。 ——
	war.rules["corps"] = {"autonomy": {"forced_stance": "object"}}
	war.state["tick"] = base_tick + 1
	Autonomy.evaluate_corps(war, corps)
	for id in corps["members"]:
		if str(id) == commander: continue
		check(int(Autonomy.stance_of(corps, str(id)).get("tick", -1)) == int(war.state["tick"]), "成员未获得当日独立立场")
	check(str(Autonomy.stance_of(corps, staff).get("stance", "")) == "object", "无兵参军立场不是异议")
	check(is_equal_approx(Autonomy.act_probability(war, corps, staff), 0.0), "无兵参军可自行领兵")
	var before_task: Dictionary = war.state["armies"][target]["corps_task"].duplicate(true)
	var refused_same: Dictionary = Corps.issue(war, corps, {"type": "assign_task", "unit": target, "task": "rear_guard"}, "测试覆盖拒命者")
	check(not refused_same.get("ok", true) and bool(refused_same.get("refused", false)), "异议将领的同回合行动被主帅覆盖：%s" % str(refused_same))
	war.state["tick"] = base_tick + 2
	var refused_next: Dictionary = Corps.issue(war, corps, {"type": "assign_task", "unit": target, "task": "rear_guard"}, "测试覆盖拒命者")
	check(not refused_next.get("ok", true) and bool(refused_next.get("refused", false)), "异议将领的下回合行动被主帅覆盖：%s" % str(refused_next))
	check(war.state["armies"][target]["corps_task"] == before_task, "拒命者的任务被改写")

	# —— 阶段二：拒命窗口结束后（第3日）恢复发令，回到服从。 ——
	war.rules["corps"] = {"autonomy": {"forced_stance": "obey"}}
	war.state["tick"] = base_tick + 3
	war.state["armies"][target]["corps_task"]["issued_at"] = int(war.state["tick"]) - 5
	var new_task: String = "rear_guard" if str(before_task.get("type", "")) != "rear_guard" else "regroup"
	var restored: Dictionary = Corps.issue(war, corps, {"type": "assign_task", "unit": target, "task": new_task}, "窗口结束恢复正常发令")
	check(restored.get("ok", false), "异议窗口结束后主帅仍无法发令：%s" % str(restored))
	check(str(Autonomy.stance_of(corps, str(war.state["armies"][target]["officer_id"])).get("stance", "")) == "obey", "服从表态未记录")

	# —— 阶段三：强制自行行动。领兵者执行本地合法战术候选，且不被覆盖。 ——
	war.rules["corps"] = {"autonomy": {"forced_stance": "act"}}
	war.rules["battle_ai"]["mode"] = "legacy"
	war.state["tick"] = base_tick + 4
	Corps.update(war)
	var leader_unit: Dictionary = war.state["armies"][target]
	check(leader_unit.has("autonomy"), "分队缺少独立立场记录")
	if leader_unit.has("autonomy"):
		check(str(leader_unit["autonomy"]["stance"]) in ["act", "object"], "自行行动立场未记录：%s" % str(leader_unit["autonomy"]))
	if str(Autonomy.stance_of(corps, str(leader_unit["officer_id"])).get("stance", "")) == "act":
		check(str(leader_unit["last_reason"]).begins_with("自行行动"), "自行行动者未执行本地判断：%s" % str(leader_unit["last_reason"]))
		check(str(leader_unit["action"].get("type", "")) in ["engage", "flank", "hold"], "自行行动者执行了非法动作：%s" % str(leader_unit["action"]))
		var blocked_act: Dictionary = Corps.issue(war, corps, {"type": "assign_task", "unit": target, "task": "main_attack"}, "覆盖自行行动者")
		check(not blocked_act.get("ok", true), "自行行动者同回合被主帅覆盖")
	war.rules["battle_ai"]["mode"] = "active"

	# —— 阶段四：参军独立立场进入主帅上下文与参谋建议。 ——
	war.rules["corps"] = {"autonomy": {"forced_stance": "object"}}
	war.state["tick"] = base_tick + 6
	var context: Dictionary = Corps.commander_context(war, corps)
	check(str(context.get("staff_advice", {}).get("stance", "")) == "object", "参军建议未携带独立立场")
	var missing := 0
	for member in context["members"]:
		if not member.has("stance"): missing += 1
	check(missing == 0 and context["members"].size() == corps["members"].size(), "主帅上下文缺少成员独立立场")
	check(not Array(context.get("autonomy", [])).is_empty(), "主帅上下文缺少自主性摘要")

	# —— 阶段五：守恒：立场评估不改变成员与兵力；主帅战死后继任不变账。 ——
	var before := snapshot(war, corps)
	check(before["members"].size() > 0, "快照成员为空")
	var root_army: Dictionary = war.state["armies"][corps["root_id"]]
	war.state["officer_states"][commander] = {"status": "dead", "lost": true}
	root_army["status"] = "ended"
	root_army["outcome"] = "军队覆没"
	Corps.succeed(war, corps)
	check(str(corps["commander_id"]) != commander, "主帅战死后未产生继任者")
	check(corps["members"].size() == before["members"].size(), "继任后成员数量改变")
	var after := snapshot(war, corps)
	var changed := 0
	for id in before["strengths"]:
		if after["strengths"].get(id, -1) != before["strengths"][id]: changed += 1
	check(changed == 0, "继任评估改变了分队兵力台账")
	if failures.is_empty():
		print("OFFICER_AUTONOMY_OK: per-officer obey/object/act, staff independent view, no same/next-turn override, local legal action, succession conservation")
	quit(0 if failures.is_empty() else 1)
