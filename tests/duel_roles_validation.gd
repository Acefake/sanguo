extends SceneTree

# 角色定位驱动战场行为 —— 单挑资格与触发条件验证。
#
#   godot --headless --path . --script tests/duel_roles_validation.gd
#
# 覆盖：
#   C1 诸葛亮型（武力低、定位“主帅、军师／不宜前锋”）绝不可发起或被选为单挑。
#   C2 边界：同为接战、同等兵力下，前锋合格而军师不合格；武力不足者亦不合格。
#   C5 真实战场推进：相邻接战多回合后，单挑记录只归属于合格角色。

const D = preload("res://scripts/war/duel/duel_system.gd")
const Role = preload("res://scripts/war/duel/officer_role.gd")
const Combat = preload("res://scripts/war/battle/combat_system.gd")

var failures: Array[String] = []
var checks := 0

func _initialize() -> void: call_deferred("run")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures.append(message)
		push_error(message)

func run() -> void:
	var store = root.get_node("GameState")
	store.persist_enabled = false
	store.prepare_battle_test(true)
	var war = store.war
	# 固定为无死亡／无俘获，避免资格验证被战死结果污染。
	war.rules["officer_fate"]["duel_death"] = 0.0
	war.rules["officer_fate"]["duel_capture"] = 0.0

	_roles(war)
	_eligibility(war)
	_live_battle(war)

	print("checks=%d failures=%d" % [checks, failures.size()])
	if failures.is_empty():
		print("VALIDATION OK duel_roles")
		quit(0)
	else:
		for f in failures: print("FAILED: " + f)
		print("VALIDATION FAILED duel_roles")
		quit(1)

# ---- 角色分类 --------------------------------------------------------------
func _roles(war) -> void:
	var zhuge := _find(war, "诸葛亮")
	check(not zhuge.is_empty(), "名册缺少诸葛亮，无法验证史实规则")
	if not zhuge.is_empty():
		check(Role.role(war, zhuge) == "strategist", "诸葛亮应判为军师，实际=" + Role.role(war, zhuge))
		check(not Role.can_duel(war, zhuge), "诸葛亮不应具备单挑资格")
	var guan := _find(war, "关羽")
	if not guan.is_empty():
		check(Role.role(war, guan) == "frontline", "关羽应判为前锋，实际=" + Role.role(war, guan))
		check(Role.can_duel(war, guan), "关羽应具备单挑资格")

# ---- 资格判定 --------------------------------------------------------------
func _eligibility(war) -> void:
	# 按角色挑选候选，而不是按数组下标——下标会把主帅（魏延）当作战场代表。
	var a := _first_duelist(war, "liu_bei")
	var b := _first_duelist(war, "yuan_shao")
	check(not a.is_empty() and not b.is_empty(), "测试战场缺少可单挑的前锋")
	# 强制双方为合格前锋，先证明基础路径可用。
	a["skills"]["武艺"] = 95; a["skills"]["膂力"] = 90; a["skills"]["体魄"] = 88; a["skills"]["骑术"] = 80
	b["skills"]["武艺"] = 92; b["skills"]["膂力"] = 88; b["skills"]["体魄"] = 86; b["skills"]["骑术"] = 78
	_setup_contact(war, a, b)
	check(D.eligible(war, a, b), "两名合格前锋相邻接战应可单挑")

	# C2 边界：把 b 换成诸葛亮型——武力低、定位军师，应立刻失去资格。
	var zhuge := _find(war, "诸葛亮")
	if not zhuge.is_empty():
		check(not Role.can_duel(war, zhuge), "诸葛亮型军师不应具备单挑资格")
		var saved: Dictionary = b["skills"].duplicate(true)
		b["skills"] = zhuge["skills"].duplicate(true)
		var officer_id: String = b["officer_id"]
		b["officer_id"] = str(zhuge["id"])
		check(not D.eligible(war, a, b), "军师型将领不应被选为单挑对象")
		check(D.challenge(war, a, b, true).is_empty(), "军师型将领不应能被强制发起单挑")
		b["officer_id"] = officer_id
		b["skills"] = saved
		check(D.eligible(war, a, b), "恢复前锋技能后应重新具备单挑资格")

	# 武力阈值边界：高定位但武力不足者仍不合格。
	var weak: Dictionary = b["skills"].duplicate(true)
	for k in ["武艺", "膂力", "体魄", "骑术"]: b["skills"][k] = 20
	check(not Role.can_duel(war, b), "个人武勇低于阈值不应具备单挑资格")
	b["skills"] = weak

