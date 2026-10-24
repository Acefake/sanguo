extends RefCounted

# 每名武将独立评估主帅军令：服从(obey)/异议(object)/自行行动(act)。
# 依据：本地性格（自尊/风险承受/忠义/秩序偏好/自制/野心/疑心）、与主帅的关系立场、
# 信任与怨气、危险态势。独立领兵者可执行本地合法战术候选；无兵参军只表态与建议，
# 不会私自带兵移动。全部掷点走 war.state["dissent_state"] 独立随机流，随存档可复现。

const Dissent = preload("res://scripts/agents/officer_dissent.gd")
const Structure = preload("res://scripts/war/campaign/corps_structure.gd")
const Tactical = preload("res://scripts/war/battle/tactical_battlefield.gd")

const OBEY := "obey"
const OBJECT := "object"
const ACT := "act"

const STANCE_LABELS := {"obey": "服从", "object": "异议", "act": "自行行动"}

static func params(war) -> Dictionary:
	var defaults := {
		"object_base": 0.06,
		"act_base": 0.03,
		"personality_weight": 0.0035,
		"danger_steady": -0.06,
		"danger_bold": 0.10,
		"max_object": 0.65,
		"max_act": 0.6,
		"refusal_ticks": 2,
		"forced_stance": "",
	}
	var section = war.rules.get("corps", {})
	var configured: Dictionary = section.get("autonomy", {}) if section is Dictionary else {}
	for key in defaults:
		if configured.has(key): defaults[key] = configured[key]
	return defaults

static func tick(war) -> int:
	return int(war.state.get("tick", 0))

static func label(stance: String) -> String:
	return str(STANCE_LABELS.get(stance, stance))

static func refusal_until(corps: Dictionary, officer: String) -> int:
	var table = corps.get("refusals", {})
	return int(table.get(officer, -1)) if table is Dictionary else -1

static func refused(war, corps: Dictionary, officer: String) -> bool:
	if officer.is_empty(): return false
	return tick(war) < refusal_until(corps, officer)

static func stance_of(corps: Dictionary, officer: String) -> Dictionary:
	var table = corps.get("autonomy", {})
	if not table is Dictionary: return {}
	var stances = table.get("stances", {})
	return stances.get(officer, {}) if stances is Dictionary else {}

static func latest_order(corps: Dictionary) -> Dictionary:
	var orders: Array = corps.get("orders", [])
	return orders[-1] if not orders.is_empty() and orders[-1] is Dictionary else {}

static func unit_for(war, corps: Dictionary, officer: String) -> Dictionary:
	for id in corps.get("units", []):
		var unit: Dictionary = war.state["armies"].get(id, {})
		if unit.is_empty() or unit.get("status", "ended") == "ended": continue
		if str(unit.get("officer_id", "")) == officer: return unit
	return {}

static func _p(personality: Dictionary, name: String) -> float:
	return float(personality.get(name, 50))

static func can_act(war, corps: Dictionary, officer: String) -> bool:
	var unit := unit_for(war, corps, officer)
	if not unit.is_empty(): return not unit.get("returning", false)
	return int(corps.get("node_strength", {}).get(officer, 0)) >= Structure.MIN_TROOP

static func danger_of(war, corps: Dictionary, unit: Dictionary) -> bool:
	if not unit.is_empty():
		var contact: Dictionary = war._observed_contact(unit) if unit.has("tactical") else {}
		return Dissent.urgent(unit, contact, war.supply_enabled())
	for id in corps.get("units", []):
		var other: Dictionary = war.state["armies"].get(id, {})
		if other.is_empty() or other.get("status", "ended") == "ended": continue
		if float(other.get("morale", 100)) < 35.0 or float(other.get("organization", 100)) < 30.0 or bool(other.get("returning", false)): return true
	return false

# 异议（拒绝执行当前军令）概率。
static func object_probability(war, corps: Dictionary, officer_id: String, order: Dictionary = {}) -> float:
	var p := params(war)
	if str(p.get("forced_stance", "")) != "":
		return 1.0 if str(p["forced_stance"]) in [OBJECT, ACT] else 0.0
	var officer: Dictionary = war.roster.officers.get(officer_id, {})
	if officer.is_empty(): return 0.0
	var personality: Dictionary = officer.get("personality", {})
	var commander: Dictionary = war.roster.officers.get(Structure.tree_parent(corps, officer_id), {})
	var relation: String = war.characters.relation_label(officer_id, str(commander.get("id", "")))
	var weight := float(p["personality_weight"])
	var proud := (_p(personality, "自尊") + _p(personality, "决断") + _p(personality, "野心")) / 3.0 - 50.0
	var loyal := (_p(personality, "忠义") + _p(personality, "秩序偏好") + _p(personality, "自制")) / 3.0 - 50.0
	var unit := unit_for(war, corps, officer_id)
	var trust := float(unit.get("trust", 0.0)) if not unit.is_empty() else 0.0
	var resent := float(unit.get("resentment", 0.0)) if not unit.is_empty() else 0.0
	var relation_mod: float = {"同袍": -0.06, "猜忌": 0.04, "宿怨": 0.08}.get(relation, 0.0)
	var risk := "常规"
	var root: Dictionary = war.state["armies"].get(str(corps.get("root_id", "")), {})
	if not root.is_empty(): risk = str(war.orders_for(root).get("risk_allowance", "常规"))
	var strict := 0.03 if risk == "保守" else -0.04 if risk == "放手" else 0.0
	var value := float(p["object_base"]) + proud * weight - loyal * weight + relation_mod + resent * 0.5 - trust * 0.5 + strict
	if danger_of(war, corps, unit): value += float(p.get("danger_steady", -0.06))
	return clampf(value, 0.0, float(p["max_object"]))

