extends SceneTree

# 追击/接战回归：骑兵对连续移动步兵的追击必须走
# Candidates -> Evaluator -> Commit -> Tactical.move -> resolve 的真实链路，
# 覆盖两种移动先后顺序、两点预算不双花、不可见/占格/守点/非追击状态禁追。
# 日期标记 2026-10-11；方案文档 docs/追击与兵种近战改进方案-2026-10-10.md。

const T = preload("res://scripts/war/tactical_battlefield.gd")
const Brain = preload("res://scripts/agents/unit_brain.gd")
const Eval = preload("res://scripts/agents/tactical_evaluator.gd")
const Commit = preload("res://scripts/agents/decision_commit.gd")
const Plan = preload("res://scripts/agents/tactical_plan.gd")
const Roles = preload("res://scripts/war/troop_roles.gd")
const Fort = preload("res://scripts/war/city_fortifications.gd")
var store
var failures: Array[String] = []

func _initialize() -> void: call_deferred("run")

func check(ok: bool, message: String) -> void:
	if not ok: failures.append(message); push_error(message)

func corridor(tick_parity: int = 0) -> Array:
	store.prepare_battle_test(true,"plains_clash",42)
	var war = store.war
	war.rules["duel"]["enabled"] = false
	var own: Dictionary = war.active_armies("liu_bei")[0]
	var enemy: Dictionary = war.active_armies("yuan_shao")[0]
	for army in war.active_armies():
		if army["id"] not in [own["id"],enemy["id"]]: army["status"] = "ended"
	var board: Dictionary = war.state["battlefield"]
	var legal := Fort.movement_board(war,board,"liu_bei")
	var cells: Array = []
	for run in [10,8]:
		for row in range(int(board["min_row"])+2,int(board["max_row"])-2):
			for column in range(int(board["min_column"])+1,int(board["max_column"])-run+2):
				var candidate: Array = []
				for i in range(run): candidate.append(T.cell_at(column+i,row))
				if candidate.all(func(c): return T.in_battlefield(legal,c) and T.terrain_class(c) == "plains"): cells = candidate; break
			if not cells.is_empty(): break
		if not cells.is_empty(): break
	assert(not cells.is_empty(),"Fixture needs a clear plains corridor")
	for army in [own,enemy]:
		army["morale"] = 90.0
		army["organization"] = 90.0
		army["fatigue"] = 0.0
		army["returning"] = false
		army["tactical"]["role"] = "main_attack"
		army["operation"]["role"] = "main_attack"
		army["corps_task"] = {"type":"main_attack","reason":"测试编组"}
		army["tactical"].erase("movement_credit")
		army.erase("orders")
	own["units"] = {"infantry":0,"cavalry":3000,"archers":0}
	enemy["units"] = {"infantry":3000,"cavalry":0,"archers":0}
	own["initial_strength"] = 3000
	enemy["initial_strength"] = 3000
	if int(war.state["tick"]) % 2 != tick_parity:
		war.state["tick"] += 1
		war.state["battle_round"] += 1
	return [own,enemy,cells]

func revive(faction: String, cell: int) -> Dictionary:
	for army in store.war.state["armies"].values():
		if str(army["faction"]) == faction and str(army["status"]) == "ended":
			army["status"] = "active"
			army["units"] = {"infantry":2000,"cavalry":0,"archers":0}
			army["initial_strength"] = 2000
			army["morale"] = 90.0
			army["organization"] = 90.0
			army["returning"] = false
			army["tactical"]["cell"] = cell
			army["corps_task"] = {"type":"main_attack","reason":"测试编组"}
			return army
	return {}

func flee_action(enemy: Dictionary, cells: Array, direction: int) -> Dictionary:
	var cell: int = int(enemy["tactical"]["cell"])
	var index: int = Array(cells).find(cell)
	if index < 0: return {"type":"hold"}
	var target: int = int(cells[clampi(index+direction,0,cells.size()-1)])
	if target == cell: return {"type":"hold"}
	return {"type":"reposition","tactical_contract":true,"path":[cell,target],"goal_cell":target,"stop_distance":0,"enemy":"","intent":"脱离距离"}

