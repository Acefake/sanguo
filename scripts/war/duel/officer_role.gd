extends RefCounted

# 角色定位（Battlefield Role）——单挑与战场行为的第一层判定。
#
# 设计目标：将领在战场上的行为由其档案中的职能定位与能力决定，而不是由阵营、
# 名字或调用顺序决定。“主帅／军师”型人物不会亲自单挑；前锋、
# 武将型人物才会。判定只用两类客观输入：
#
#   1. 档案文本 `positions`（data/officers.json 的 sections.位置），形如
#      “核心位置：前锋 / 次选位置：偏将、护军 / 不宜位置：治政、外交主谈”。
#      档案显式写明的“不宜位置”拥有最高优先级——数据作者已经判断过。
#   2. 能力数值：stats[2]（武力）与技能 武艺／膂力／骑术／体魄。
#
# 任何一条缺失（地方守备、剧本生成的补位将领）都会退化为能力判定，
# 绝不因为缺字段就让人物失去行为能力。
#
# 角色取值（与 duel.role_gate 允许的集合一致）：
#   "commander"  主帅：统军坐镇，非必要不单挑
#   "strategist" 军师：谋略与布阵，不参与单挑
#   "frontline"  前锋／偏将：正面接战，可单挑
#   "duelist"    专职猛将：以个人武力见长，最优先单挑
#   "civil"      治政／军需：不入战阵
#   "guard"      守备／地方补位：被动守城，可应对挑战

const ROLES := ["commander", "strategist", "frontline", "duelist", "civil", "guard"]

# 位置文本 → 角色。顺序即优先级：先匹配到的更具体的位置胜出。
# “主帅”先于“前锋”列出，因为“核心位置：主帅、军师”这类组合文本应优先判为主帅。
const POSITION_ROLES := [
	["主帅", "commander"], ["都督", "commander"], ["总帅", "commander"],
	["军师", "strategist"], ["参军", "strategist"], ["谋士", "strategist"], ["幕僚", "strategist"],
	["前锋", "frontline"], ["先锋", "frontline"], ["偏将", "frontline"], ["护军", "frontline"], ["副帅", "frontline"], ["守将", "guard"], ["殿后", "guard"], ["奇兵", "frontline"],
	["猛将", "duelist"],
	["治政", "civil"], ["军需", "civil"], ["后勤", "civil"], ["文官", "civil"], ["太守", "civil"],
	["守备", "guard"], ["地方将领", "guard"],
]

const ROLE_MARTIAL := {
	"commander": 0.45,
	"strategist": 0.0,
	"frontline": 1.0,
	"duelist": 1.15,
	"civil": 0.0,
	"guard": 0.75,
}

static func config(war) -> Dictionary:
	return war.rules.get("duel", {})

# 判定一名将领（军队字典或名册档案）的角色。
# 接受两种输入：已组建的军队（含 officer_id/skills/units），或名册档案本身。
static func role(war, officer_or_army: Dictionary) -> String:
	var card := _card(war, officer_or_army)
	var explicit := str(card.get("battlefield_role", officer_or_army.get("battlefield_role", "")))
	if explicit in ROLES and not _vetoed(str(card.get("positions", "")), explicit): return explicit
	if card.is_empty() and officer_or_army.has("skills"):
		# 无名册档案（剧本补位将领）时退回军队自身的技能表。
		return _role_from_ability(officer_or_army, "")
	return _role_from_card(card, officer_or_army)

static func _card(war, subject: Dictionary) -> Dictionary:
	var roster = war.get("roster")
	if roster == null: return {}
	var id := str(subject.get("officer_id", subject.get("id", "")))
	if id == "" : return {}
	return roster.officers.get(id, {})

static func _role_from_card(card: Dictionary, subject: Dictionary) -> String:
	var positions := str(card.get("positions", ""))
	var from_text := _role_from_positions(positions)
	if from_text != "": return from_text
	return _role_from_ability(subject if subject.has("skills") else card, positions)

