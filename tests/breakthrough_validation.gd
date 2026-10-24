extends SceneTree

# 近战击破推进回归：resolve 后守军覆没且格空时，一名实际近战攻击者
# 用本轮真实剩余额度沿 move_path 进入腾空格；远射/守点/危险/额度不足/无追击
# 授权全部禁占，且兵账不变。日期标记 2026-10-11。
# 方案文档 docs/追击与兵种近战改进方案-2026-10-10.md。

const T = preload("res://scripts/war/tactical_battlefield.gd")
const Fort = preload("res://scripts/war/city_fortifications.gd")
var store
var failures: Array[String] = []

func _initialize() -> void: call_deferred("run")

func check(ok: bool, message: String) -> void:
	if not ok: failures.append(message); push_error(message)

func lineup() -> Array:
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
	for row in range(int(board["min_row"])+2,int(board["max_row"])-2):
		for column in range(int(board["min_column"])+1,int(board["max_column"])-7):
			var candidate: Array = []
			for i in range(8): candidate.append(T.cell_at(column+i,row))
			if candidate.all(func(c): return T.in_battlefield(legal,c) and T.terrain_class(c) == "plains"): cells = candidate; break
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
	return [own,enemy,cells]

func revive(faction: String, cell: int, strength: int) -> Dictionary:
	for army in store.war.state["armies"].values():
		if str(army["faction"]) == faction and str(army["status"]) == "ended":
			army["status"] = "active"
			army["units"] = {"infantry":strength,"cavalry":0,"archers":0}
			army["initial_strength"] = strength
			army["morale"] = 90.0
			army["organization"] = 90.0
			army["returning"] = false
			army["tactical"]["cell"] = cell
			army["corps_task"] = {"type":"main_attack","reason":"测试编组"}
			army["action"] = {"type":"hold","tactical_contract":true,"path":[cell],"goal_cell":cell,"stop_distance":0}
			return army
	return {}

func stage(own: Dictionary, enemy: Dictionary, cells: Array, own_cell: int, enemy_cell: int) -> void:
	own["tactical"]["cell"] = cells[own_cell]
	enemy["tactical"]["cell"] = cells[enemy_cell]
	enemy["units"] = {"infantry":60,"cavalry":0,"archers":0}
	enemy["initial_strength"] = 60
	enemy["action"] = {"type":"hold","tactical_contract":true,"path":[int(enemy["tactical"]["cell"])],"goal_cell":int(enemy["tactical"]["cell"]),"stop_distance":0}
	own["action"] = {"type":"engage","tactical_contract":true,"path":[int(own["tactical"]["cell"])],"goal_cell":int(enemy["tactical"]["cell"]),"stop_distance":1,"enemy":str(enemy["id"])}
	store.war.state["tick"] += 1
	store.war.state["battle_round"] += 1
	store.war._observe_all()
	T.clear_target_cache()

func book(army: Dictionary) -> Dictionary:
	return {"dead":int(army.get("dead",0)),"wounded":int(army.get("wounded",0)),"captured":int(army.get("captured",0)),"deposited":int(army.get("deposited",0)),"strength":store.war.Combat.strength(army),"initial":int(army.get("initial_strength",0))}

func balanced(b: Dictionary) -> bool:
	return int(b["dead"]) + int(b["wounded"]) + int(b["captured"]) + int(b["deposited"]) + int(b["strength"]) == int(b["initial"])

func occupancy_ok() -> bool:
	var seen := {}
	for army in store.war.active_armies():
		if not army.has("tactical"): continue
		var cell: int = int(army["tactical"]["cell"])
		if seen.has(cell): return false
		seen[cell] = true
	return true