func disengage_action(enemy: Dictionary, cells: Array, direction: int) -> Dictionary:
	var cell: int = int(enemy["tactical"]["cell"])
	var index: int = Array(cells).find(cell)
	if index < 0: return {"type":"hold"}
	var target: int = int(cells[clampi(index+direction,0,cells.size()-1)])
	if target == cell: return {"type":"hold"}
	return {"type":"local_disengage","tactical_contract":true,"path":[cell,target],"goal_cell":target,"stop_distance":0,"enemy":"","intent":"局部脱离"}

func walk_round(own: Dictionary, enemy: Dictionary, cells: Array, direction: int = 1) -> Dictionary:
	store.war.state["tick"] += 1
	store.war.state["battle_round"] += 1
	store.war._observe_all()
	T.clear_target_cache()
	enemy["action"] = flee_action(enemy,cells,direction)
	var ctx: Dictionary = Brain.context(store.war,own)
	var chosen: Dictionary = Eval.choose(ctx)
	if not Commit.apply(store.war,ctx,chosen): chosen = {"error":"commit_failed"}
	T.move(store.war)
	return {"choice":chosen,"context":ctx}

func round_budget(own: Dictionary) -> float:
	return minf(2.0,float(own["tactical"].get("movement_credit",0.0)) + Roles.mobility(own,T.terrain_class(int(own["tactical"]["cell"])),store.war.rules))