static func _role_from_positions(positions: String) -> String:
	if positions.strip_edges() == "": return ""
	var secondary := ""
	var core_set := []
	for raw_line in positions.split("\n"):
		var line := raw_line.strip_edges()
		if line == "": continue
		var target := ""
		if line.begins_with("核心位置"): target = "core"
		elif line.begins_with("次选位置"): target = "secondary"
		elif line.begins_with("不宜位置"): target = "unfit"
		elif line.begins_with("位置说明") or line.begins_with("说明"): continue
		else: target = "core"
		if target == "unfit": continue
		var body := line.split("：", true, 1)
		var text := body[1] if body.size() > 1 else body[0]
		# 带数值的位置文本（“前锋 105｜副帅 91”）只取前段名称。
		for part in text.replace("｜", "、").split("、"):
			var token := part.strip_edges().split(" ")[0].split("　")[0]
			if token == "": continue
			var mapped := _role_of_token(token)
			if mapped == "": continue
			if target == "core":
				if not mapped in core_set: core_set.append(mapped)
			elif secondary == "": secondary = mapped
	# 核心位置可能列出多个职位（“主帅、军师”）。决策与谋划型身份优先表达：
	# 一人若同时是主帅与军师，其角色定位以谋略职能标示。
	# 这不影响可单挑性——两者都不在 allowed_roles 内。
	for priority in ["strategist", "commander", "duelist", "frontline", "civil", "guard"]:
		if priority in core_set and not _vetoed(positions, priority): return priority
	if secondary != "" and not _vetoed(positions, secondary): return secondary
	return ""

static func _vetoed(positions: String, role_name: String) -> bool:
	for raw_line in positions.split("\n"):
		var line := raw_line.strip_edges()
		if not line.begins_with("不宜位置"): continue
		var body := line.split("：", true, 1)
		var text := body[1] if body.size() > 1 else body[0]
		for part in text.replace("｜", "、").split("、"):
			if _role_of_token(part.strip_edges().split(" ")[0]) == role_name: return true
	return false

static func _role_of_token(token: String) -> String:
	for row in POSITION_ROLES:
		if token.contains(row[0]): return row[1]
	return ""

# 无位置文本时的能力判定：以武力／武艺为主，谋略为反向指标。
static func _role_from_ability(subject: Dictionary, positions: String) -> String:
	if subject.is_empty(): return "guard"
	var martial := _martial_score(subject)
	var intellect := _intellect_score(subject)
	if martial >= 85.0 and martial - intellect >= 15.0: return "duelist"
	if martial >= 70.0: return "frontline"
	if intellect >= 80.0: return "strategist"
	if martial >= 55.0: return "guard"
	return "civil"

static func _skill(subject: Dictionary, name: String) -> float:
	var skills: Dictionary = subject.get("skills", {})
	return float(skills.get(name, 50))

# 资格评分只用于角色与门槛；实际单挑评分由勇武主属性和当前模式决定。
static func martial_score(subject: Dictionary) -> float:
	return _martial_score(subject)

static func _martial_score(subject: Dictionary) -> float:
	return _skill(subject, "武艺") * 0.5 + _skill(subject, "膂力") * 0.3 + _skill(subject, "体魄") * 0.2 + _skill(subject, "骑术") * 0.1

static func _intellect_score(subject: Dictionary) -> float:
	return _skill(subject, "智计") * 0.5 + _skill(subject, "料敌") * 0.3 + _skill(subject, "应变") * 0.2

# 单挑资格：角色必须在允许集合内，且个人武勇达到阈值。
static func can_duel(war, subject: Dictionary) -> bool:
	return can_initiate(war, subject)

static func can_initiate(war, subject: Dictionary) -> bool:
	return _qualified(war, subject, false)

static func can_accept(war, subject: Dictionary) -> bool:
	return _qualified(war, subject, true)

static func _qualified(war, subject: Dictionary, accepting: bool) -> bool:
	var gate: Dictionary = config(war).get("role_gate", {})
	if not bool(gate.get("enabled", true)): return true
	if role(war, subject) not in gate.get("allowed_roles", ["frontline", "duelist", "guard"]): return false
	var info := _card(war, subject)
	var threshold := float(gate.get("accept_min_martial", 20.0)) if accepting else float(gate.get("min_martial", 60.0))
	return martial_score(subject if subject.has("skills") else info) >= threshold

# 单挑意愿／主导度权重：武力越强、角色越靠前，越可能主动挑战或应战。
static func duel_weight(war, subject: Dictionary) -> float:
	var gate: Dictionary = config(war).get("role_gate", {})
	var weights: Dictionary = gate.get("role_weights", {})
	return float(weights.get(role(war, subject), weights.get("default", 1.0)))

# 从候选名单中挑出最合适的单挑人选（供战场与行军会战选择挑战者使用）。
# 无人合格时返回空字典，调用方应放弃本次单挑而不是随便挑一个。
static func best_duelist(war, candidates: Array) -> Dictionary:
	var best: Dictionary = {}
	var best_score := -1.0
	for candidate in candidates:
		if not can_duel(war, candidate): continue
		var score := martial_score(candidate) * duel_weight(war, candidate)
		if score > best_score:
			best_score = score
			best = candidate
	return best

static func label(role_name: String) -> String:
	match role_name:
		"commander": return "主帅"
		"strategist": return "军师"
		"frontline": return "前锋"
		"duelist": return "猛将"
		"civil": return "文官"
		"guard": return "守备"
	return "将领"
