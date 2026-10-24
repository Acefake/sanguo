extends SceneTree
## 人物系统 ↔ characters 适配：官渡卡经 PeopleCharacterBridge 换算后能被 character_model 完整读取（不缺项、兵种地形换成英文枚举）；
## 载入人物包时 20 人收录进当前战役的 characters，名册人物的定义与状态逐字不变，重复载入不重复收录；
## 属性从 characters 读；关系值只存在 characters.relations，People 用中文维度名读写、存档里没有自己的关系表；
## 宿主重建 characters 或换掉 war 后取用前补收录；没有 characters 的 Store 不收录、关系读写为空。
##
##   godot --headless --path . --script res://tests/people/character_bridge_validation.gd

const Store = preload("res://scripts/people/person_store.gd")
const Migrate = preload("res://scripts/people/card_migrate.gd")
const Bridge = preload("res://scripts/people/character_bridge.gd")
const Model = preload("res://scripts/officers/character_model.gd")

var failures: Array[String] = []


func check(value: bool, message: String) -> void:
	if not value:
		failures.append(message)
		push_error(message)


func roster_snapshot(characters, ids: Array) -> String:
	var out := {}
	for id in ids: out[id] = {"definition": characters.definitions.get(id), "state": characters.states.get(id)}
	return JSON.stringify(out, "", true)


## GameState 的 _ready（建 war、设 characters_source）在 _initialize 之后才跑，所以推迟一帧。
func _initialize() -> void:
	call_deferred("run")


func run() -> void:
	var migrated := Migrate.migrate_all(Store.pack_cards("guandu"), Store.read_json(Store.DATA_DIR + "guandu/persons_s7.json"))
	for card in migrated:
		var officer := Bridge.character_officer(card)
		var def := Model.definition(Bridge.character_card(card), officer)
		check(Model.validate(def).is_empty() and def["calibration_required"].is_empty(), "%s 换算后应能完整读取：%s" % [card["id"], str(Model.validate(def))])
		check(def["base_attributes"]["统兵"] == card["attributes"]["统兵"] and def["potential_by_attribute"]["名望"] == card["potentials"]["名望"], "%s 属性与潜力原样" % card["id"])
		check(def["troop_aptitudes"]["cavalry"] == card["troop_aptitudes"]["骑兵"] and def["birth"]["year"] == card["birth_year"], "%s 兵种适性与生年" % card["id"])
	var yuan: Dictionary = migrated.filter(func(c): return c["id"] == "ys_001")[0]
	var yuan_def := Model.definition(Bridge.character_card(yuan), Bridge.character_officer(yuan))
	check(yuan_def["terrain_experience"]["plains"] == "unfamiliar" and yuan_def["terrain_experience"]["canyon"] == "expert" and yuan_def["terrain_experience"]["wetland"] == "unfamiliar", "地形与熟练度换成 character_model 枚举")
	check(not Bridge.to_character_axes({"familiarity": 1.0})["ok"] and Bridge.to_character_axes({"信任": 1.0, "怨恨": 2.0})["changes"] == {"trust": 1.0, "resentment": 2.0}, "关系维度换算；familiarity 没有对应轴")

	var game: Node = root.get_node("GameState")
	var people: Node = root.get_node("People")
	var characters = game.war.characters
	var roster_ids: Array = characters.definitions.keys()
	var before := roster_snapshot(characters, roster_ids)
	var relations_before := JSON.stringify(characters.relations, "", true)
	check(people.load_scenario("guandu"), "官渡人物包应载入")
	check(people.persons.keys().all(func(id): return characters.definitions.has(id) and characters.states.has(id)), "20 人应收录进 characters")
	check(characters.definitions.size() == roster_ids.size() + 20, "名册 %d 人 + 人物包 20 人，实际 %d" % [roster_ids.size(), characters.definitions.size()])
	check(roster_snapshot(characters, roster_ids) == before and JSON.stringify(characters.relations, "", true) == relations_before, "名册人物的定义、状态与关系不应被改动")
	check(people.persons.keys().all(func(id): return not game.war.roster.officers.has(id)), "人物包人物不进战役名册")
	var adopted := JSON.stringify(characters.definitions["ys_001"], "", true)
	check(people.load_scenario("guandu") and characters.definitions.size() == roster_ids.size() + 20 and JSON.stringify(characters.definitions["ys_001"], "", true) == adopted, "重复载入不重复收录、不改已收录定义")
	check(people.attributes("ys_001")["统兵"] == float(yuan["attributes"]["统兵"]) and characters.job_fit("ys_001", "commander")["known"], "属性从 characters 读，岗位适配可算")

	var tick := int(game.war.state["tick"])
	check(people.relation_event("ys_015", "ys_001", "bridge_test", {"信任": -10.0, "怨恨": 20.0}, tick), "关系变化应写进 characters")
	var edge: Dictionary = characters.relation("ys_015", "ys_001")
	var seen: Dictionary = people.relation("ys_015", "ys_001")
	check(not edge.is_empty() and seen["信任"] == edge["trust"] and seen["怨恨"] == edge["resentment"] and edge["resentment"] > 0.0, "People 读到的就是 characters 的关系边")
	check(not people.relation_event("ys_015", "ys_001", "bridge_test", {"怨恨": 20.0}, tick), "同一事件不重复记（沿用 characters 去重）")
	check(not people.export_state().has("relations"), "人物系统存档不再有自己的关系表")
	check(characters.relation_label("ys_015", "ys_001") in ["中立", "猜忌", "宿怨", "同袍"], "characters 的关系标签照常可用")

	# 宿主重建 characters（同一 war 再 setup）或换掉 war 时，名册外的人物包人物下次取用前补收录，名册人物不受影响。
	game.war.characters.setup(game.war, {})
	check(not game.war.characters.definitions.has("ys_001"), "前提：characters 重建后不含名册外的人")
	check(people.attributes("ys_001")["统兵"] == float(yuan["attributes"]["统兵"]) and game.war.characters.definitions.size() == roster_ids.size() + 20, "characters 重建后取用时补收录 20 人")
	check(roster_snapshot(game.war.characters, roster_ids) == before, "补收录不改名册人物")
	var replaced = game.war.get_script().new()
	replaced.setup(game, {})
	game.war = replaced
	check(people.characters() == replaced.characters and replaced.characters.definitions.has("ys_015") and people.relation("ys_015", "ys_001").is_empty(), "换了 war 后收录进新的 characters，旧 war 的关系边不带过去")

	var bare := Store.new()
	bare.load_scenario("guandu")
	check(bare.characters() == null and bare.relation("ys_015", "ys_001").is_empty() and not bare.relation_event("ys_015", "ys_001", "x", {"信任": 1.0}, 0) and bare.attributes("ys_001").is_empty(), "没有 characters 时不收录、关系与属性为空")
	bare.free()

	print("CHARACTER_BRIDGE: %s（%d 处失败）" % ["PASS" if failures.is_empty() else "FAIL", failures.size()])
	quit(1 if not failures.is_empty() else 0)
