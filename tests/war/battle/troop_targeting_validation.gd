extends SceneTree

# 兵种目标选择回归：骑兵对可达暴露弓兵的真实选择、保护/不可达对照、
# 弓兵对骑兵威胁的提前换位与贴脸脱离准备。
# 日期标记 2026-10-11；方案文档 docs/追击与兵种近战改进方案-2026-10-10.md。

const T = preload("res://scripts/war/battle/tactical_battlefield.gd")
const Brain = preload("res://scripts/agents/unit_brain.gd")
const Eval = preload("res://scripts/agents/tactical_evaluator.gd")
const Commit = preload("res://scripts/agents/decision_commit.gd")
const Roles = preload("res://scripts/war/battle/troop_roles.gd")
const Fort = preload("res://scripts/war/battle/city_fortifications.gd")
var store
var failures: Array[String] = []

func _initialize() -> void: call_deferred("run")

func check(ok: bool, message: String) -> void:
	if not ok: failures.append(message); push_error(message)

func set_units(army: Dictionary, mix: Dictionary, strength: int) -> void:
	army["units"] = mix
	army["initial_strength"] = strength

func plains_runs(count: int, run_length: int) -> Array:
	var war = store.war
	var board: Dictionary = war.state["battlefield"]
	var legal := Fort.movement_board(war,board,"liu_bei")
	var runs: Array = []
	var used_rows: Array = []
	for gap in [4,2,0]:
		if runs.size() >= count: break
		for row in range(int(board["min_row"])+2,int(board["max_row"])-2):
			if runs.size() >= count: break
			var too_close := false
			for used in used_rows:
				if absi(int(row)-int(used)) < gap: too_close = true
			if too_close: continue
			for column in range(int(board["min_column"])+1,int(board["max_column"])-run_length+2):
				var candidate: Array = []
				for i in range(run_length): candidate.append(T.cell_at(column+i,row))
				if candidate.all(func(c): return T.in_battlefield(legal,c) and T.terrain_class(c) == "plains"):
					runs.append(candidate)
					used_rows.append(row)
					break
	return runs

func setup_two_runs() -> Dictionary:
	store.prepare_battle_test(true,"plains_clash",42)
	var war = store.war
	war.rules["duel"]["enabled"] = false
	var own: Dictionary = war.active_armies("liu_bei")[0]
	var normal: Dictionary = war.active_armies("yuan_shao")[0]
	var bow: Dictionary = war.active_armies("yuan_shao")[1]
	for army in war.active_armies():
		if army["id"] not in [own["id"],normal["id"],bow["id"]]: army["status"] = "ended"
	for army in [own,normal,bow]:
		army["morale"] = 90.0
		army["organization"] = 90.0
		army["fatigue"] = 0.0
		army["returning"] = false
		army["tactical"]["role"] = "main_attack"
		army["operation"]["role"] = "main_attack"
		army["corps_task"] = {"type":"main_attack","reason":"测试编组"}
		army.erase("orders")
		army["tactical"].erase("movement_credit")
	set_units(own,{"infantry":0,"cavalry":3000,"archers":0},3000)
	set_units(normal,{"infantry":3000,"cavalry":0,"archers":0},3000)
	set_units(bow,{"infantry":0,"cavalry":0,"archers":2000},2000)
	var runs := plains_runs(2,8)
	assert(runs.size() == 2,"Fixture needs two plains runs")
	own["tactical"]["cell"] = runs[0][0]
	normal["tactical"]["cell"] = runs[0][3]
	var bow_cell: int = runs[1][3]
	for option in runs[1]:
		if T.cell_distance(int(own["tactical"]["cell"]),int(option)) == 3: bow_cell = int(option); break
	bow["tactical"]["cell"] = bow_cell
	war._observe_all()
	T.clear_target_cache()
	return {"own":own,"normal":normal,"bow":bow,"runs":runs}

