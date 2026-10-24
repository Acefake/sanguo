extends SceneTree

const Brain = preload("res://scripts/agents/unit_brain.gd")
const Plan = preload("res://scripts/agents/tactical_plan.gd")
const Eval = preload("res://scripts/agents/tactical_evaluator.gd")
const Commit = preload("res://scripts/agents/decision_commit.gd")
const Tactical = preload("res://scripts/war/battle/tactical_battlefield.gd")
const Candidates = preload("res://scripts/agents/tactical_candidates.gd")
var failures: Array[String] = []

func _initialize() -> void: call_deferred("run")
func check(ok: bool, message: String) -> void:
	if not ok: failures.append(message); push_error(message)

func run() -> void:
	var store: Node = root.get_node("GameState")
	store.persist_enabled = false
	store.agent.enabled = false
	store.prepare_battle_test(true,"plains_clash",42)
	var war = store.war
	# Verify the UnitBrain pipeline under explicit obedience; refusal is covered separately.
	war.rules["corps"] = {"autonomy": {"forced_stance": "obey"}}
	await war.step()
	check(war.state["battle_ai_metrics"]["actors"] == war.active_armies().size(),"存在可行动分队未进入自主决策")
	print("UNIT_METRICS ",war.state["battle_ai_metrics"])
	for army in war.active_armies():
		check(army.has("battle_ai") and army["battle_ai"]["submitted_round"] == war.state["battle_round"],"军团部将未提交本轮行动")
		check(army["action"].get("tactical_contract",false),"部将没有明确的战术执行契约")
		var ctx := Brain.context(war,army)
		var old_rng: int = war.rng.state
		var before: Dictionary = army.duplicate(true)
		Eval.choose(ctx)
		check(war.rng.state == old_rng and army == before,"只读预测修改世界或战斗随机流")
		check(not Commit.apply(war,ctx,Eval.choose(ctx)),"同轮重复提交")
		check(ctx["candidates"].size() <= 24,"候选预算失控")
	var own: Dictionary = war.active_armies("liu_bei")[1]
	var ctx := Brain.context(war,own)
	var hidden: Dictionary = war.active_armies("yuan_shao")[-1]
	var original: Dictionary = hidden.duplicate(true)
	hidden["units"]["infantry"] += 100000
	hidden["tactical"]["cell"] += 220
	war._observe_all()
	var changed := Brain.context(war,own)
	check(changed["knowledge"]["enemies"] != ctx["knowledge"]["enemies"],"远方敌军实时信息未进入决策")
	hidden.clear()
	hidden.merge(original)
	war._observe_all()
	var snapshot: Dictionary = war.export_state()
	Brain.decide(war,null,true)
	check(snapshot["armies"] == war.state["armies"] and snapshot["corps"] == war.state["corps"] and snapshot["reports"] == war.state["reports"],"影子决策存在世界副作用")
	var saved: Dictionary = war.export_state()
	await war.step()
	var expected: Array = war.active_armies().map(func(a): return [a["id"],a["units"],a["morale"],a["organization"],a["tactical"]["cell"],a["battle_ai"]["plan"]])
	war.setup(store,JSON.parse_string(JSON.stringify(saved)))
	await war.step()
	var actual: Array = war.active_armies().map(func(a): return [a["id"],a["units"],a["morale"],a["organization"],a["tactical"]["cell"],a["battle_ai"]["plan"]])
	if Plan.normalized(actual) != Plan.normalized(expected): FileAccess.open("res://docs/validation/tactical-unit-replay-debug.json",FileAccess.WRITE).store_string(JSON.stringify({"expected":expected,"actual":actual},"\t"))
	check(Plan.normalized(actual) == Plan.normalized(expected),"存读档后离线决策或账本不能复现")
	# A request-scoped c00 may mean a different plan in today's table.
	own = war.active_armies("liu_bei")[1]
	ctx = Brain.context(war,own)
	if ctx["candidates"].size() > 1:
		var request := ctx.duplicate(true)
		request["candidates"][0]["canonical_plan"]["goal_cell"] = -999
		Eval.rank(ctx)
		var verdict := Brain.model_verdict(ctx,{"context":request,"result":{"candidate_id":request["candidates"][0]["id"]}})
		check(not verdict["ok"],"旧候选重名被当作当前候选执行")
	# Explicit hard authority is independent of personality and model choice.
	own = war.active_armies("liu_bei")[1]
	own["orders"] = war.orders_for(own)
	own["orders"]["retreat"] = false
	own["orders"]["local_disengage"] = false
	own["orders"]["must_hold_objective"] = true
	Plan.ensure(war,own)
	ctx = Brain.context(war,own)
	check(not ctx["candidates"].any(func(c): return c["canonical_plan"]["template"] == "rally"),"死守/禁止撤退仍生成局部脱离")
	for candidate in ctx["candidates"]: check(Tactical.cell_distance(candidate["canonical_plan"]["goal_cell"],ctx["authority"]["duty_cell"]) <= 1,"硬职责范围被人格绕过")
	# Bounded decision logs and occupancy across a real multi-round fight.
	store.prepare_battle_test(true,"plains_clash",42)
	war = store.war
	war.rules["corps"] = {"autonomy": {"forced_stance": "obey"}}
	var moves := 0
	var phases := {}
	for day in range(15):
		await war.step()
		var cells := {}
		for army in war.active_armies():
			if not army.has("tactical"): continue
			var cell: int = army["tactical"]["cell"]
			check(not cells.has(cell),"真实战斗出现重复占格")
			cells[cell] = true
			check(Tactical.can_enter(war,army,cell),"进入不可通行格")
			check(army["battle_ai"]["history"].size() <= 40,"个人决策日志无界增长")
			if army["tactical"].get("move_path",[]).size() > 1: moves += 1
			phases[army["battle_ai"]["plan"].get("template","")] = true
	check(moves > 10,"战术计划无法驱动实际移动")
	print("UNIT_BEHAVIOR moves=",moves," templates=",phases.keys()," metrics=",war.state["battle_ai_metrics"])
	store.restore_battle_test()
	print("UNIT_BRAIN_OK" if failures.is_empty() else "UNIT_BRAIN_FAILED "+str(failures))
	quit(0 if failures.is_empty() else 1)
