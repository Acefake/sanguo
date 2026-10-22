class_name OfficerDissent
extends RefCounted
## 军令书与违令的规则层：将领关系、违令概率、主副搭配提示。

# 军令书与违令的规则层：将领关系（由人格轴推导）、违令概率与主副搭配提示。
# 全部确定性，不消耗战斗随机数；概率最后记录进决策记录，随种子可复现。


static func axis(officer: Dictionary, name: String) -> float:
	return float(officer.get("personality", {}).get(name, 50))


## a 对 b 的关系类别。人物卡写了 a→b 有向边时按边定（怨恨≥40 宿怨、怨恨≥20 或信任<35 猜忌、
## 信任≥70 且怨恨<10 同袍）；没写边的（生成将、守备将、卡外人物）按人格轴推导。
static func relation(a: Dictionary, b: Dictionary) -> String:
	if a.is_empty() or b.is_empty() or str(a.get("id", "")) == str(b.get("id", "")): return "中立"
	for edge in a.get("relations", []):
		if str(edge.get("to", "")) != str(b.get("name", "")): continue
		if float(edge["怨恨"]) >= 40.0: return "宿怨"
		if float(edge["怨恨"]) >= 20.0 or float(edge["信任"]) < 35.0: return "猜忌"
		if float(edge["信任"]) >= 70.0 and float(edge["怨恨"]) < 10.0: return "同袍"
		return "中立"
	var score := (axis(a, "记仇") - 50.0) * 0.45 + (axis(a, "猜疑") - 50.0) * 0.25 - (axis(a, "容人") - 50.0) * 0.3 - (axis(b, "容人") - 50.0) * 0.2 - (axis(b, "忠义") - 50.0) * 0.15
	if score >= 18.0: return "宿怨"
	if score >= 8.0: return "猜忌"
	if score <= -12.0: return "同袍"
	return "中立"


static func probability(army: Dictionary, personality: Dictionary, orders: Dictionary, relation_name: String, urgent: bool, counter_intel: float, params: Dictionary) -> float:
	var weight := float(params.get("personality_weight", 0.004))
	var bold := ((_p(personality, "自尊") + _p(personality, "风险承受") + _p(personality, "决断")) / 3.0 - 50.0) * weight
	var loyal := ((_p(personality, "忠义") + _p(personality, "秩序偏好") + _p(personality, "自制")) / 3.0 - 50.0) * weight
	var urgency := float(params.get("urgent_bonus", 0.1)) if urgent else 0.0
	var relation_mod: float = float({"同袍": -0.05, "猜忌": 0.03, "宿怨": 0.05}.get(relation_name, 0.0))
	var strictness := 0.0
	if str(orders.get("intent", "稳扎")) in ["稳扎", "牵制", "保存实力"]: strictness += 0.03
	var risk := str(orders.get("risk_allowance", "常规"))
	if risk == "放手": strictness -= 0.04
	elif risk == "保守": strictness += 0.04
	var value := float(params.get("base", 0.15)) + bold - loyal + urgency + relation_mod + counter_intel + strictness + float(army.get("resentment", 0.0)) - float(army.get("trust", 0.0))
	return clampf(value, 0.0, float(params.get("max", 0.6)))


static func _p(personality: Dictionary, name: String) -> float:
	return float(personality.get(name, 50))


# 违令掷点。key 只能包含剧本种子、部队与当日，不得包含战斗随机流的快照，
# 否则任何一处战斗差异都会改写违令结果。war.state 持有这条独立随机流的状态，
# 它既不消耗 battle rng，也随存档往返。
static func roll(key: String, war_state: Dictionary = {}) -> float:
	var carried := int(war_state.get("dissent_state", 0))
	if carried == 0:
		# 首次掷点：从 key 派生起点，之后按序推进，保证同一存档重放得到同一条序列。
		carried = hash(key) & 0x7FFFFFFF
		if carried == 0: carried = 1
	var rng := RandomNumberGenerator.new()
	rng.seed = carried
	var value := rng.randf()
	war_state["dissent_state"] = int(rng.state)
	return value


static func urgent(army: Dictionary, contact: Dictionary, supply_enabled: bool = true) -> bool:
	if float(army.get("morale", 100)) < 35.0 or float(army.get("organization", 100)) < 30.0: return true
	# 粮草系统停用时 grain 恒为 0，不加这道判断 urgent 就恒真，违令概率被系统性
	# 抬高 +0.1（0.15→0.25），而该模式下断粮根本不是理由。
	if supply_enabled and float(army.get("grain", 0)) < 1.0: return true
	if bool(contact.get("flanked", false)): return true
	var initial := float(army.get("initial_strength", 0))
	var strength := 0.0
	for value in army.get("units", {}).values(): strength += float(value)
	return initial > 0.0 and strength <= initial * 0.6


static func pairing_hint(commander: Dictionary, member: Dictionary) -> String:
	var c := _profile(commander)
	var m := _profile(member)
	var commander_steady: bool = c >= 0.0
	var member_steady: bool = m >= 0.0
	if commander_steady and member_steady: return "主副持重：军团偏守势，稳中求进"
	if commander_steady and not member_steady: return "主稳副冒：副将更可能领侧翼或独立奔袭"
	if not commander_steady and member_steady: return "主冒副稳：副将可能被留在预备队压阵"
	return "主副皆冒进：军团整体风险上升，注意保留预备队"


static func _profile(officer: Dictionary) -> float:
	var bold := (axis(officer, "野心") + axis(officer, "风险承受") + axis(officer, "决断")) / 3.0
	var steady := (axis(officer, "自制") + axis(officer, "耐心") + axis(officer, "秩序偏好")) / 3.0
	return steady - bold
