extends SceneTree
const D = preload("res://scripts/war/duel_system.gd")
const C = preload("res://scripts/war/combat_system.gd")
const War = preload("res://scripts/war/campaign_state.gd")
const Role = preload("res://scripts/war/officer_role.gd")
var failures: Array[String] = []
func _initialize(): call_deferred("run")
func check(ok: bool, message: String):
	if not ok: failures.append(message); push_error(message)
# 单挑资格现在受角色限制（前锋／猛将／守备），所以测试必须按角色选人，
# 而不是取数组下标（下标可能落在主帅／军师身上）。
func duelist(war, faction: String, skip: Array = []) -> Dictionary:
	for army in war.active_armies(faction):
		if army.has("tactical") and Role.can_duel(war, army) and not army["officer_id"] in skip: return army
	return {}
func run():
	var store = root.get_node("GameState")
	store.persist_enabled = false
	store.prepare_battle_test(true)
	var war = store.war
	# Wound recovery and pair limits use guaranteed non-terminal results here.
	war.rules["officer_fate"]["duel_death"] = 0.0
	war.rules["officer_fate"]["duel_capture"] = 0.0
	var a: Dictionary = duelist(war, "liu_bei")
	var b: Dictionary = duelist(war, "yuan_shao")
	check(not a.is_empty() and not b.is_empty(), "测试战场缺少可单挑将领")
	a["tactical"]["cell"] = war.Tactical.offset_cell(war.state["battlefield"],0,0)
	b["tactical"]["cell"] = war.Tactical.neighbors(a["tactical"]["cell"])[0]
	a["action"] = {"type":"engage"}
	b["action"] = {"type":"continue"}
	check(D.eligible(war,a,b),"相邻主动近战不能单挑")
	for action_type in ["reposition", "hold", "flank", "support", "pursue"]:
		a["action"] = {"type":action_type}
		b["action"] = {"type":action_type}
		check(D.eligible(war,a,b), "相邻近战动作无法单挑：" + action_type)
	a["action"] = {"type":"withdraw"}
	check(not D.eligible(war,a,b), "脱离接触动作触发单挑")
	a["action"] = {"type":"engage"}
	b["action"] = {"type":"continue"}
	var saved_orders: Dictionary = a.get("orders", {}).duplicate(true)
	a["orders"] = saved_orders.duplicate(true)
	a["orders"]["engage"] = false
	check(not D.eligible(war,a,b), "禁止接战命令仍触发单挑")
	a["orders"] = saved_orders
	b["tactical"]["phase"] = "远射"
	check(not D.eligible(war,a,b),"远射触发单挑")
	b["tactical"]["phase"] = "近战"
	b["returning"] = true
	check(not D.eligible(war,a,b),"撤退触发单挑")
	b["returning"] = false
	a["first_contact_effect_tick"] = war.state["tick"]
	check(not D.eligible(war,a,b),"武圣威压同日又触发单挑")
	a.erase("first_contact_effect_tick")
	var card: Dictionary = war.roster.officers[b["officer_id"]]
	var personality: Dictionary = card["personality"].duplicate(true)
	for name in ["忠义","自尊","自制"]: card["personality"][name] = 50
	var neutral := D.acceptance(war,b,a)
	card["personality"]["自制"] = 90
	check(D.acceptance(war,b,a) < neutral,"自制不影响拒战")
	card["personality"]["自制"] = 50
	card["personality"]["自尊"] = 90
	check(D.acceptance(war,b,a) > neutral,"自尊不影响应战")
	var rates := []
	for condition in ["普通","自制","自尊"]:
		for name in ["忠义","自尊","自制"]: card["personality"][name] = 50
		if condition != "普通": card["personality"][condition] = 90
		var probability := D.acceptance(war,b,a)
		var accepted := 0
		war.rng.seed = 10005
		for sample in range(4000):
			if war.rng.randf() < probability: accepted += 1
		var rate := accepted/4000.0
		check(absf(rate-probability) < 0.03,"固定种子应战率不在预期区间")
		rates.append(rate)
	check(rates[1] < rates[0] and rates[0] < rates[2],"性格应战率次序不符")
	card["personality"] = personality
	war.rng.seed = 12345
	var result := D.contest(war,a,b)
	war.rng.seed = 12345
	check(D.contest(war,a,b) == result,"单挑结果无法种子复现")
	check(result["rounds"].size() <= 40 and result.has("winner"),"单挑回合超过安全上限")
	var numeric: Dictionary = war.rules["duel"]["numeric"]
	var previous_hit: Array = numeric["hit_bounds"].duplicate()
	numeric["hit_bounds"] = [0.0,0.0]
	var no_knockout := D.contest(war,a,b)
	check(no_knockout["rounds"].size() == 40 and no_knockout["winner"] == -1 and no_knockout["result"] == "draw","无命中时安全上限应判平手")
	numeric["hit_bounds"] = previous_hit
	var strength := C.strength(b)
	b["morale"] = 100
	b["organization"] = 100
	D.apply_result(war,a,b,{"result":"overwhelming","winner":0})
	check(b["morale"] == 100 - war.rules["duel"]["effects"]["overwhelming"]["loser_morale"] and b["organization"] == 100 - war.rules["duel"]["effects"]["overwhelming"]["loser_org"] and b["duel_wounded"],"压倒胜出效果不符合规则")
	check(C.strength(b) == strength,"单挑直接扣兵或秒杀军队")
	check(not D.eligible(war,a,b), "负伤将领仍可发起单挑")
	b["duel_wounded"] = false
	war.state["officer_states"][b["officer_id"]].erase("duel_wounded")
	war.rules["duel"]["acceptance"] = 0.0
	D.challenge(war,a,b,true)
	check(war.Feedback.book(war).get("pending_events",[]).any(func(e):return e["kind"] == "单挑"),"真实单挑挑战没有写入会战事件")
	check(not D.eligible(war,a,b),"同一对将领重复单挑")
	var enemies: Array = war.active_armies("yuan_shao").filter(func(e): return e["officer_id"] != b["officer_id"] and Role.can_duel(war, e))
	var second: Dictionary = enemies[0]
	a["duel_wounded"] = false
	second["tactical"]["cell"] = b["tactical"]["cell"]
	second["action"] = {"type":"continue"}
	check(not D.challenge(war,a,second,true).is_empty(),"无法对另一将领进行第二次单挑")
	var third: Dictionary = enemies[1]
	third["tactical"]["cell"] = b["tactical"]["cell"]
	third["action"] = {"type":"continue"}
	check(not D.eligible(war,a,third),"同一武将一战超过两次单挑")
	b["duel_wounded"] = true
	var saved: Dictionary = war.export_state()
	var restored = War.new()
	restored.setup(store,saved)
	var replay := D.contest(war,a,b)
	check(D.contest(restored,restored.state["armies"][a["id"]],restored.state["armies"][b["id"]]) == replay,"读档后单挑RNG轨迹不同")
	check(restored.state["duels"]["records"] == war.state["duels"]["records"] and restored.state["armies"][b["id"]]["duel_wounded"],"单挑记录或负伤没有保存")
	b["location"] = {"node":b["home"],"edge":"","progress":0.0}
	war._finish(b,"撤退")
	check(war.state["officer_states"][b["officer_id"]]["status"] == "recovering", "负伤将领战后没有休养")
	war.state["tick"] += int(war.rules["duel"]["recover_days"])
	war._deliver_reports()
	check(not war.state["officer_states"][b["officer_id"]].get("duel_wounded",false) and war.state["officer_states"][b["officer_id"]]["status"] == "deployed","伤愈后未清除伤势或错误释放仍在军团的武将")
	store.restore_battle_test()
	print("DUEL_OK: eligibility, personality, replay RNG, effects, manpower, one pair, wounds and save" if failures.is_empty() else "DUEL_FAILED")
	quit(0 if failures.is_empty() else 1)