func run() -> void:
	store = root.get_node("GameState")
	store.persist_enabled = false
	store.agent.enabled = false

	# 1) 连续移动步兵3轮，两种先后顺序都要追上；每轮检查预算不双花。
	for parity in [0,1]:
		var pair := corridor(parity)
		var own: Dictionary = pair[0]
		var enemy: Dictionary = pair[1]
		var cells: Array = pair[2]
		own["tactical"]["cell"] = cells[0]
		enemy["tactical"]["cell"] = cells[3]
		own["tactical"]["movement_credit"] = 0.5
		store.war._observe_all()
		T.clear_target_cache()
		var start_gap := T.cell_distance(int(own["tactical"]["cell"]),int(enemy["tactical"]["cell"]))
		check(start_gap == 3,"Precondition: gap 3 at credit 0.5, got %d" % start_gap)
		var contact_round := -1
		for round_number in range(1,4):
			var budget_before := round_budget(own)
			var before_gap := T.cell_distance(int(own["tactical"]["cell"]),int(enemy["tactical"]["cell"]))
			var outcome := walk_round(own,enemy,cells,1)
			var chosen: Dictionary = outcome["choice"]
			var ctx: Dictionary = outcome["context"]
			if round_number == 1:
				check(chosen.get("error","") == "","Round 1 candidate pipeline failed: "+str(chosen))
				var picked: Array = ctx["candidates"].filter(func(c): return c["id"] == chosen.get("candidate_id",""))
				check(not picked.is_empty() and picked[0]["canonical_plan"]["target_id"] == enemy["id"],"Cavalry did not choose to engage the moving infantry (chose %s)" % str(chosen.get("candidate_id","")))
			var steps: int = Array(own["tactical"].get("move_path",[])).size()-1
			var remaining := float(own["tactical"].get("round_points",0.0))
			check(steps <= 2,"Round %d moved %d steps (cap 2)" % [round_number,steps])
			check(steps + remaining <= budget_before + 0.011 and steps + remaining >= budget_before - 0.011,"Round %d double-spent or lost budget: steps=%d remaining=%.2f before=%.2f" % [round_number,steps,remaining,budget_before])
			check(remaining >= -0.001,"Round %d negative remaining budget" % round_number)
			var after_gap := T.cell_distance(int(own["tactical"]["cell"]),int(enemy["tactical"]["cell"]))
			check(after_gap <= before_gap,"Round %d gap grew: %d -> %d" % [round_number,before_gap,after_gap])
			if after_gap <= 1:
				contact_round = round_number
				break
		check(contact_round > 0 and contact_round <= 3,"Parity %d cavalry did not catch moving infantry within 3 rounds" % parity)
		if contact_round > 0:
			var strength_before_resolve: int = store.war.Combat.strength(enemy)
			store.war._resolve_contacts({})
			check(int(enemy.get("combat_tick",-1)) == int(store.war.state["tick"]),"Contact round produced no melee tick")
			check(store.war.Combat.strength(enemy) < strength_before_resolve,"Resolve produced no real casualties on the caught infantry")
			check(str(enemy.get("last_enemy_id","")) == str(own["id"]),"Melee contact did not credit the cavalry attacker")
		print("CHASE_SAMPLE parity=",parity," contact_round=",contact_round," gap=",T.cell_distance(int(own["tactical"]["cell"]),int(enemy["tactical"]["cell"])))

	# 2) 直接复现：credit 0.5、gap 3，起手决策路径必须允许合法落到目标邻格（两点额度第二点）。
	var repro := corridor()
	var own2: Dictionary = repro[0]
	var enemy2: Dictionary = repro[1]
	var cells2: Array = repro[2]
	own2["tactical"]["cell"] = cells2[1]
	enemy2["tactical"]["cell"] = cells2[4]
	own2["tactical"]["movement_credit"] = 0.5
	store.war._observe_all()
	T.clear_target_cache()
	var ctx2: Dictionary = Brain.context(store.war,own2)
	var two_step: Array = ctx2["candidates"].filter(func(c): return c["canonical_plan"]["target_id"] == enemy2["id"] and c["action"]["path"].size() >= 3)
	check(not two_step.is_empty(),"Gap 3 with credit 0.5 produced no legal two-step engage candidate")
	if not two_step.is_empty():
		var landing: int = int(two_step[0]["action"]["path"][-1])
		check(T.cell_distance(landing,int(enemy2["tactical"]["cell"])) == 1,"Second step did not land on the target's neighbouring cell")
	check(not ctx2["candidates"].any(func(c): return c["action"]["path"].has(int(enemy2["tactical"]["cell"]))),"Candidate path crosses the enemy cell")

	# 3) 第二点不得落到其他可见敌军的贴脸格：目标旁再放一支可见敌军。
	var guard_options: Array = []
	for neighbor in T.neighbors(int(enemy2["tactical"]["cell"])):
		if neighbor == int(own2["tactical"]["cell"]): continue
		if T.terrain_class(neighbor) != "plains": continue
		guard_options.append(neighbor)
	guard_options.sort_custom(func(a,b): return T.cell_distance(a,int(own2["tactical"]["cell"])) < T.cell_distance(b,int(own2["tactical"]["cell"])) if T.cell_distance(a,int(own2["tactical"]["cell"])) != T.cell_distance(b,int(own2["tactical"]["cell"])) else a < b)
	var guard_cell: int = int(guard_options[0]) if not guard_options.is_empty() else -1
	var escort := revive("yuan_shao",guard_cell) if guard_cell >= 0 else {}
	if not escort.is_empty():
		store.war._observe_all()
		T.clear_target_cache()
		var ctx3: Dictionary = Brain.context(store.war,own2)
		for c in ctx3["candidates"]:
			if c["canonical_plan"]["target_id"] != enemy2["id"]: continue
			if c["action"]["path"].size() < 3: continue
			check(T.cell_distance(int(c["next_cell"]),guard_cell) > 1,"Two-step landing ignored another visible enemy's zone")

	# 4) 全图可见：远于旧视野范围的目标仍可跟进，且不得占用敌军格。
	var blind := corridor()
	var own4: Dictionary = blind[0]
	var enemy4: Dictionary = blind[1]
	var cells4: Array = blind[2]
	own4["tactical"]["cell"] = cells4[0]
	enemy4["tactical"]["cell"] = cells4[cells4.size()-1]
	own4["orders"] = {"engage":true,"retreat":false,"local_disengage":false,"pursue":true}
	store.war._observe_all()
	T.clear_target_cache()
	check(T.cell_distance(int(own4["tactical"]["cell"]),int(enemy4["tactical"]["cell"])) > 7,"Blind fixture target is inside sight range")
	own4["intel"]["enemies"].erase(enemy4["id"])
	store.war.state["battle_round"] += 1
	store.war.state["tick"] += 1
	T.clear_target_cache()
	own4["action"] = {"type":"reposition","tactical_contract":true,"path":[int(own4["tactical"]["cell"])],"goal_cell":int(enemy4["tactical"]["cell"]),"stop_distance":1,"enemy":enemy4["id"]}
	own4["tactical"]["attack_target"] = enemy4["id"]
	T.move(store.war)
	check(int(own4["tactical"].get("chase_marker",-1)) == int(store.war.state["tick"]),"Full visibility did not allow distant pursuit")
	check(int(own4["tactical"]["cell"]) != int(enemy4["tactical"]["cell"]),"Distant pursuit overlapped the target")

	# 5) 通路占格：友军封住唯一前进格时不得穿人、不得占格。
	var blocked := corridor()
	var own5: Dictionary = blocked[0]
	var enemy5: Dictionary = blocked[1]
	var cells5: Array = blocked[2]
	own5["tactical"]["cell"] = cells5[0]
	enemy5["tactical"]["cell"] = cells5[4]
	var ally := revive(own5["faction"],cells5[2])
	own5["tactical"]["movement_credit"] = 0.5
	store.war._observe_all()
	T.clear_target_cache()
	var ctx5: Dictionary = Brain.context(store.war,own5)
	Commit.apply(store.war,ctx5,Eval.choose(ctx5))
	T.move(store.war)
	check(int(own5["tactical"]["cell"]) != int(ally["tactical"]["cell"]),"Chase passed through a friendly cell")
	check(int(own5["tactical"]["cell"]) != int(enemy5["tactical"]["cell"]),"Chase occupied the enemy cell")
	var duplicates := {}
	var overlap := false
	for army in store.war.active_armies():
		if not army.has("tactical"): continue
		var cell: int = int(army["tactical"]["cell"])
		if duplicates.has(cell): overlap = true
		duplicates[cell] = true
	check(not overlap,"Blocked chase created two units on one cell")

	# 6) 守点：职责半径约束下不得朝远处目标追击。
	var hold := corridor()
	var own6: Dictionary = hold[0]
	var enemy6: Dictionary = hold[1]
	var cells6: Array = hold[2]
	own6["tactical"]["cell"] = cells6[2]
	enemy6["tactical"]["cell"] = cells6[6]
	own6["tactical"]["movement_credit"] = 0.5
	own6["orders"] = {"engage":true,"retreat":true,"local_disengage":true,"must_hold_objective":true,"pursue":true}
	own6["corps_task"] = {"type":"main_attack","cell":cells6[2],"must_hold_objective":true,"reason":"测试守点"}
	store.war._observe_all()
	T.clear_target_cache()
	var ctx6: Dictionary = Brain.context(store.war,own6)
	Commit.apply(store.war,ctx6,Eval.choose(ctx6))
	var cell_before6 := int(own6["tactical"]["cell"])
	enemy6["action"] = {"type":"hold","tactical_contract":true,"path":[int(enemy6["tactical"]["cell"])],"goal_cell":int(enemy6["tactical"]["cell"]),"stop_distance":0}
	T.move(store.war)
	check(int(own6["tactical"].get("chase_marker",-1)) != int(store.war.state["tick"]),"Hold order chased a distant target")
	check(int(own6["tactical"]["cell"]) == cell_before6,"Hold order moved toward the enemy")

	# 7) 脱离/整顿状态不得追击（plan=rally / local_state 非 active）。
	var rest := corridor()
	var own7: Dictionary = rest[0]
	var enemy7: Dictionary = rest[1]
	var cells7: Array = rest[2]
	own7["tactical"]["cell"] = cells7[1]
	enemy7["tactical"]["cell"] = cells7[4]
	own7["tactical"]["movement_credit"] = 0.5
	Plan.ensure(store.war,own7)
	own7["battle_ai"]["plan"] = {"template":"rally","target_id":"","goal_cell":int(own7["tactical"]["cell"]),"ally_id":"","started_round":int(store.war.state["battle_round"]),"command_revision":1}
	own7["battle_ai"]["submitted_round"] = -1
	own7["battle_ai"]["local_state"] = "disengaging_local"
	store.war.state["tick"] += 1
	store.war.state["battle_round"] += 1
	store.war._observe_all()
	T.clear_target_cache()
	own7["action"] = {"type":"reposition","tactical_contract":true,"path":[int(own7["tactical"]["cell"])],"goal_cell":int(enemy7["tactical"]["cell"]),"stop_distance":1,"enemy":enemy7["id"]}
	own7["tactical"]["attack_target"] = enemy7["id"]
	enemy7["action"] = {"type":"hold","tactical_contract":true,"path":[int(enemy7["tactical"]["cell"])],"goal_cell":int(enemy7["tactical"]["cell"]),"stop_distance":0}
	var cell_before7 := int(own7["tactical"]["cell"])
	T.move(store.war)
	check(int(own7["tactical"].get("chase_marker",-1)) != int(store.war.state["tick"]),"Disengaging unit chased")
	check(int(own7["tactical"]["cell"]) == cell_before7,"Disengaging unit advanced with the follow phase")
	check(float(own7["tactical"].get("round_points",0.0)) >= 1.0,"Disengaging unit burned its follow budget")

	# 8) 贴脸脱离：初始 gap1 已接战，步兵准备充分后本回合发起真实 local_disengage，
	#    骑兵原候选为 engage path=[start]；两种先后顺序下都必须用剩余额度跟进，
	#    resolve 后敌兵量真实下降。连续逃脱三轮，真实新位置 gap 不得被甩开。
	for parity in [0,1]:
		var clinch := corridor(parity)
		var own8: Dictionary = clinch[0]
		var enemy8: Dictionary = clinch[1]
		var cells8: Array = clinch[2]
		own8["tactical"]["cell"] = cells8[3]
		enemy8["tactical"]["cell"] = cells8[4]
		own8["tactical"]["movement_credit"] = 0.5
		enemy8["tactical"]["withdraw_preparation"] = 2
		enemy8["organization"] = 95.0
		enemy8["morale"] = 95.0
		var own_first := false
		for round_number in range(1,4):
			store.war.state["tick"] += 1
			store.war.state["battle_round"] += 1
			store.war._observe_all()
			T.clear_target_cache()
			var order: Array = store.war.active_armies()
			if int(store.war.state["tick"]) % 2 == 0: order.reverse()
			own_first = order.find(own8) < order.find(enemy8)
			var ctx8: Dictionary = Brain.context(store.war,own8)
			# The morning plan in contact is the engage line: hold position and
			# strike. Later rounds keep the same contact plan while it stays valid.
			var engages: Array = ctx8["candidates"].filter(func(c): return c["canonical_plan"]["template"] == "advance" and c["action"]["type"] == "engage" and c["canonical_plan"]["target_id"] == enemy8["id"])
			check(not engages.is_empty(),"Round %d has no engage-from-contact candidate" % round_number)
			if engages.is_empty(): break
			check(engages[0]["action"]["path"].size() == 1,"Round %d engage candidate is not path=[start]" % round_number)
			check(Commit.apply(store.war,ctx8,{"candidate_id":engages[0]["id"]}),"Round %d engage plan did not commit" % round_number)
			print("CLINCH_DECISION parity=",parity," own_first=",own_first," round=",round_number," candidate=",engages[0]["id"]," path=",engages[0]["action"]["path"])
			var enemy_cell_before := int(enemy8["tactical"]["cell"])
			var strength_before8: int = store.war.Combat.strength(enemy8)
			enemy8["action"] = disengage_action(enemy8,cells8,1)
			T.move(store.war)
			var gap8 := T.cell_distance(int(own8["tactical"]["cell"]),int(enemy8["tactical"]["cell"]))
			check(int(enemy8["tactical"]["cell"]) != enemy_cell_before,"Round %d infantry local_disengage did not legally move" % round_number)
			check(int(own8["tactical"].get("chase_marker",-1)) == int(store.war.state["tick"]),"Round %d remaining budget was not used to follow the disengage" % round_number)
			check(gap8 <= 1,"Round %d cavalry was shaken off: gap %d" % [round_number,gap8])
			store.war._resolve_contacts({})
			check(store.war.Combat.strength(enemy8) < strength_before8,"Round %d resolve produced no real casualties" % round_number)
			check(str(enemy8.get("last_enemy_id","")) == str(own8["id"]),"Round %d damage ledger did not credit the pursuing cavalry" % round_number)
			print("CLINCH_SAMPLE parity=",parity," own_first=",own_first," round=",round_number," gap=",gap8," enemy_strength=",store.war.Combat.strength(enemy8))
			if str(enemy8.get("status","")) == "ended" or store.war.Combat.strength(enemy8) <= 0: break

	# 9) 远方敌军晨间可见，移动后按实时位置跟进。
	var fresh := corridor()
	var own9: Dictionary = fresh[0]
	var enemy9: Dictionary = fresh[1]
	var cells9: Array = fresh[2]
	own9["tactical"]["cell"] = cells9[0]
	enemy9["tactical"]["cell"] = cells9[cells9.size()-1]
	enemy9["units"] = {"infantry":0,"cavalry":3000,"archers":0}
	enemy9["initial_strength"] = 3000
	own9["tactical"]["movement_credit"] = 0.5
	enemy9["tactical"]["movement_credit"] = 0.5
	own9["intel"]["enemies"].erase(enemy9["id"])
	store.war.state["tick"] += 1
	store.war.state["battle_round"] += 1
	store.war._observe_all()
	check(own9["intel"]["enemies"].has(enemy9["id"]),"Distant target was not recorded at morning")
	own9["action"] = {"type":"reposition","tactical_contract":true,"path":[int(own9["tactical"]["cell"])],"goal_cell":int(enemy9["tactical"]["cell"]),"stop_distance":1,"enemy":enemy9["id"]}
	own9["tactical"]["attack_target"] = ""
	var enemy9_goal := int(cells9[cells9.size()-3])
	enemy9["action"] = {"type":"reposition","tactical_contract":true,"path":[int(enemy9["tactical"]["cell"]),int(cells9[cells9.size()-2]),enemy9_goal],"goal_cell":enemy9_goal,"stop_distance":0}
	T.move(store.war)
	var tick9 := int(store.war.state["tick"])
	check(int(own9["tactical"].get("chase_marker",-1)) == tick9,"Freshly visible target was not followed")
	check(own9["intel"]["enemies"].has(enemy9["id"]) and int(own9["intel"]["enemies"][enemy9["id"]]["observed_at"]) == tick9,"Fresh sighting did not refresh intel")
	var gap9 := T.cell_distance(int(own9["tactical"]["cell"]),int(enemy9["tactical"]["cell"]))
	check(gap9 <= 5,"Fresh follow did not use the new position (gap %d)" % gap9)
	print("FRESH_SIGHT_SAMPLE gap=",gap9)

	# 10) 目标向远处移动后仍更新实时位置，并保持追击。
	var escaped := corridor()
	var own10: Dictionary = escaped[0]
	var enemy10: Dictionary = escaped[1]
	var cells10: Array = escaped[2]
	own10["tactical"]["cell"] = cells10[0]
	enemy10["tactical"]["cell"] = cells10[6]
	enemy10["units"] = {"infantry":0,"cavalry":3000,"archers":0}
	enemy10["initial_strength"] = 3000
	own10["tactical"]["movement_credit"] = 0.5
	enemy10["tactical"]["movement_credit"] = 0.5
	store.war.state["tick"] += 1
	store.war.state["battle_round"] += 1
	store.war._observe_all()
	check(own10["intel"]["enemies"].has(enemy10["id"]),"Out-of-sight case precondition: target not recorded at morning")
	var old_record_cell := int(own10["intel"]["enemies"][enemy10["id"]]["tactical_cell"])
	var old_record_tick := int(own10["intel"]["enemies"][enemy10["id"]]["observed_at"])
	own10["action"] = {"type":"reposition","tactical_contract":true,"path":[int(own10["tactical"]["cell"])],"goal_cell":int(enemy10["tactical"]["cell"]),"stop_distance":1,"enemy":enemy10["id"]}
	var enemy10_goal := int(cells10[8])
	enemy10["action"] = {"type":"reposition","tactical_contract":true,"path":[int(enemy10["tactical"]["cell"]),int(cells10[7]),enemy10_goal],"goal_cell":enemy10_goal,"stop_distance":0}
	T.move(store.war)
	check(int(own10["tactical"].get("chase_marker",-1)) == int(store.war.state["tick"]),"Distant moving target was not followed")
	check(int(own10["intel"]["enemies"][enemy10["id"]]["tactical_cell"]) == int(enemy10["tactical"]["cell"]) and int(own10["intel"]["enemies"][enemy10["id"]]["observed_at"]) == int(store.war.state["tick"]),"Moving target's live position was not refreshed")
	check(int(own10["tactical"]["cell"]) != int(enemy10["tactical"]["cell"]),"Distant pursuit overlapped the target")
	print("OUT_OF_SIGHT_SAMPLE cell=",own10["tactical"]["cell"]," stale_cell=",old_record_cell)

	print("CHASE_CONTACT_OK" if failures.is_empty() else "CHASE_CONTACT_FAILED " + str(failures))
	quit(0 if failures.is_empty() else 1)
