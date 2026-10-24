extends SceneTree
const Brain = preload("res://scripts/agents/unit_brain.gd")
const Plan = preload("res://scripts/agents/tactical_plan.gd")
const Eval = preload("res://scripts/agents/tactical_evaluator.gd")
const Candidates = preload("res://scripts/agents/tactical_candidates.gd")
const Commit = preload("res://scripts/agents/decision_commit.gd")
const Tactical = preload("res://scripts/war/tactical_battlefield.gd")
const Coordination = preload("res://scripts/war/corps_coordination.gd")
var failures: Array[String] = []
var store: Node
var pair: Array = []
var cell := -1

func _initialize() -> void: call_deferred("run")
func check(ok: bool, message: String) -> void:
	if not ok: failures.append(message); push_error(message)
func fixture() -> void:
	store.prepare_battle_test(true,"plains_clash",42)
	var war = store.war
	pair = [war.active_armies("liu_bei")[1],war.active_armies("yuan_shao")[1]]
	for army in war.active_armies():
		if not pair.has(army): army["status"] = "ended"
	war.state["corps"] = {}
	for army in pair:
		army["intel"]["enemies"].clear()
		army.erase("corps_id")
		army["corps_task"] = {"type":"main_attack"}
		army["operation"] = {"role":"main_attack","support_id":""}
		army["departure_at"] = 0
		army["units"] = {"infantry":3000,"archers":0,"cavalry":0}
		army["initial_strength"] = 3000
		army["morale"] = 80.0
		army["organization"] = 80.0
		army["fatigue"] = 0.0
		army["action"] = {"type":"hold"}
		army["battle_ai"] = {}
		army.erase("battle_ai")
	var board: Dictionary = war.state["battlefield"]
	cell = -1
	for q in range(int(board["min_column"])+4,int(board["max_column"])-4):
		for r in range(int(board["min_row"])+4,int(board["max_row"])-4):
			var point := Tactical.cell_at(q,r)
			if range(5).all(func(i): return Tactical.can_enter(war,pair[0],point+i) and Tactical.terrain_class(point+i) == "plains"):
				cell = point
				break
		if cell >= 0: break
	assert(cell >= 0)
	pair[0]["tactical"]["cell"] = cell
	pair[1]["tactical"]["cell"] = cell+2
	war._observe_all()
	for army in pair: Plan.ensure(war,army)

