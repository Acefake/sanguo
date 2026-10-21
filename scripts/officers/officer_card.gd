extends RefCounted
## 人物卡（OfficerRepository，schema 6）到运行时人物字典的唯一换算点。
##
## 卡面用人物系统 GDD v0.3.1 的字典：25 项子属性（统兵…容人）、五兵种适性、十类地形、
## 价值倾向/风险偏好/忠诚三轴、有向关系边、推荐/不宜岗位、技术特性与人格型局限。
## 战斗代码沿用旧的运行时键（带兵、布阵、辩才……）和 14 条人格轴，换算全部在这里，
## 调用方不再读卡面原始字段。换算规则：
##   - 子属性：同义的直接改名（统兵→带兵、机动→布阵 等，见 RUNTIME_KEY）；攻坚保留原名；
##     水练没有 GDD 对应项，按水军适性折算（WATER_FROM_APTITUDE），只在河流/渡口作战时读取。
##   - 人格轴：风险承受=风险偏好、耐心=防御偏好（缺省 1−风险偏好）、秩序偏好=秩序、野心=功业、
##     贪欲=个人利益、忠义=承诺坚持，均 ×100；卡面没有对应量的轴记 50，并在 data_sources 里标出。

const GDD_ATTRIBUTES := ["统兵", "攻坚", "机动", "奇袭", "治军", "智计", "沉着", "料敌", "应变", "辩论",
	"膂力", "体魄", "武艺", "骑术", "射术", "农桑", "财赋", "吏治", "法度", "外交",
	"威仪", "仁德", "信义", "名望", "容人"]
const DIMENSIONS := ["军事", "谋略", "勇武", "政务", "影响"]
const TROOPS := ["步兵", "骑兵", "弓弩", "水军", "攻城"]
const TERRAIN := ["平原", "丘陵", "山地", "谷道", "森林", "沼泽", "河岸", "城邑", "关隘", "水域"]
## GDD 名 → 运行时键；不在表里的同名。
const RUNTIME_KEY := {"统兵": "带兵", "机动": "布阵", "辩论": "辩才", "射术": "箭术", "财赋": "商贾",
	"法度": "律法", "外交": "辞令", "信义": "忠义", "容人": "雅量"}
const WATER_FROM_APTITUDE := {"S": 95, "A": 80, "B": 65, "C": 50, "D": 35}
## 人格轴 ← 卡面字段（路径, 是否取 1−值）。
const AXIS_FROM_CARD := {"风险承受": ["risk_preference", false], "耐心": ["defense_preference", false],
	"秩序偏好": ["values.秩序", false], "野心": ["values.功业", false], "贪欲": ["values.个人利益", false],
	"忠义": ["loyalty.承诺坚持", false]}
const POST_ORDER := ["core", "secondary", "unsuitable"]
const POST_LABEL := {"core": "核心位置", "secondary": "次选位置", "unsuitable": "不宜位置"}


## 运行时键 → 卡面显示名（署名、面板用 GDD 名）。
static func label(runtime_key: String) -> String:
	for gdd in RUNTIME_KEY:
		if RUNTIME_KEY[gdd] == runtime_key: return gdd
	return runtime_key


## 运行时 skills：25 个旧键 + 攻坚，返回 {skills, sources}。
static func runtime_skills(card: Dictionary) -> Dictionary:
	var attributes: Dictionary = card.get("attributes", {})
	var skills := {}
	var sources := {}
	for key in GDD_ATTRIBUTES:
		var runtime := str(RUNTIME_KEY.get(key, key))
		skills[runtime] = int(attributes.get(key, 50))
		sources[runtime] = "card" if attributes.has(key) else "missing_default"
	var water := str(card.get("troop_aptitudes", {}).get("水军", ""))
	skills["水练"] = int(WATER_FROM_APTITUDE.get(water, 50))
	sources["水练"] = "derived:水军适性" if WATER_FROM_APTITUDE.has(water) else "missing_default"
	return {"skills": skills, "sources": sources}


## 运行时 14 条人格轴，返回 {personality, sources}。
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


## 生效特性：技术特性（GDD 8.1 数量预算内）+ 人格型局限（卡面 personality.flaws）。
static func trait_ids(card: Dictionary) -> Array:
	var ids: Array = card.get("traits", []).map(func(t): return str(t["id"]))
	ids.append_array(card.get("personality", {}).get("flaws", []).map(func(f): return str(f["id"])))
	return ids


