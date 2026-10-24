class_name OfficerCard
extends RefCounted
## 官渡 schema 6 人物卡（data/scenarios/guandu/officers.json）到运行时人物字段的换算点。
##
## 新 main 只移植人物系统要用的两项：14 条人格轴与生效特性 id。卡面到战斗运行时键（runtime_skills）、
## 武将页视图（page_view）等换算随「官渡 20 人卡接入名册」一步再移植，届时在这个文件里补齐。
## 人格轴换算：风险承受=风险偏好、耐心=防御偏好（缺省 1−风险偏好）、秩序偏好=秩序、野心=功业、
## 贪欲=个人利益、忠义=承诺坚持，均 ×100；卡面没有对应量的轴记 50，并在 sources 里标出。

## 人格轴 ← 卡面字段（路径, 是否取 1−值）。
const AXIS_FROM_CARD := {"风险承受": ["risk_preference", false], "耐心": ["defense_preference", false],
	"秩序偏好": ["values.秩序", false], "野心": ["values.功业", false], "贪欲": ["values.个人利益", false],
	"忠义": ["loyalty.承诺坚持", false]}


## 运行时人格轴（axes 给出轴名与顺序），返回 {personality, sources}。
static func personality_axes(card: Dictionary, axes: Array) -> Dictionary:
	var p: Dictionary = card.get("personality", {})
	var result := {}
	var sources := {}
	for axis in axes:
		var rule: Array = AXIS_FROM_CARD.get(axis, [])
		var raw: Variant = _path(p, str(rule[0])) if not rule.is_empty() else null
		if raw == null and axis == "耐心" and p.has("risk_preference"): raw = 1.0 - float(p["risk_preference"])
		if raw == null:
			result[axis] = 50
			sources[axis] = "not_in_card"
		else:
			result[axis] = int(round(clampf(float(raw), 0.0, 1.0) * 100.0))
			sources[axis] = "card:" + (str(rule[0]) if not rule.is_empty() else "1-risk_preference")
	return {"personality": result, "sources": sources}


## 生效特性：技术特性 + 人格型局限（卡面 personality.flaws）。
static func trait_ids(card: Dictionary) -> Array:
	var ids: Array = card.get("traits", []).map(func(t): return str(t["id"]))
	ids.append_array(card.get("personality", {}).get("flaws", []).map(func(f): return str(f["id"])))
	return ids


static func _path(data: Dictionary, path: String) -> Variant:
	var node: Variant = data
	for part in path.split("."):
		if not node is Dictionary or not node.has(part): return null
		node = node[part]
	return node