func run() -> void:
	store = root.get_node("GameState")
	store.persist_enabled = false
	store.agent.enabled = false

	# 1) 单近战攻击者击破：按剩余额度进入腾空格，账目守恒且不追加攻击。
	var single := lineup()
	var own: Dictionary = single[0]
	var enemy: Dictionary = single[1]
	var cells: Array = single[2]
	own["units"] = {"infantry":3000,"cavalry":0,"archers":0}
	own["initial_strength"] = 3000
	stage(own,enemy,cells,3,4)
	T.move(store.war)
	check(int(own["tactical"].get("round_marker",-1)) == int(store.war.state["tick"]),"Move phase did not record this round's budget")
	check(float(own["tactical"].get("round_points",0.0)) >= 1.0,"Contact round has no real remaining budget")
	var own_book_before := book(own)
	var enemy_book_before := book(enemy)
	var own_strength_before: int = own_book_before["strength"]
	store.war._resolve_contacts({})
	print("CASE1_BOOK ",book(enemy)," own=",book(own))
	check(str(enemy.get("status","")) == "ended","Melee annihilation did not end the defender")
	check(int(store.war.Combat.strength(enemy)) == 0 and balanced(book(enemy)),"Defender casualty ledger is off")
	var enemy_book := book(enemy)
	check(int(enemy_book["dead"]) + int(enemy_book["wounded"]) + int(enemy_book["captured"]) + int(enemy_book["deposited"]) == int(enemy_book["initial"]),"Defender losses are not conserved across dead/wounded/captured/deposited")
	check(int(enemy["units"]["infantry"]) + int(enemy["units"]["archers"]) + int(enemy["units"]["cavalry"]) == 0,"Defender still holds soldiers after annihilation")
	check(int(own["tactical"]["cell"]) == int(cells[4]),"Single melee striker did not enter the vacated cell")
	check(Array(own["tactical"].get("move_path",[])).back() == int(cells[4]),"Breakthrough step missing from move_path animation")
	check(is_equal_approx(float(own["tactical"].get("round_points",0.0)),0.0),"Breakthrough did not deduct one real point")
	check(int(own["tactical"].get("breakthrough_marker",-1)) == int(store.war.state["tick"]),"Breakthrough marker missing for once-per-round guard")
	check(Array(own.get("combat_targets",[])).size() <= 1,"Breakthrough produced an extra attack")
	check(balanced(book(own)),"Breakthrough broke the attacker's books")
	check(balanced(enemy_book_before) and balanced(book(enemy)),"Defender books unbalanced after breakthrough")
	print("BREAKTHROUGH_SAMPLE single cell=",own["tactical"]["cell"]," strength=",store.war.Combat.strength(own)," from=",own_strength_before)

	# 2) 多近战攻击者：一格最多一队。
	var multi := lineup()
	var ownA: Dictionary = multi[0]
	var enemyM: Dictionary = multi[1]
	var cellsM: Array = multi[2]
	ownA["units"] = {"infantry":3000,"cavalry":0,"archers":0}
	ownA["initial_strength"] = 3000
	stage(ownA,enemyM,cellsM,3,4)
	ownA["action"] = {"type":"engage","tactical_contract":true,"path":[int(ownA["tactical"]["cell"])],"goal_cell":int(enemyM["tactical"]["cell"]),"stop_distance":1,"enemy":str(enemyM["id"])}
	var ownB := revive("liu_bei",int(cellsM[5]),3000)
	check(not ownB.is_empty(),"Fixture has no second liu_bei formation for the multi case")
	if not ownB.is_empty():
		ownB["action"] = {"type":"engage","tactical_contract":true,"path":[int(cellsM[5])],"goal_cell":int(cellsM[4]),"stop_distance":1,"enemy":str(enemyM["id"])}
		store.war._observe_all()
		T.clear_target_cache()
		T.move(store.war)
		store.war._resolve_contacts({})
		check(str(enemyM.get("status","")) == "ended","Multi-attacker melee did not break the defender")
		var claimed := 0
		if int(ownA["tactical"]["cell"]) == int(cellsM[4]): claimed += 1
		if int(ownB["tactical"]["cell"]) == int(cellsM[4]): claimed += 1
		check(claimed == 1,"Broken cell was claimed by %d attackers instead of exactly one" % claimed)
		check(occupancy_ok(),"Multi-attacker breakthrough produced overlapping cells")
		print("BREAKTHROUGH_SAMPLE multi claimed=",claimed)

	# 3) 远射禁占：弓兵用箭雨击破后不得进入腾空格。
	var ranged := lineup()
	var archer: Dictionary = ranged[0]
	var enemyR: Dictionary = ranged[1]
	var cellsR: Array = ranged[2]
	archer["units"] = {"infantry":0,"cavalry":0,"archers":3000}
	archer["initial_strength"] = 3000
	stage(archer,enemyR,cellsR,6,4)
	check(T.attack_range(archer) == 2,"Ranged fixture cannot shoot at range two")
	enemyR["action"] = {"type":"hold","tactical_contract":true,"path":[int(cellsR[4])],"goal_cell":int(cellsR[4]),"stop_distance":0}
	archer["action"] = {"type":"engage","tactical_contract":true,"path":[int(cellsR[6])],"goal_cell":int(cellsR[4]),"stop_distance":2,"enemy":str(enemyR["id"])}
	T.move(store.war)
	store.war._resolve_contacts({})
	check(str(enemyR.get("status","")) == "ended","Ranged fire did not destroy the tiny defender")
	check(int(archer["tactical"]["cell"]) == int(cellsR[6]),"Ranged killer occupied the broken cell")
	check(occupancy_ok(),"Ranged breakthrough overlapped cells")

	# 4) 守点禁占。
	var held := lineup()
	var ownH: Dictionary = held[0]
	var enemyH: Dictionary = held[1]
	var cellsH: Array = held[2]
	ownH["units"] = {"infantry":3000,"cavalry":0,"archers":0}
	ownH["initial_strength"] = 3000
	ownH["orders"] = {"engage":true,"retreat":true,"pursue":true,"must_hold_objective":true}
	ownH["corps_task"] = {"type":"main_attack","cell":int(cellsH[3]),"must_hold_objective":true,"reason":"测试守点"}
	stage(ownH,enemyH,cellsH,3,4)
	T.move(store.war)
	store.war._resolve_contacts({})
	check(str(enemyH.get("status","")) == "ended","Hold-order melee did not destroy the defender")
	check(int(ownH["tactical"]["cell"]) == int(cellsH[3]),"Hold order followed into the broken cell")

	# 5) 危险禁占：腾空格旁另有两支可见敌军。
	var danger := lineup()
	var ownD: Dictionary = danger[0]
	var enemyD: Dictionary = danger[1]
	var cellsD: Array = danger[2]
	ownD["units"] = {"infantry":3000,"cavalry":0,"archers":0}
	ownD["initial_strength"] = 3000
	stage(ownD,enemyD,cellsD,3,4)
	var threat_cells: Array = []
	for neighbor in T.neighbors(int(cellsD[4])):
		if neighbor == int(cellsD[3]) or neighbor == int(cellsD[4]): continue
		if T.cell_distance(neighbor,int(cellsD[3])) < 2: continue
		if T.can_enter(store.war,ownD,neighbor): threat_cells.append(neighbor)
		if threat_cells.size() >= 2: break
	var guardA := revive("yuan_shao",int(threat_cells[0]),2000) if threat_cells.size() > 0 else {}
	var guardB := revive("yuan_shao",int(threat_cells[1]),2000) if threat_cells.size() > 1 else {}
	check(not guardA.is_empty() and not guardB.is_empty(),"Fixture lacks two visible flankers for the danger case")
	if not guardA.is_empty() and not guardB.is_empty():
		store.war._observe_all()
		T.clear_target_cache()
		T.move(store.war)
		store.war._resolve_contacts({})
		check(str(enemyD.get("status","")) == "ended","Danger-case melee did not destroy the defender")
		check(int(ownD["tactical"]["cell"]) == int(cellsD[3]),"Breakthrough advanced into a cell adjacent to two visible enemies")

	# 6) 额度不足禁占。
	var spent := lineup()
	var ownS: Dictionary = spent[0]
	var enemyS: Dictionary = spent[1]
	var cellsS: Array = spent[2]
	ownS["units"] = {"infantry":3000,"cavalry":0,"archers":0}
	ownS["initial_strength"] = 3000
	stage(ownS,enemyS,cellsS,3,4)
	T.move(store.war)
	ownS["tactical"]["round_points"] = 0.5
	store.war._resolve_contacts({})
	check(str(enemyS.get("status","")) == "ended","Spent-budget melee did not destroy the defender")
	check(int(ownS["tactical"]["cell"]) == int(cellsS[3]),"Breakthrough ignored the exhausted round budget")

	# 7) 无追击授权禁占。
	var restricted := lineup()
	var ownP: Dictionary = restricted[0]
	var enemyP: Dictionary = restricted[1]
	var cellsP: Array = restricted[2]
	ownP["units"] = {"infantry":3000,"cavalry":0,"archers":0}
	ownP["initial_strength"] = 3000
	ownP["orders"] = {"engage":true,"retreat":true,"pursue":false}
	stage(ownP,enemyP,cellsP,3,4)
	T.move(store.war)
	store.war._resolve_contacts({})
	check(str(enemyP.get("status","")) == "ended","No-pursuit melee did not destroy the defender")
	check(int(ownP["tactical"]["cell"]) == int(cellsP[3]),"Breakthrough ignored the missing pursue authority")

	print("BREAKTHROUGH_OK" if failures.is_empty() else "BREAKTHROUGH_FAILED " + str(failures))
	quit(0 if failures.is_empty() else 1)