func run() -> void:
	store = root.get_node("GameState")
	store.persist_enabled = false
	store.agent.enabled = false
	fixture()
	var war = store.war
	var own: Dictionary = pair[0]
	var enemy: Dictionary = pair[1]
	# Starting a slow move earns credit, while risk and damage still use the
	# actual occupied cell. The next round spends that credit on one real step.
	var saved_rules: Dictionary = war.rules.duplicate(true)
	war.rules["troop_traits"]["infantry"]["movement"]["plains"] = 0.5
	own["battle_ai"]["plan"] = {"template":"hold_line","target_id":"","goal_cell":cell,"ally_id":"","stop_distance":0}
	var slow := Brain.context(war,own)
	for axis in slow["officer"]["personality"]: slow["officer"]["personality"][axis] = 50
	var slow_choice := Eval.choose(slow)
	var slow_candidate: Dictionary = slow["candidates"].filter(func(c): return c["id"] == slow_choice["candidate_id"])[0]
	check(slow_candidate["canonical_plan"]["template"] == "advance" and slow_candidate["next_cell"] == cell and slow_candidate["progress_cell"] != cell,"低移动点让可行接敌永远不能启动")
	check(slow_candidate["forecast"]["enemy_loss"] == 0,"未实际移动就虚构进入攻击射程")
	check(Commit.apply(war,slow,slow_choice),"低移动点计划未提交")
	Tactical.move(war)
	check(own["tactical"]["cell"] == cell and float(own["tactical"]["movement_credit"]) > 0,"慢速首回合未积累移动点或发生瞬移")
	war.state["tick"] += 1
	war.state["battle_round"] += 1
	war._observe_all()
	slow = Brain.context(war,own)
	slow_choice = Eval.choose(slow)
	check(Commit.apply(war,slow,slow_choice),"积累移动点后的计划未提交")
	Tactical.move(war)
	check(own["tactical"]["cell"] != cell and Tactical.cell_distance(cell,int(own["tactical"]["cell"])) == 1,"慢速第二回合未消耗点数移动一格")
	war.rules = saved_rules
	fixture()
	war = store.war
	own = pair[0]
	enemy = pair[1]
	own["operation"]["role"] = "raid_rear"
	own["corps_task"] = {"type":"raid_rear","stage":"attack","cell":cell}
	Plan.ensure(war,own)
	own["battle_ai"]["plan"] = {"template":"approach_objective","target_id":"","goal_cell":cell,"ally_id":"","stop_distance":0}
	var finished_raid := Brain.context(war,own)
	check(not finished_raid["candidates"].any(func(c): return c["canonical_plan"]["template"] == "approach_objective" and c["canonical_plan"]["goal_cell"] == cell),"绕后完成后仍守着旧路径点")
	own["operation"]["role"] = "regroup"
	own["corps_task"] = {"type":"regroup","cell":cell+4}
	Plan.ensure(war,own)
	own["battle_ai"]["plan"] = {"template":"hold_line","target_id":"","goal_cell":cell+1,"ally_id":"","stop_distance":1}
	var regroup := Brain.context(war,own)
	check(not regroup["candidates"].any(func(c): return c["canonical_plan"]["goal_cell"] == cell+1),"归建仍复用过期集合位置")
	check(own["battle_ai"]["duty_cell"] == cell,"新军令没有刷新部队职责起点")
	fixture()
	war = store.war
	own = pair[0]
	enemy = pair[1]
	own["units"] = {"infantry":0,"archers":3000,"cavalry":0}
	own["operation"]["role"] = "support"
	own["corps_task"]["type"] = "support"
	Plan.ensure(war,own)
	var ctx := Brain.context(war,own)
	var result := Eval.choose(ctx)
	var candidate: Dictionary = ctx["candidates"].filter(func(c): return c["id"] == result["candidate_id"])[0]
	check(candidate["canonical_plan"]["template"] == "fire_with_cover" and candidate["next_cell"] == cell,"弓兵未维持现有有效射程")
	# A safe assigned ally does not keep a healthy frontline on endless escort.
	var friend: Dictionary = war.state["armies"].values().filter(func(a): return a["faction"] == own["faction"] and a["id"] != own["id"])[0]
	friend["status"] = "active"
	friend["returning"] = false
	friend["organization"] = 100.0
	friend["morale"] = 100.0
	friend["tactical"]["cell"] = cell-1
	friend["operation"] = {"role":"main_attack"}
	own["operation"]["support_id"] = friend["id"]
	ctx = Brain.context(war,own)
	check(not ctx["candidates"].any(func(c): return c["canonical_plan"]["template"] == "cover_ally" and c["canonical_plan"]["ally_id"] == friend["id"]),"安全友军仍锁住接应任务")
	friend["organization"] = 30.0
	ctx = Brain.context(war,own)
	check(ctx["candidates"].any(func(c): return c["canonical_plan"]["template"] == "cover_ally"),"友军承压后没有合法接应")
	friend["status"] = "ended"
	enemy["tactical"]["cell"] = cell+1
	war._observe_all()
	ctx = Brain.context(war,own)
	result = Eval.choose(ctx)
	candidate = ctx["candidates"].filter(func(c): return c["id"] == result["candidate_id"])[0]
	check(candidate["canonical_plan"]["template"] == "rally" and candidate["action"]["type"] == "local_disengage","弓兵近战危机没有比较合法脱离")
	# Local recovery must preserve the original entity, objective and manpower.
	own["organization"] = 45.0
	own["fatigue"] = 70.0
	war.state["battle_round"] = 1
	ctx = Brain.context(war,own)
	result = Eval.choose(ctx)
	check(Commit.apply(war,ctx,result),"合法局部整顿未提交")
	var id: String = own["id"]
	var home: String = own["home"]
	for day in range(4):
		war.state["tick"] += 1
		war._observe_all()
		Tactical.move(war)
	check(not own["returning"] and own["id"] == id and own["home"] == home,"局部脱离错误启动回城或重建部队")
	enemy["status"] = "ended"
	# Damage counters retain their last hit until the next hit. Yesterday's loss
	# must not make a safe intermediate recovery tile look permanently dangerous.
	own["intel"]["enemies"].clear()
	own["daily_loss"] = 90
	own["daily_loss_tick"] = int(war.state["tick"])-1
	own["organization"] = 45.0
	own["fatigue"] = 80.0
	own["battle_ai"]["plan"]["goal_cell"] = int(own["tactical"]["cell"])+2
	Plan.after_round(war,own)
	check(own["battle_ai"]["local_state"] == "recovering" and own["battle_ai"]["plan"]["goal_cell"] == own["tactical"]["cell"],"历史伤亡让安全休整点永远不能完成")
	own["tactical"]["cell"] = own["battle_ai"]["plan"]["goal_cell"]
	own["organization"] = 70.0
	own["morale"] = 70.0
	own["fatigue"] = 20.0
	war._observe_all()
	Plan.after_round(war,own)
	check(own["battle_ai"]["local_state"] == "ready_to_rejoin","恢复达标后未准备重新投入")
	# A safe recovery point must allow uninterrupted actual rest.
	own["organization"] = 45.0
	own["fatigue"] = 80.0
	own["battle_ai"]["local_state"] = "recovering"
	own["battle_ai"]["plan"]["goal_cell"] = own["tactical"]["cell"]
	ctx = Brain.context(war,own)
	check(ctx["candidates"].filter(func(c): return c["canonical_plan"]["template"] == "rally").all(func(c): return c["next_cell"] == ctx["self"]["cell"]),"安全休整仍逐日换位")
	fixture()
	war = store.war
	own = pair[0]
	enemy = pair[1]
	# A moved target invalidates its old approach cell; a lone commander can
	# continue the fight under the same engagement and regional authority.
	own["battle_ai"]["plan"] = {"template":"advance","target_id":enemy["id"],"goal_cell":cell+3,"ally_id":"","stop_distance":1}
	ctx = Brain.context(war,own)
	check(not ctx["candidates"].any(func(c): return c["canonical_plan"]["template"] == "advance" and c["canonical_plan"]["goal_cell"] == cell+3),"目标移动后仍执行旧目标格")
	own["corps_task"]["type"] = "command"
	own["operation"]["role"] = "command"
	ctx = Brain.context(war,own)
	check(ctx["last_line"] and ctx["candidates"].any(func(c): return c["canonical_plan"]["template"] == "advance"),"最后一支中军永远不能重新接敵")
	ctx["siege_approach"] = true
	ctx["last_line"] = false
	ctx["task"]["anchor_cell"] = cell+4
	ctx["current_plan"] = {}
	ctx["candidates"] = Candidates.generate(ctx)
	ctx.erase("_ranking")
	var siege_choice := Eval.choose(ctx)
	check(ctx["candidates"].any(func(c): return c["id"] == siege_choice.get("candidate_id","") and c["canonical_plan"]["template"] == "approach_objective"),"授权攻城后中军仍只在外圈等待")
	enemy["tactical"]["cell"] = cell+1
	war._observe_all()
	own["intel"]["enemies"][enemy["id"]]["observed_at"] = int(war.state["tick"])-4
	check(war._observed_contact(own)["adjacent_enemies"] == 0,"陈旧敌情把部队永久锁定为近战")
	own["corps_task"]["type"] = "main_attack"
	own["operation"]["role"] = "main_attack"
	own["orders"] = {"retreat":false,"local_disengage":false,"pursue":false}
	Plan.ensure(war,own)
	enemy["returning"] = true
	war._observe_all()
	ctx = Brain.context(war,own)
	check(not ctx["candidates"].any(func(c): return c["canonical_plan"]["target_id"] == enemy["id"] or c["canonical_plan"]["template"] == "rally"),"追击或脱离越过授权")
	var snapshots: Array = [Brain.context(war,own),Brain.context(war,enemy)]
	var proposals := {}
	for view in snapshots: proposals[view["actor_key"]] = Eval.choose(view)
	var coordinated := Coordination.resolve(snapshots,proposals)
	var reservations := {}
	for view in snapshots:
		var chosen: Dictionary = coordinated[view["actor_key"]].get("coordinated_candidate",{})
		if chosen.is_empty(): continue
		for next in chosen["action"]["path"].slice(1):
			check(not reservations.has(next),"协调没有消除目标格冲突")
			reservations[next] = true
	# Explicitly empty legal set cannot silently repeat last round's movement.
	ctx = Brain.context(war,own)
	ctx["candidates"] = []
	war.state["battle_round"] += 1
	ctx["battle_round"] = war.state["battle_round"]
	check(not Commit.apply(war,ctx,{}),"空合法集伪造行动")
	check(own["action"]["type"] == "no_legal_action","空合法集保留了上轮动作")
	fixture()
	war = store.war
	own = pair[0]
	enemy = pair[1]
	own["tactical"]["cell"] = cell+1
	own["corps_task"] = {"type":"main_attack","cell":cell,"must_hold_objective":true}
	Plan.ensure(war,own)
	ctx = Brain.context(war,own)
	# A legal final goal cannot authorize an out-of-region intermediate step,
	# even when that step is only being priced for next round's movement credit.
	var unsafe_routes := {"routes":{str(cell-1)+":0":cell+2},"destinations":{},"first":{},"occupied":{}}
	var unsafe: Array = []
	Candidates.add(unsafe,ctx,unsafe_routes,"hold_line",cell-1)
	check(unsafe.is_empty(),"合法目标允许绕路越出守点范围")
	ctx["self"]["mobility"] = 0.5
	Candidates.add(unsafe,ctx,unsafe_routes,"hold_line",cell-1)
	check(unsafe.is_empty(),"低移动点仍奖励越出守点的方向")
	enemy["status"] = "ended"
	own["action"] = {"type":"reposition","tactical_contract":true,"goal_cell":cell-1,"path":[cell+1,cell+2]}
	Tactical.move(war)
	check(own["tactical"]["cell"] == cell+1,"执行层未阻止越界契约路径")
	check(Tactical.duty_step_allowed(cell+4,cell+3,cell,1) and not Tactical.duty_step_allowed(cell+4,cell+5,cell,1),"职责调整后归建路径不能向内回归或允许向外偏离")
	own["corps_task"]["cell"] = -1
	war.state["battlefield"]["control_point"] = {"cell":cell+3,"radius":1}
	ctx = Brain.context(war,own)
	check(ctx["authority"]["duty_cell"] == cell+3 and Tactical.authority_duty_cell(war,own,war.orders_for(own)) == cell+3,"守点候选与执行使用不同的控制点")
	own["tactical"]["siege_slot"] = cell+4
	ctx = Brain.context(war,own)
	check(ctx["authority"]["duty_cell"] == cell+4 and Tactical.authority_duty_cell(war,own,war.orders_for(own)) == cell+4,"守点候选与执行使用不同的攻城位置")
	store.restore_battle_test()
	print("TACTICAL_BEHAVIOR_OK" if failures.is_empty() else "TACTICAL_BEHAVIOR_FAILED "+str(failures))
	quit(0 if failures.is_empty() else 1)