## 推定条目：卡面标 inferred 的特性与人格局限。
static func inferred_trait_ids(card: Dictionary) -> Array:
	var ids: Array = []
	for entry in card.get("traits", []) + card.get("personality", {}).get("flaws", []):
		if bool(entry.get("inferred", false)) or str(entry.get("source", "")) == "draft": ids.append(str(entry["id"]))
	return ids


## trait_registry 的人物配置：{"officers": {id: {name, trait_ids, inferred, no_flaw_reason}}}。
static func assignments(cards: Array) -> Dictionary:
	var officers := {}
	for card in cards:
		officers[str(card["id"])] = {"name": str(card["name"]), "trait_ids": trait_ids(card), "inferred": inferred_trait_ids(card), "no_flaw_reason": str(card.get("no_flaw_reason", "")), "budget_exception": str(card.get("gdd_exceptions", {}).get("trait_budget", "")) if str(card.get("status", "")) == "source" else ""}
	return {"officers": officers}


## 岗位文本，格式与 army_corps.suitability、生成将模板一致。
static func positions_text(card: Dictionary) -> String:
	var posts: Dictionary = card.get("posts", {})
	var lines: Array = []
	for key in POST_ORDER:
		var names: Array = posts.get(key, [])
		if not names.is_empty(): lines.append("%s：%s" % [POST_LABEL[key], "、".join(names)])
	return "\n".join(lines)


## 五维（展示用）：子属性算术平均，四舍五入取整。
static func dimensions(card: Dictionary) -> Array:
	var attributes: Dictionary = card.get("attributes", {})
	var result: Array = []
	for group in range(5):
		var total := 0.0
		for index in range(5): total += float(attributes.get(GDD_ATTRIBUTES[group * 5 + index], 0))
		result.append(int(round(total / 5.0)))
	return result


## 人物页使用的展示视图：stats（五维）、substats（5×5，GDD 顺序）与按小节组织的文本；特性条由人物页按注册表补上。
static func page_view(card: Dictionary) -> Dictionary:
	var attributes: Dictionary = card.get("attributes", {})
	var substats: Array = []
	var rows: Array = []
	for group in range(5):
		var row: Array = []
		var text: Array = []
		for index in range(5):
			var key: String = GDD_ATTRIBUTES[group * 5 + index]
			row.append(int(attributes.get(key, 0)))
			text.append("%s %d" % [key, int(attributes.get(key, 0))])
		substats.append(row)
		rows.append("%s：%s" % [DIMENSIONS[group], "｜".join(text)])
	var stats := dimensions(card)
	# 人格页显示卡面原值（GDD 3.2 的价值倾向/风险/忠诚三轴，×100），不显示换算出来的运行时轴。
	var p: Dictionary = card.get("personality", {})
	var axes_text: Array = []
	for key in p.get("values", {}): axes_text.append("%s %d" % [key, int(round(float(p["values"][key]) * 100.0))])
	axes_text.append("风险偏好 %d" % int(round(float(p.get("risk_preference", 0.5)) * 100.0)))
	for key in p.get("loyalty", {}): axes_text.append("%s %d" % [key, int(round(float(p["loyalty"][key]) * 100.0))])
	var relations: Array = card.get("relations", []).map(func(r): return "%s→%s：信任 %d／敬重 %d／恩义 %d／利益 %d／怨恨 %d" % [card["name"], r["to"], r["信任"], r["敬重"], r["恩义"], r["利益"], r["怨恨"]])
	var sections := {
		"定位": str(card.get("summary", "")),
		"核心定义": str(card.get("summary", "")),
		"五维": "\n".join(range(5).map(func(i): return "%s %d" % [DIMENSIONS[i], stats[i]])),
		"位置": positions_text(card),
		"25项子属性": "\n".join(rows),
		"关系": "\n".join(relations),
		"人格数值": "｜".join(axes_text),
		"性格": str(card.get("personality", {}).get("behavior", "")),
		"失败模式": "\n".join(card.get("failure_modes", []).map(func(f): return str(f["text"]))),
		"史实": str(card.get("history", "")),
	}
	return {"id": str(card["id"]), "name": str(card["name"]), "style_name": str(card.get("courtesy_name", "—")), "faction": str(card.get("faction", "")),
		"status": str(card.get("status", "")), "stats": stats, "substats": substats, "sections": sections,
		"portrait": str(card.get("portrait", "res://assets/officers/portrait.png")), "thumbnail": str(card.get("thumbnail", "")),
		"source": str(card.get("sources", [{}])[0].get("url", ""))}


static func _path(data: Dictionary, path: String) -> Variant:
	var node: Variant = data
	for part in path.split("."):
		if not node is Dictionary or not node.has(part): return null
		node = node[part]
	return node