func revive(faction: String, cell: int, mix: Dictionary, strength: int) -> Dictionary:
	for army in store.war.state["armies"].values():
		if str(army["faction"]) == faction and str(army["status"]) == "ended":
			army["status"] = "active"
			set_units(army,mix,strength)
			army["morale"] = 90.0
			army["organization"] = 90.0
			army["fatigue"] = 0.0
			army["returning"] = false
			army["tactical"]["cell"] = cell
			army["tactical"]["role"] = "main_attack"
			army["operation"]["role"] = "main_attack"
			army["corps_task"] = {"type":"main_attack","reason":"测试编组"}
			return army
	return {}

func target_of(context: Dictionary, choice: Dictionary) -> String:
	for c in context["candidates"]:
		if c["id"] == choice.get("candidate_id",""): return str(c["canonical_plan"]["target_id"])
	return ""

func run() -> void:
	store = root.get_node("GameState")
	store.persist_enabled = false
	store.agent.enabled = false

	# A) 骑兵在等距可达的普通目标旁，真实选择暴露弓兵；受保护与不可达对照。
	var fixture := setup_two_runs()
	var own: Dictionary = fixture["own"]
	var normal: Dictionary = fixture["normal"]
	var bow: Dictionary = fixture["bow"]
	var runs: Array = fixture["runs"]
	var ctx_a: Dictionary = Brain.context(store.war,own)
	check(ctx_a["candidates"].any(func(c): return c["canonical_plan"]["target_id"] == bow["id"]),"Reachable bow produced no candidate before truncation")
	check(ctx_a["candidates"].any(func(c): return c["canonical_plan"]["target_id"] == normal["id"]),"Normal target produced no candidate")
	var chosen_a: Dictionary = Eval.choose(ctx_a)
	check(target_of(ctx_a,chosen_a) == bow["id"],"Cavalry did not choose the reachable exposed bow (chose %s)" % target_of(ctx_a,chosen_a))
	print("TARGET_SAMPLE exposure=exposed choice=",chosen_a.get("candidate_id","")," target=",target_of(ctx_a,chosen_a))
	var bow_spot: int = int(bow["tactical"]["cell"])
	var exposed_bonus := 0.0
	var normal_score := 0.0
	var bow_score := 0.0
	for c in ctx_a["candidates"]:
		var rated: Dictionary = Eval.evaluate(ctx_a,c)
		if c["canonical_plan"]["target_id"] == bow["id"]:
			exposed_bonus = maxf(exposed_bonus,float(rated["breakdown"].get("兵种克制",0)))
			bow_score = maxf(bow_score,float(rated["score"]))
		elif c["canonical_plan"]["target_id"] == normal["id"]:
			normal_score = maxf(normal_score,float(rated["score"]))
	check(exposed_bonus > 0,"Exposed bow candidate lost the cavalry type bonus")
	check(bow_score > normal_score,"Exposed bow candidate did not outscore the equal normal target")

	# 受保护：弓旁再放一支持枪步兵，选型收益必须被保护风险压回。
	var guard_cell := -1
	for neighbor in T.neighbors(bow_spot):
		if neighbor != int(own["tactical"]["cell"]) and T.terrain_class(neighbor) == "plains": guard_cell = neighbor; break
	var guard := revive("yuan_shao",guard_cell,{"infantry":2000,"cavalry":0,"archers":0},2000)
	check(not guard.is_empty(),"Fixture has no spare formation for the bow guard")
	if not guard.is_empty():
		store.war._observe_all()
		T.clear_target_cache()
		var ctx_guard: Dictionary = Brain.context(store.war,own)
		var protected_bonus := 0.0
		var protected_score := 0.0
		var guard_normal := 0.0
		for c in ctx_guard["candidates"]:
			var rated: Dictionary = Eval.evaluate(ctx_guard,c)
			if c["canonical_plan"]["target_id"] == bow["id"]:
				protected_bonus = maxf(protected_bonus,float(rated["breakdown"].get("兵种克制",0)))
				protected_score = maxf(protected_score,float(rated["score"]))
			elif c["canonical_plan"]["target_id"] == normal["id"]:
				guard_normal = maxf(guard_normal,float(rated["score"]))
		check(protected_bonus < exposed_bonus,"Protection did not reduce the cavalry type bonus")
		print("TARGET_SAMPLE exposure=guarded bonus=",protected_bonus," bow_score=",protected_score," normal_score=",guard_normal)

	# 不可达：职责半径外不生成弓兵候选。
	bow["tactical"]["cell"] = int(runs[1][runs[1].size()-1])
	own["corps_task"] = {"type":"main_attack","region_radius":2,"reason":"测试半径"}
	store.war._observe_all()
	T.clear_target_cache()
	var ctx_far: Dictionary = Brain.context(store.war,own)
	check(not ctx_far["candidates"].any(func(c): return c["canonical_plan"]["target_id"] == bow["id"]),"Bow outside the region radius was still offered as a target")

	# B) 弓兵：可见平原骑兵在下一轮可达（gap3）时提前换位到更安全且有掩护的格。
	var evasion := setup_two_runs()
	var archer: Dictionary = evasion["own"]
	var rider: Dictionary = evasion["normal"]
	var ev_runs: Array = evasion["runs"]
	evasion["bow"]["status"] = "ended"
	set_units(archer,{"infantry":0,"cavalry":0,"archers":3000},3000)
	set_units(rider,{"infantry":0,"cavalry":3000,"archers":0},3000)
	archer["tactical"]["cell"] = ev_runs[0][3]
	rider["tactical"]["cell"] = ev_runs[0][6]
	var cover := revive("liu_bei",int(ev_runs[0][1]),{"infantry":3000,"cavalry":0,"archers":0},3000)
	store.war._observe_all()
	T.clear_target_cache()
	var ctx_b: Dictionary = Brain.context(store.war,archer)
	var chosen_b: Dictionary = Eval.choose(ctx_b)
	var picked_b: Array = ctx_b["candidates"].filter(func(c): return c["id"] == chosen_b.get("candidate_id",""))
	check(not picked_b.is_empty(),"Archer threat produced no candidate")
	if not picked_b.is_empty():
		check(picked_b[0]["canonical_plan"]["template"] == "rally","Archer did not choose a fallback plan under cavalry threat (chose %s)" % picked_b[0]["canonical_plan"]["template"])
		check(T.cavalry_threat(ctx_b["knowledge"]["enemies"],int(picked_b[0]["next_cell"])) > T.cavalry_threat(ctx_b["knowledge"]["enemies"],int(archer["tactical"]["cell"])),"Archer fallback did not increase the cavalry threat gap")
		print("TARGET_SAMPLE archer_fallback=",picked_b[0]["action"]["path"]," next_threat=",T.cavalry_threat(ctx_b["knowledge"]["enemies"],int(picked_b[0]["next_cell"])))
		rider["action"] = {"type":"hold","tactical_contract":true,"path":[int(rider["tactical"]["cell"])],"goal_cell":int(rider["tactical"]["cell"]),"stop_distance":0}
		var gap_before := T.cell_distance(int(archer["tactical"]["cell"]),int(rider["tactical"]["cell"]))
		var committed_b: bool = Commit.apply(store.war,ctx_b,chosen_b)
		check(committed_b,"Archer fallback did not commit")
		print("EVASION_COMMIT committed=",committed_b," action=",archer["action"].get("type","")," path=",archer["action"].get("path",[]))
		store.war.state["tick"] += 1
		store.war.state["battle_round"] += 1
		store.war._observe_all()
		T.clear_target_cache()
		T.move(store.war)
		print("EVASION_MOVE cell=",archer["tactical"]["cell"]," blocked=",archer["tactical"].get("blocked",false)," path=",archer["tactical"].get("move_path",[]))
		var gap_after := T.cell_distance(int(archer["tactical"]["cell"]),int(rider["tactical"]["cell"]))
		check(gap_after > gap_before,"Executed archer fallback did not open real distance (gap %d -> %d)" % [gap_before,gap_after])
		var occupied_cells := {}
		var overlap := false
		for army in store.war.active_armies():
			if not army.has("tactical"): continue
			var cell: int = int(army["tactical"]["cell"])
			if occupied_cells.has(cell): overlap = true
			occupied_cells[cell] = true
		check(not overlap,"Archer fallback overlapped another formation")

	# C) 贴脸脱离：先按准备度停留积蓄，然后合法撤离且不穿人。
	var clinch := setup_two_runs()
	var archer_c: Dictionary = clinch["own"]
	var rider_c: Dictionary = clinch["normal"]
	var c_runs: Array = clinch["runs"]
	clinch["bow"]["status"] = "ended"
	set_units(archer_c,{"infantry":0,"cavalry":0,"archers":3000},3000)
	set_units(rider_c,{"infantry":0,"cavalry":3000,"archers":0},3000)
	archer_c["tactical"]["cell"] = c_runs[0][4]
	rider_c["tactical"]["cell"] = c_runs[0][3]
	store.war._observe_all()
	T.clear_target_cache()
	var ctx_c: Dictionary = Brain.context(store.war,archer_c)
	check(ctx_c["crisis"],"Adjacent cavalry did not trigger the bow crisis review")
	var chosen_c: Dictionary = Eval.choose(ctx_c)
	var picked_c: Array = ctx_c["candidates"].filter(func(c): return c["id"] == chosen_c.get("candidate_id",""))
	check(not picked_c.is_empty() and picked_c[0]["action"]["type"] == "local_disengage","Bow in contact did not choose local_disengage (chose %s)" % (picked_c[0]["action"]["type"] if not picked_c.is_empty() else "<none>"))
	rider_c["action"] = {"type":"hold","tactical_contract":true,"path":[int(rider_c["tactical"]["cell"])],"goal_cell":int(rider_c["tactical"]["cell"]),"stop_distance":0}
	var cell_before := int(archer_c["tactical"]["cell"])
	check(Commit.apply(store.war,ctx_c,chosen_c),"Contact disengage did not commit")
	T.move(store.war)
	check(int(archer_c["tactical"]["cell"]) == cell_before,"Bow left contact before its preparation finished")
	check(int(archer_c["tactical"].get("withdraw_preparation",0)) == 1,"Contact disengage did not accumulate preparation")
	var prep_before := int(archer_c["tactical"].get("withdraw_preparation",0))
	store.war.state["tick"] += 1
	store.war.state["battle_round"] += 1
	store.war._observe_all()
	T.clear_target_cache()
	var ctx_c2: Dictionary = Brain.context(store.war,archer_c)
	var chosen_c2: Dictionary = Eval.choose(ctx_c2)
	var committed_c2: bool = Commit.apply(store.war,ctx_c2,chosen_c2)
	print("CLINCH_COMMIT2 committed=",committed_c2," action=",archer_c["action"].get("type","")," path=",archer_c["action"].get("path",[])," prep=",archer_c["tactical"].get("withdraw_preparation",0))
	T.move(store.war)
	print("CLINCH_MOVE2 cell=",archer_c["tactical"]["cell"]," blocked=",archer_c["tactical"].get("blocked",false)," path=",archer_c["tactical"].get("move_path",[])," prep=",archer_c["tactical"].get("withdraw_preparation",0))
	var escaped := int(archer_c["tactical"]["cell"]) != cell_before
	check(escaped,"Prepared bow never escaped contact in the second round")
	if escaped:
		var gap_c := T.cell_distance(int(archer_c["tactical"]["cell"]),int(rider_c["tactical"]["cell"]))
		check(gap_c >= 2,"Bow escaped to another contact cell (gap %d)" % gap_c)
		check(int(archer_c["tactical"]["cell"]) != int(rider_c["tactical"]["cell"]),"Bow disengage occupied the cavalry cell")

	# D) 脱离失败不能穿人：唯一退路被友军占用时留在原格。
	var blocked := setup_two_runs()
	var archer_d: Dictionary = blocked["own"]
	var rider_d: Dictionary = blocked["normal"]
	var d_runs: Array = blocked["runs"]
	blocked["bow"]["status"] = "ended"
	set_units(archer_d,{"infantry":0,"cavalry":0,"archers":3000},3000)
	set_units(rider_d,{"infantry":0,"cavalry":3000,"archers":0},3000)
	archer_d["tactical"]["cell"] = d_runs[0][4]
	rider_d["tactical"]["cell"] = d_runs[0][3]
	var wall := revive("liu_bei",int(d_runs[0][5]),{"infantry":3000,"cavalry":0,"archers":0},3000)
	archer_d["tactical"]["withdraw_preparation"] = 2
	store.war._observe_all()
	T.clear_target_cache()
	archer_d["action"] = {"type":"local_disengage","tactical_contract":true,"path":[int(archer_d["tactical"]["cell"]),int(wall["tactical"]["cell"])],"goal_cell":int(wall["tactical"]["cell"]),"enemy":"","intent":"局部脱离"}
	rider_d["action"] = {"type":"hold","tactical_contract":true,"path":[int(rider_d["tactical"]["cell"])],"goal_cell":int(rider_d["tactical"]["cell"]),"stop_distance":0}
	wall["action"] = {"type":"hold","tactical_contract":true,"path":[int(wall["tactical"]["cell"])],"goal_cell":int(wall["tactical"]["cell"]),"stop_distance":0}
	T.move(store.war)
	check(int(archer_d["tactical"]["cell"]) == int(d_runs[0][4]),"Blocked disengage passed through or displaced the ally")
	check(int(wall["tactical"]["cell"]) == int(d_runs[0][5]),"Blocked disengage moved the ally")
	check(int(rider_d["tactical"]["cell"]) == int(d_runs[0][3]),"Blocked disengage displaced the cavalry")

	# E) 守点弓兵禁退。
	archer_d["orders"] = {"engage":true,"retreat":true,"local_disengage":true,"must_hold_objective":true}
	archer_d["corps_task"] = {"type":"main_attack","cell":int(archer_d["tactical"]["cell"]),"must_hold_objective":true,"reason":"测试守点"}
	archer_d["tactical"]["withdraw_preparation"] = 0
	archer_d["battle_ai"] = archer_d.get("battle_ai",{})
	archer_d["battle_ai"]["submitted_round"] = -1
	store.war.state["tick"] += 1
	store.war.state["battle_round"] += 1
	store.war._observe_all()
	T.clear_target_cache()
	var ctx_e: Dictionary = Brain.context(store.war,archer_d)
	check(not ctx_e["candidates"].any(func(c): return c["canonical_plan"]["template"] == "rally"),"Hold order still offered a bow retreat")
	var chosen_e: Dictionary = Eval.choose(ctx_e)
	check(not picked_action_is(store.war,ctx_e,chosen_e,"local_disengage"),"Hold order still planned a local disengage")

	# F) 威胁半径按地形机动计算：平原骑兵3格可及，山地骑兵3格不误报。
	var plains_cell: int = int(d_runs[0][0])
	var plains_record := {"id":"g1","cell":plains_cell,"unit_mix_estimate":{"cavalry":1000},"routing":false}
	check(T.cavalry_reach(plains_record) == 3,"Plains cavalry reach should be 3, got %d" % T.cavalry_reach(plains_record))
	var rough_cell := -1
	var grid = T.grid()
	for cell in range(0,220*220):
		if not grid.walkable(cell): continue
		if T.terrain_class(cell) in ["mountains","forest","marsh"] and T.cell_distance(cell,plains_cell) <= 3:
			rough_cell = cell
			break
	if rough_cell >= 0:
		var rough_record := {"id":"g2","cell":rough_cell,"unit_mix_estimate":{"cavalry":1000},"routing":false}
		check(T.cavalry_reach(rough_record) < 3,"Rough-ground cavalry reach was not reduced")
		var rough_gap := T.cell_distance(rough_cell,plains_cell)
		if rough_gap <= 3:
			check(T.cavalry_threat([rough_record],plains_cell) == 99 or rough_gap <= T.cavalry_reach(rough_record)+1,"Rough cavalry reported a threat it cannot reach")

	print("TROOP_TARGETING_OK" if failures.is_empty() else "TROOP_TARGETING_FAILED " + str(failures))
	quit(0 if failures.is_empty() else 1)

func picked_action_is(war, context: Dictionary, choice: Dictionary, kind: String) -> bool:
	for c in context["candidates"]:
		if c["id"] == choice.get("candidate_id",""): return str(c["action"]["type"]) == kind
	return false
