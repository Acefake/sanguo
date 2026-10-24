class_name PeopleCharacterBridge
extends RefCounted
## 人物系统（scripts/people）与 characters 系统（scripts/officers/character_*）之间的换算层。纯函数，不读写状态。
##
## 分工：characters 管属性、成长、年龄、伤病、岗位适配、寻访招募，以及人物之间的关系值；people 管心志、圈子、记忆、生平。
## 关系值只存在 CharacterSystem.relations 一处，people 经 PersonStore.relation()/relation_event() 读写，这里只换维度名。
## 人物包的人物（官渡卡）不在名册里时，由 PersonStore 用这里换算出的定义收录进 characters（CharacterSystem.adopt）。
##
## 官渡卡（schema 6，迁移后 schema 7）与 character_model 卡面的差别：
##   - 字段名：attributes → base_attributes，potentials → potential_by_attribute，courtesy_name → style_name，
##     birth_year → birth {year, precision}；25 项属性名两边相同，不换。
##   - 兵种：步兵/骑兵/弓弩/水军/攻城 → infantry/cavalry/archers/navy/siege，等级 S–D 两边相同。
##   - 地形：平原…水域 → plains…water（沼泽→wetland、河岸→river，与 CharacterSystem.normalize_terrain 一致），
##     熟练度 陌生/熟悉/精通 → unfamiliar/familiar/expert。
##   - 关系维度：信任/敬重/恩义/利益/怨恨 → trust/respect/gratitude/interest/resentment。
##     人物系统的 familiarity（熟识）在 characters 没有对应轴，不换算，见 RELATION_UNMAPPED。

const TROOPS := {"步兵": "infantry", "骑兵": "cavalry", "弓弩": "archers", "水军": "navy", "攻城": "siege"}
const TERRAINS := {"平原": "plains", "丘陵": "hills", "山地": "mountains", "谷道": "canyon", "森林": "forest",
	"沼泽": "wetland", "河岸": "river", "城邑": "city", "关隘": "pass", "水域": "water"}
const TERRAIN_RANKS := {"陌生": "unfamiliar", "熟悉": "familiar", "精通": "expert"}
const RELATION_AXES := {"信任": "trust", "敬重": "respect", "恩义": "gratitude", "利益": "interest", "怨恨": "resentment"}
## 人物系统有、characters 没有对应轴的关系维度。
const RELATION_UNMAPPED := ["familiarity"]


## 官渡卡 → CharacterModel.definition() 读的卡面字段。卡上没有的项不填，由 character_model 标为待校准。
static func character_card(card: Dictionary) -> Dictionary:
	var troops := {}
	for name in card.get("troop_aptitudes", {}):
		if TROOPS.has(name): troops[TROOPS[name]] = card["troop_aptitudes"][name]
	var terrains := {}
	for name in card.get("terrain_experience", {}):
		if TERRAINS.has(name): terrains[TERRAINS[name]] = TERRAIN_RANKS.get(str(card["terrain_experience"][name]))
	var birth_year := int(card.get("birth_year", 0))
	var sources: Array = card.get("sources", [])
	return {
		"base_attributes": card.get("attributes", {}).duplicate(true),
		"potential_by_attribute": card.get("potentials", {}).duplicate(true),
		"troop_aptitudes": troops,
		"terrain_experience": terrains,
		"style_name": str(card.get("courtesy_name", "")),
		"birth": {"year": birth_year, "precision": "year"} if birth_year > 0 else {"year": null, "precision": "unknown"},
		"source": str(sources[0].get("url", "")) if not sources.is_empty() and sources[0] is Dictionary else "",
	}


## 官渡卡 → CharacterModel 要的人物字典（id、名字、世界剧本势力 id）。faction_id 是迁移后 schema 7 卡上的字段。
static func character_officer(card: Dictionary) -> Dictionary:
	return {"id": str(card["id"]), "name": str(card["name"]), "faction": str(card.get("faction_id", ""))}


## 人物系统的关系变化 {信任: 4, …} → characters 的 {trust: 4, …}。有换算不了的维度时返回 {ok: false, unmapped}。
static func to_character_axes(changes: Dictionary) -> Dictionary:
	var mapped := {}
	var unmapped: Array = []
	for dim in changes:
		if RELATION_AXES.has(dim): mapped[RELATION_AXES[dim]] = changes[dim]
		else: unmapped.append(dim)
	return {"ok": unmapped.is_empty(), "changes": mapped, "unmapped": unmapped}


## characters 的关系边 → 人物系统维度名；边不存在时为空字典。只换五条轴，不带事件明细。
static func from_character_edge(edge: Dictionary) -> Dictionary:
	var out := {}
	if edge.is_empty(): return out
	for dim in RELATION_AXES: out[dim] = float(edge.get(RELATION_AXES[dim], 0.0))
	return out
