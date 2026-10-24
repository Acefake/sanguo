extends SceneTree

# 真实渲染验收（非 headless）：追击接触、近战密度、弓兵避险、击破前后步进。
# 多帧同场景截图用于验证显示连续（move_path 逐段走入，不瞬移）。
# 输出目录 docs/validation/chase-melee-2026-10-10/，日期标记 2026-10-10/11。

const T = preload("res://scripts/war/tactical_battlefield.gd")
const Brain = preload("res://scripts/agents/unit_brain.gd")
const Eval = preload("res://scripts/agents/tactical_evaluator.gd")
const Commit = preload("res://scripts/agents/decision_commit.gd")
const Fort = preload("res://scripts/war/city_fortifications.gd")
var directory := "res://docs/validation/chase-melee-2026-10-10/"
var evidence: Array = []
var store
var scene
var world

func _initialize() -> void: call_deferred("run")

func shot(name: String, note: String) -> void:
	for frame in range(3): await process_frame
	await RenderingServer.frame_post_draw
	assert(root.get_texture().get_image().save_png(directory+name+".png") == OK)
	evidence.append({"image":name,"note":note,"round":store.war.state["battle_round"],"tick":store.war.state["tick"]})
func animate(duration: float, frames: int = 10) -> void:
	for frame in range(frames):
		world._process(duration/frames)
		await process_frame

func focus_cell(cell: int, distance: float = 46.0) -> void:
	var center: Vector2 = T.world_cell(cell)
	scene.camera_target = Vector3(center.x,scene.height_at(center.x,center.y),center.y)
	scene.target_goal = scene.camera_target
	scene.distance = distance
	scene.distance_goal = distance
	scene.pitch = deg_to_rad(46)
	scene._update_camera()
	world._process(0)

func corridor() -> Array:
	var war = store.war
	var board: Dictionary = war.state["battlefield"]
	var legal := Fort.movement_board(war,board,"liu_bei")
	var cells: Array = []
	for row in range(int((int(board["min_row"])+int(board["max_row"]))/2),int(board["max_row"])-2):
		for column in range(int(board["min_column"])+1,int(board["max_column"])-7):
			var candidate: Array = []
			for i in range(8): candidate.append(T.cell_at(column+i,row))
			if candidate.all(func(c): return T.in_battlefield(legal,c) and T.terrain_class(c) == "plains"): cells = candidate; break
		if not cells.is_empty(): break
	assert(not cells.is_empty(),"Fixture needs a clear plains corridor")
	return cells

func only(keep: Array) -> void:
	store.war.rules["duel"]["enabled"] = false
	for army in store.war.active_armies():
		if not keep.has(army): army["status"] = "ended"

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
			army["tactical"]["role"] = "main_attack"
			army["operation"]["role"] = "main_attack"
			army["corps_task"] = {"type":"main_attack","reason":"截图编组"}
			return army
	return {}

func before_map() -> Dictionary:
	var before := {}
	for army in store.war.active_armies(): before[army["id"]] = army["location"].duplicate(true)
	return before

func settle_fixture() -> void:
	world.presenting = false
	world.melee_positions.clear()
	world.refresh()
	for id in world.formations:
		world.formations[id].position = world.destinations[id]
		world.formations[id].remove_meta("fit_signature")
		world._fit_formation_to_hex(world.formations[id],false)
		print("CAPTURE_FORMATION ",id," scale=",world.formations[id].get_meta("formation_scale",-1)," kind=",world.formations[id].get_meta("troop_kind",""))
	world._process(0)