# 自行行动（抛开军令按本地判断用兵）概率；无兵参军恒为 0。
static func act_probability(war, corps: Dictionary, officer_id: String, order: Dictionary = {}) -> float:
	var p := params(war)
	if not can_act(war, corps, officer_id): return 0.0
	if str(p.get("forced_stance", "")) != "":
		return 1.0 if str(p["forced_stance"]) == ACT else 0.0
	var officer: Dictionary = war.roster.officers.get(officer_id, {})
	if officer.is_empty(): return 0.0
	var personality: Dictionary = officer.get("personality", {})
	var skills: Dictionary = officer.get("skills", {})
	var bold := (_p(personality, "风险承受") + _p(personality, "决断") + _p(personality, "自尊")) / 3.0 - 50.0
	var discipline := (_p(personality, "自制") + _p(personality, "秩序偏好") + _p(personality, "忠义")) / 3.0 - 50.0
	var capability := (float(skills.get("带兵", 50)) + float(skills.get("奇袭", 50))) / 2.0 - 50.0
	var value := float(p["act_base"]) + bold * 0.004 - discipline * 0.003 + capability * 0.002
	var unit := unit_for(war, corps, officer_id)
	if danger_of(war, corps, unit) and bold > 0.0: value += float(p.get("danger_bold", 0.10))
	return clampf(value, 0.0, float(p["max_act"]))

static func _reason(war, corps: Dictionary, officer_id: String, stance: String, order: Dictionary) -> String:
	var order_type := str(order.get("action", {}).get("type", "")) if order is Dictionary else ""
	var role := str(corps.get("appointments", {}).get(officer_id, Structure.ATTACHED_ROLE))
	var commander := str(war.roster.officers.get(str(corps.get("commander_id", "")), {}).get("name", "主帅"))
	match stance:
		OBJECT:
			if Structure.behavior_of(role) == "staff":
				return "不认同%s的用兵方略，保持异议但继续随军参谋" % commander
			return "拒绝执行%s的%s军令，本部就地持重观望" % [commander, order_type if not order_type.is_empty() else "当前"]
		ACT:
			return "不待%s军令，按本地敌情自行动作" % commander
	return "遵从%s军令" % commander

# 评估单名武将。order 为该武将当前面对的主帅命令（军团 orders 末条或本单位任务）。
static func evaluate_officer(war, corps: Dictionary, officer_id: String, order: Dictionary = {}) -> Dictionary:
	Structure.ensure(corps)
	var officer: Dictionary = war.roster.officers.get(officer_id, {})
	if officer.is_empty(): return {}
	var status: Dictionary = war.state.get("officer_states", {}).get(officer_id, {})
	if status.get("lost", false) or str(status.get("status", "")) in ["dead", "captured"]: return {}
	var p := params(war)
	var object_p := object_probability(war, corps, officer_id, order)
	var act_p := act_probability(war, corps, officer_id, order)
	var stance := OBEY
	var value := 0.0
	var forced := str(p.get("forced_stance", ""))
	if forced != "":
		stance = forced if forced in [OBEY, OBJECT, ACT] else OBEY
	else:
		value = Dissent.roll("%s:%s:%s:autonomy" % [str(war.state.get("dissent_seed", 0)), officer_id, str(int(order.get("tick", tick(war))))], war.state)
		if value < object_p: stance = OBJECT
		elif value < object_p + act_p: stance = ACT
	# 无法独立领兵者不会自行用兵：降级为异议，保留独立立场与建议。
	if stance == ACT and not can_act(war, corps, officer_id): stance = OBJECT
	var entry := {
		"stance": stance,
		"role": str(corps.get("appointments", {}).get(officer_id, Structure.ATTACHED_ROLE)),
		"tick": tick(war),
		"reason": _reason(war, corps, officer_id, stance, order),
		"order": str(order.get("action", {}).get("type", "")) if order is Dictionary else "",
		"object_probability": object_p,
		"act_probability": act_p,
		"roll": value,
	}
	if stance in [OBJECT, ACT]:
		corps["refusals"][officer_id] = tick(war) + int(p.get("refusal_ticks", 2))
	return entry