# ---- 真实战场推进（C5） ----------------------------------------------------
func _live_battle(war) -> void:
	var journal: Dictionary = D.journal(war)
	var before: int = int(journal["records"].size())
	var allowed: Array = war.rules["duel"]["role_gate"]["allowed_roles"]
	var offenders: Array[String] = []
	# 真实发动概率约 0.1~0.25，12 个 tick 内只会有少量尝试，未加干预时“零单挑”是
	# 合法但不确定的结果。C5 要验证的是“谁”能单挑而不是“多常”发生，因此把发动率
	# 临时拉满，使场景确定性地产生单挑，再检查记录的归属角色。
	var saved_initiation: float = float(war.rules["duel"]["initiation"])
	war.rules["duel"]["initiation"] = 1.0
	war.rules["duel"]["acceptance"] = 1.0
	# 把三名合格前锋顶到相邻格并与敌军接战，其余战场原位不动；
	# 然后按真实 tick 推进，让 tactical_battlefield 之外的同一条 Duel 通道被反复调用。
	var friendlies: Array = war.active_armies("liu_bei").filter(func(x): return Role.can_duel(war, x) and x.has("tactical"))
	var hostiles: Array = war.active_armies("yuan_shao").filter(func(x): return Role.can_duel(war, x) and x.has("tactical"))
	print("LIVE_BATTLE_SETUP: friends=%d foes=%d" % [friendlies.size(), hostiles.size()])
	var pairs := mini(friendlies.size(), hostiles.size())
	for i in range(pairs):
		var f: Dictionary = friendlies[i]
		var h: Dictionary = hostiles[i]
		var own: int = war.Tactical.offset_cell(war.state["battlefield"], 0, i * 2)
		f["tactical"]["cell"] = own
		h["tactical"]["cell"] = war.Tactical.neighbors(own)[0]
		f["tactical"]["phase"] = "近战"
		h["tactical"]["phase"] = "近战"
		f["action"] = {"type": "engage"}
		h["action"] = {"type": "continue"}
		f["returning"] = false
		h["returning"] = false
		f.erase("duel_wounded")
		h.erase("duel_wounded")
		f.erase("first_contact_effect_tick")
		h.erase("first_contact_effect_tick")
	for tick in range(int(war.state["tick"]), int(war.state["tick"]) + 12):
		war.state["tick"] = tick
		for army in war.Tactical.participants(war):
			if not army.has("tactical") or not war.Tactical.can_attack(war, army): continue
			for enemy in war.Tactical.targets(war, army):
				if war.Tactical.distance(army, enemy) != 1: continue
				if not war.Tactical.can_attack(war, enemy): continue
				D.challenge(war, army, enemy)
				break
	var created: int = int(journal["records"].size()) - before
	for record in journal["records"].slice(before):
		for side in ["a", "b"]:
			var officer_id := str(record[side])
			var card: Dictionary = war.roster.officers.get(officer_id, {})
			if card.is_empty():
				offenders.append(officer_id + "(无名册档案)")
				continue
			var role_name := Role.role(war, card)
			if not role_name in allowed: offenders.append("%s(%s)" % [card.get("name", officer_id), role_name])
	print("LIVE_BATTLE: duels_created=%d offenders=%s" % [created, str(offenders)])
	war.rules["duel"]["initiation"] = saved_initiation
	check(created > 0, "真实战场推进未产生任何单挑，C5 无法证明")
	check(offenders.is_empty(), "单挑记录中出现不合格角色: " + str(offenders))

# ---- 工具 ------------------------------------------------------------------
func _first_duelist(war, faction: String) -> Dictionary:
	for army in war.active_armies(faction):
		if army.has("tactical") and Role.can_duel(war, army): return army
	return {}

func _find(war, officer_name: String) -> Dictionary:
	for officer in war.roster.officers.values():
		if str(officer.get("name", "")) == officer_name: return officer
	return {}

func _setup_contact(war, a: Dictionary, b: Dictionary) -> void:
	a["tactical"]["cell"] = war.Tactical.offset_cell(war.state["battlefield"], 0, 0)
	b["tactical"]["cell"] = war.Tactical.neighbors(a["tactical"]["cell"])[0]
	a["tactical"]["phase"] = "近战"
	b["tactical"]["phase"] = "近战"
	a["action"] = {"type": "engage"}
	b["action"] = {"type": "continue"}
	a["returning"] = false
	b["returning"] = false
	a.erase("first_contact_effect_tick")
	b.erase("first_contact_effect_tick")