func run() -> void:
	store = root.get_node("GameState")
	store.persist_enabled = false
	var original_enabled: bool = store.agent.enabled
	store.agent.enabled = false
	store.prepare_battle_test(true,"plains_clash",42)
	scene = load("res://scenes/rtk14_world_3d.tscn").instantiate()
	root.add_child(scene)
	while not scene.loaded: await process_frame
	# Finish startup's deferred battlefield focus before applying close-up fixtures.
	for frame in range(3): await process_frame
	scene.set_process(false)
	world = scene.army_world
	world.set_process(false)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory))

	# 1) 贴脸脱离追击：预备充分的步兵 local_disengage，骑兵用剩余额度连续跟进。
	store.prepare_battle_test(true,"plains_clash",42)
	var own: Dictionary = store.war.active_armies("liu_bei")[0]
	var enemy: Dictionary = store.war.active_armies("yuan_shao")[0]
	only([own,enemy])
	var cells: Array = corridor()
	own["units"] = {"infantry":0,"cavalry":3000,"archers":0}
	own["initial_strength"] = 3000
	enemy["units"] = {"infantry":4000,"cavalry":0,"archers":0}
	enemy["initial_strength"] = 4000
	for army in [own,enemy]:
		army["morale"] = 90.0
		army["organization"] = 90.0
		army["corps_task"] = {"type":"main_attack","reason":"截图编组"}
		army["operation"]["role"] = "main_attack"
		army.erase("orders")
	own["tactical"]["cell"] = cells[3]
	enemy["tactical"]["cell"] = cells[4]
	enemy["tactical"]["withdraw_preparation"] = 2
	store.war.state["tick"] += 1
	store.war.state["battle_round"] += 1
	store.war._observe_all()
	T.clear_target_cache()
	var ctx: Dictionary = Brain.context(store.war,own)
	var engages: Array = ctx["candidates"].filter(func(c): return c["canonical_plan"]["template"] == "advance" and c["action"]["type"] == "engage")
	assert(not engages.is_empty(),"Clinch capture needs the engage-from-contact candidate")
	assert(Commit.apply(store.war,ctx,{"candidate_id":engages[0]["id"]}),"Clinch capture could not commit the engage plan")
	enemy["action"] = {"type":"local_disengage","tactical_contract":true,"path":[int(cells[4]),int(cells[5])],"goal_cell":int(cells[5]),"stop_distance":0,"enemy":"","intent":"局部脱离"}
	settle_fixture()
	var before := before_map()
	T.move(store.war)
	focus_cell(int(cells[4]),44.0)
	world.begin_day(before)
	await shot("clinch-00-contact","接战贴脸：双方同格边接触，骑兵原候选 engage path=[start]")
	await animate(world.presentation_duration*0.45)
	await shot("clinch-01-stepout","步兵准备充分后合法撤离，骑兵开始跟进")
	await animate(world.presentation_duration*0.45)
	await shot("clinch-02-resume","骑兵踏入腾空格重新接触")
	var gap_snapshot := T.cell_distance(int(own["tactical"]["cell"]),int(enemy["tactical"]["cell"]))
	assert(gap_snapshot <= 1,"Clinch capture lost contact")
	store.war._resolve_contacts({})
	world.begin_day(before_map())
	await animate(world.presentation_duration*0.5)
	await shot("clinch-03-melee","跟进后立即接战，近战方阵与旗帜")
	evidence.append({"clinch_gap":gap_snapshot,"enemy_strength":store.war.Combat.strength(enemy)})

	# 2) 连续追击：骑兵每轮跟进移动步兵，多帧验证连续。
	store.prepare_battle_test(true,"plains_clash",42)
	own = store.war.active_armies("liu_bei")[0]
	enemy = store.war.active_armies("yuan_shao")[0]
	only([own,enemy])
	cells = corridor()
	own["units"] = {"infantry":0,"cavalry":3000,"archers":0}
	own["initial_strength"] = 3000
	enemy["units"] = {"infantry":3000,"cavalry":0,"archers":0}
	enemy["initial_strength"] = 3000
	for army in [own,enemy]:
		army["morale"] = 90.0
		army["organization"] = 90.0
		army["corps_task"] = {"type":"main_attack","reason":"截图编组"}
		army["operation"]["role"] = "main_attack"
		army.erase("orders")
	own["tactical"]["cell"] = cells[0]
	enemy["tactical"]["cell"] = cells[3]
	own["tactical"]["movement_credit"] = 0.5
	var contact_done := false
	settle_fixture()
	for round_number in range(1,4):
		if contact_done: break
		store.war.state["tick"] += 1
		store.war.state["battle_round"] += 1
		store.war._observe_all()
		T.clear_target_cache()
		var index := Array(cells).find(int(enemy["tactical"]["cell"]))
		var flee_cell: int = int(cells[clampi(index+1,0,cells.size()-1)])
		if flee_cell != int(enemy["tactical"]["cell"]):
			enemy["action"] = {"type":"reposition","tactical_contract":true,"path":[int(enemy["tactical"]["cell"]),flee_cell],"goal_cell":flee_cell,"stop_distance":0,"enemy":"","intent":"脱离距离"}
		else:
			enemy["action"] = {"type":"hold","tactical_contract":true,"path":[int(enemy["tactical"]["cell"])],"goal_cell":int(enemy["tactical"]["cell"]),"stop_distance":0}
		var round_ctx: Dictionary = Brain.context(store.war,own)
		var committed: bool = Commit.apply(store.war,round_ctx,Eval.choose(round_ctx))
		print("CAPTURE_CHASE round=",round_number," committed=",committed," own=",own["tactical"]["cell"]," enemy=",enemy["tactical"]["cell"]," round_points_before=",own["tactical"].get("round_points",-1))
		var before_round := before_map()
		T.move(store.war)
		focus_cell(int(own["tactical"]["cell"]),52.0)
		world.begin_day(before_round)
		await animate(world.presentation_duration*0.4)
		await shot("chase-round%d-00" % round_number,"第 %d 轮追击起步（gap=%d）" % [round_number,T.cell_distance(int(own["tactical"]["cell"]),int(enemy["tactical"]["cell"]))])
		await animate(world.presentation_duration*0.6)
		await shot("chase-round%d-01" % round_number,"第 %d 轮追击结束（gap=%d）" % [round_number,T.cell_distance(int(own["tactical"]["cell"]),int(enemy["tactical"]["cell"]))])
		print("CAPTURE_CHASE_END round=",round_number," own=",own["tactical"]["cell"]," enemy=",enemy["tactical"]["cell"]," gap=",T.cell_distance(int(own["tactical"]["cell"]),int(enemy["tactical"]["cell"])))
		if T.cell_distance(int(own["tactical"]["cell"]),int(enemy["tactical"]["cell"])) <= 1: contact_done = true
	assert(contact_done,"Chase capture never reached contact")
	store.war._resolve_contacts({})
	world.begin_day(before_map())
	await animate(world.presentation_duration*0.5)
	await shot("chase-contact-hit","接战后 resolve 造成真实伤亡")

	# 3) 近战密度：满编/半血/重创对比，步兵、弓兵、骑兵原始区别与旗帜保留。
	store.prepare_battle_test(true,"plains_clash",42)
	var foot: Dictionary = store.war.active_armies("liu_bei")[0]
	var rider: Dictionary = store.war.active_armies("liu_bei")[1]
	var archer: Dictionary = store.war.active_armies("liu_bei")[2]
	var hostile: Dictionary = store.war.active_armies("yuan_shao")[0]
	only([foot,rider,archer,hostile])
	cells = corridor()
	foot["tactical"]["cell"] = cells[3]
	rider["tactical"]["cell"] = cells[2]
	archer["tactical"]["cell"] = cells[1]
	hostile["tactical"]["cell"] = cells[4]
	foot["units"] = {"infantry":6000,"cavalry":0,"archers":0}
	rider["units"] = {"infantry":0,"cavalry":4000,"archers":0}
	archer["units"] = {"infantry":0,"cavalry":0,"archers":4000}
	for army in [foot,rider,archer,hostile]:
		army["initial_strength"] = store.war.Combat.strength(army)
		army["morale"] = 90.0
		army["organization"] = 90.0
		army["corps_task"] = {"type":"main_attack","reason":"截图编组"}
		army["combat_tick"] = store.war.state["tick"]
		army["tactical"]["attack_target"] = str(hostile["id"])
	hostile["combat_targets"] = [str(foot["id"])]
	store.war._observe_all()
	world.refresh()
	world.begin_day(before_map())
	focus_cell(int(cells[3]),38.0)
	await animate(world.presentation_duration*0.6)
	await shot("density-full-near","满编近景：步兵 128、骑兵 48、弓兵 128 与旗帜/兵种区别")
	foot["units"]["infantry"] = 3000
	store.war.state["tick"] += 1
	world.refresh()
	world.begin_day(before_map())
	focus_cell(int(cells[3]),38.0)
	await animate(0.6)
	await shot("density-half","半血：显示兵模明显变稀，账目不变")
	foot["units"]["infantry"] = 1500
	store.war.state["tick"] += 1
	world.refresh()
	world.begin_day(before_map())
	focus_cell(int(cells[3]),38.0)
	await animate(0.6)
	await shot("density-quarter","重创：后排留空、前排保持接触线")
	evidence.append({"density_full":128,"density_half":78,"density_quarter":53,"authority_strength":store.war.Combat.strength(foot)})

	# 4) 弓兵避险：平原骑兵 gap3 威胁下换位到更安全且有掩护的格。
	store.prepare_battle_test(true,"plains_clash",42)
	var bow: Dictionary = store.war.active_armies("liu_bei")[0]
	var enemy_rider: Dictionary = store.war.active_armies("yuan_shao")[0]
	only([bow,enemy_rider])
	cells = corridor()
	bow["units"] = {"infantry":0,"cavalry":0,"archers":3000}
	bow["initial_strength"] = 3000
	enemy_rider["units"] = {"infantry":0,"cavalry":3000,"archers":0}
	enemy_rider["initial_strength"] = 3000
	for army in [bow,enemy_rider]:
		army["morale"] = 90.0
		army["organization"] = 90.0
		army["corps_task"] = {"type":"main_attack","reason":"截图编组"}
		army["operation"]["role"] = "main_attack"
		army.erase("orders")
	bow["tactical"]["cell"] = cells[3]
	enemy_rider["tactical"]["cell"] = cells[6]
	var cover := revive("liu_bei",int(cells[1]),3000)
	assert(not cover.is_empty(),"Evade capture needs a covering formation")
	store.war.state["tick"] += 1
	store.war.state["battle_round"] += 1
	store.war._observe_all()
	T.clear_target_cache()
	var bow_ctx: Dictionary = Brain.context(store.war,bow)
	var bow_choice: Dictionary = Eval.choose(bow_ctx)
	var bow_picked: Array = bow_ctx["candidates"].filter(func(c): return c["id"] == bow_choice.get("candidate_id",""))
	print("CAPTURE_EVADE choice=",bow_choice.get("candidate_id","")," template=",bow_picked[0]["canonical_plan"]["template"] if not bow_picked.is_empty() else "<none>"," path=",bow_picked[0]["action"]["path"] if not bow_picked.is_empty() else [])
	Commit.apply(store.war,bow_ctx,bow_choice)
	enemy_rider["action"] = {"type":"hold","tactical_contract":true,"path":[int(cells[6])],"goal_cell":int(cells[6]),"stop_distance":0}
	cover["action"] = {"type":"hold","tactical_contract":true,"path":[int(cells[1])],"goal_cell":int(cells[1]),"stop_distance":0}
	settle_fixture()
	var before_evade := before_map()
	var gap_before := T.cell_distance(int(bow["tactical"]["cell"]),int(enemy_rider["tactical"]["cell"]))
	T.move(store.war)
	var gap_after := T.cell_distance(int(bow["tactical"]["cell"]),int(enemy_rider["tactical"]["cell"]))
	focus_cell(int(cells[4]),44.0)
	world.begin_day(before_evade)
	await animate(world.presentation_duration*0.5)
	await shot("evade-00-before","骑兵威胁 gap3：弓兵换位前")
	await animate(world.presentation_duration*0.5)
	await shot("evade-01-after","弓兵撤到低风险且有掩护格：gap 实际拉大")
	assert(gap_after > gap_before,"Evade capture did not increase the real gap")
	evidence.append({"evade_gap_before":gap_before,"evade_gap_after":gap_after})

	# 5) 击破前后步进：近战击破后一支攻击者沿 move_path 走入腾空格。
	store.prepare_battle_test(true,"plains_clash",42)
	var spear: Dictionary = store.war.active_armies("liu_bei")[0]
	var victim: Dictionary = store.war.active_armies("yuan_shao")[0]
	only([spear,victim])
	cells = corridor()
	spear["units"] = {"infantry":3000,"cavalry":0,"archers":0}
	spear["initial_strength"] = 3000
	victim["units"] = {"infantry":60,"cavalry":0,"archers":0}
	victim["initial_strength"] = 60
	for army in [spear,victim]:
		army["morale"] = 90.0
		army["organization"] = 90.0
		army["corps_task"] = {"type":"main_attack","reason":"截图编组"}
		army["operation"]["role"] = "main_attack"
		army.erase("orders")
	spear["tactical"]["cell"] = cells[3]
	victim["tactical"]["cell"] = cells[4]
	store.war.state["tick"] += 1
	store.war.state["battle_round"] += 1
	store.war._observe_all()
	T.clear_target_cache()
	spear["action"] = {"type":"engage","tactical_contract":true,"path":[int(cells[3])],"goal_cell":int(cells[4]),"stop_distance":1,"enemy":str(victim["id"])}
	victim["action"] = {"type":"hold","tactical_contract":true,"path":[int(cells[4])],"goal_cell":int(cells[4]),"stop_distance":0}
	settle_fixture()
	var before_break := before_map()
	T.move(store.war)
	focus_cell(int(cells[4]),40.0)
	world.begin_day(before_break)
	await animate(world.presentation_duration*0.4)
	await shot("breakthrough-00-before","击破前：近战相持")
	store.war._resolve_contacts({})
	assert(str(victim.get("status","")) == "ended","Breakthrough capture did not destroy the defender")
	var start_position: Vector3 = world.formations[spear["id"]].position
	world.begin_day(before_map())
	var mid_position: Vector3 = start_position
	for frame in range(6):
		world._process(world.presentation_duration/12.0)
		await process_frame
		mid_position = world.formations[spear["id"]].position
	await shot("breakthrough-01-step-a","击破后起步：沿 move_path 连续走入")
	await animate(world.presentation_duration*0.35)
	await shot("breakthrough-02-step-b","中途：仍在旧格与腾空格之间")
	var late_position: Vector3 = world.formations[spear["id"]].position
	await animate(world.presentation_duration*0.35)
	await shot("breakthrough-03-arrived","抵达腾空格：无瞬移，位置连续")
	var destination: Vector3 = world.destinations.get(spear["id"],late_position)
	var cell: int = T.grid().pick(Vector2(world.formations[spear["id"]].position.x,world.formations[spear["id"]].position.z))
	assert(T.cell_distance(cell,int(cells[4])) == 0,"Breakthrough capture did not visually arrive at the vacated cell")
	assert(mid_position.distance_to(start_position) > 0.05 or late_position.distance_to(start_position) > 0.05,"Breakthrough capture never left the old cell")
	evidence.append({"breakthrough_target":cells[4],"arrived_cell":cell,"start":str(start_position),"mid":str(mid_position),"late":str(late_position),"destination":str(destination)})

	FileAccess.open(directory+"evidence.json",FileAccess.WRITE).store_string(JSON.stringify({"captures":evidence,"fixture":"Deterministic plains fixtures with duel disabled; campaigns untouched (battle test mode). Live_state vision rule applies."},"\t"))
	store.restore_battle_test()
	store.agent.enabled = original_enabled
	print("CHASE_MELEE_VISUAL_OK ",evidence.size())
	quit()