# 每日一次：全员独立表态（含无兵参军的异议）。主帅不参与对自己的评估。
static func evaluate_corps(war, corps: Dictionary) -> Dictionary:
	Structure.ensure(corps)
	var current: Dictionary = corps.get("autonomy", {})
	var now := tick(war)
	if int(current.get("tick", -1)) == now and str(current.get("commander", "")) == str(corps.get("commander_id", "")):
		return current
	var order: Dictionary = latest_order(corps)
	var stances := {}
	for value in corps.get("members", []):
		var id := str(value)
		if id == str(corps.get("commander_id", "")): continue
		var entry: Dictionary = stance_of(corps, id) if refused(war, corps, id) else evaluate_officer(war, corps, id, order)
		if entry.is_empty(): continue
		stances[id] = entry
	corps["autonomy"] = {"tick": now, "commander": str(corps.get("commander_id", "")), "order": {"type": str(order.get("action", {}).get("type", "")), "reason": str(order.get("reason", ""))}, "stances": stances}
	var history: Array = corps.get("autonomy_history", [])
	for id in stances:
		if str(stances[id].get("stance", OBEY)) != OBEY:
			history.append({"tick": now, "officer": id, "stance": stances[id]["stance"], "reason": stances[id]["reason"]})
	while history.size() > 40: history.pop_front()
	corps["autonomy_history"] = history
	return corps["autonomy"]

static func summary_rows(war, corps: Dictionary) -> Array:
	var rows: Array = []
	for value in corps.get("members", []):
		var id := str(value)
		if id == str(corps.get("commander_id", "")): continue
		var entry := stance_of(corps, id)
		if entry.is_empty(): continue
		var officer: Dictionary = war.roster.officers.get(id, {})
		rows.append({"id": id, "name": str(officer.get("name", id)), "role": str(entry.get("role", "")), "stance": str(entry.get("stance", OBEY)), "reason": str(entry.get("reason", ""))})
	return rows

# 异议/自行行动窗口内，主帅命令不得覆盖该将领的行动。
static func blocks_override(war, corps: Dictionary, officer_id: String) -> Dictionary:
	Structure.ensure(corps)
	if officer_id.is_empty() or not refused(war, corps, officer_id): return {"blocked": false}
	var entry := stance_of(corps, officer_id)
	return {"blocked": true, "stance": str(entry.get("stance", OBJECT)), "reason": str(entry.get("reason", "该将领已拒绝服从军令")), "until": refusal_until(corps, officer_id)}

# 单次订单评估：若该将领本日尚未表态，则面对“这一条新军令”立即独立评估。
# 每天每名将领至多新增一次掷点，既保证“同回合不被覆盖”，又不打乱每日节奏。
static func ensure_evaluated(war, corps: Dictionary, officer_id: String, order: Dictionary = {}) -> Dictionary:
	Structure.ensure(corps)
	var existing := stance_of(corps, officer_id)
	# 拒命窗口内不重新掷点：维持原独立立场，主帅无法在窗口内改写结果。
	if refused(war, corps, officer_id): return existing
	if int(existing.get("tick", -1)) == tick(war): return existing
	var entry := evaluate_officer(war, corps, officer_id, order)
	if entry.is_empty(): return {}
	var table = corps.get("autonomy", {})
	if not table is Dictionary: table = {}
	if not table.get("stances") is Dictionary: table["stances"] = {}
	table["stances"][officer_id] = entry
	corps["autonomy"] = table
	return entry

# 自行行动者在本地合法选项中择一：能打则按特长选择正面或侧翼，不能打则持守。
static func local_action(war, corps: Dictionary, unit: Dictionary) -> Dictionary:
	if unit.is_empty() or unit.get("status", "ended") == "ended" or unit.get("returning", false): return {"type": "continue"}
	if not unit.has("tactical"): return {"type": "hold"}
	if not war.orders_for(unit).get("engage", true): return {"type": "hold"}
	var enemies: Array = Tactical.targets(war, unit)
	if enemies.is_empty(): return {"type": "hold"}
	var ordered: Dictionary = Tactical.ordered_target(war, unit)
	if ordered.is_empty(): return {"type": "hold"}
	var officer: Dictionary = war.roster.officers.get(str(unit.get("officer_id", "")), {})
	var surprise := float(officer.get("skills", {}).get("奇袭", 50))
	return {"type": "flank", "enemy": str(ordered["id"])} if surprise >= 75.0 else {"type": "engage", "enemy": str(ordered["id"])}
