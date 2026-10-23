extends SceneTree
## 人物卡 schema 6 → 7 迁移：官渡 20 张卡按 id 并入补丁、旧字段不丢、已有值不覆盖、迁移两次不变；
## 没有补丁时推定心志并登记；schema 7 卡生成的 PersonState 带上心志、人格轴与心结起算旬。
##
##   godot --headless --path . --script res://tests/people/card_migrate_validation.gd

const Repository = preload("res://scripts/officers/officer_repository.gd")
const Migrate = preload("res://scripts/people/card_migrate.gd")
const Store = preload("res://scripts/people/person_store.gd")

const PATCHES := "res://data/people/guandu/persons_s7.json"

var failures: Array[String] = []


func check(value: bool, message: String) -> void:
	if not value:
		failures.append(message)
		push_error(message)


func _initialize() -> void:
	var cards := Repository.cards()
	var patches: Array = Store.read_json(PATCHES)
	var patch_by_id := {}
	for patch in patches: patch_by_id[patch["id"]] = patch
	var migrated := Migrate.migrate_all(cards, patches)
	check(migrated.size() == cards.size() and cards.size() == 20, "官渡应迁移 20 张卡，实际 %d" % migrated.size())
	for index in migrated.size():
		var card: Dictionary = migrated[index]
		var source: Dictionary = cards[index]
		var patch: Dictionary = patch_by_id.get(card["id"], {})
		check(not patch.is_empty(), "%s 没有对应补丁" % card["id"])
		check(int(card["schema_version"]) == 7, "%s schema_version 应为 7" % card["id"])
		for field in Migrate.S7_FIELDS:
			check(card[field] == patch[field], "%s.%s 应等于补丁值" % [card["id"], field])
		for field in source:
			if field not in ["schema_version", "inferred"]: check(card[field] == source[field], "%s 旧字段 %s 被改动" % [card["id"], field])
		for entry in source.get("inferred", []) + patch.get("inferred", []):
			check(entry in card["inferred"], "%s 推定登记丢了 %s" % [card["id"], entry])
		check(Migrate.migrate(card, patch) == card, "%s 迁移两次结果应不变" % card["id"])

	var preset: Dictionary = cards[0].duplicate(true)
	preset["birth_year"] = 150
	check(int(Migrate.migrate(preset, patch_by_id[preset["id"]])["birth_year"]) == 150, "卡上已有生年不应被补丁覆盖")

	var bare := Migrate.migrate(cards[0])
	var total := 0.0
	for drive in bare["drives"]:
		total += float(drive["weight"])
		check(drive["id"] in Migrate.drives_doc()["ids"], "推定出未知心志 %s" % drive["id"])
	check(bare["drives"].size() in [1, 2] and absf(total - 1.0) <= 0.01, "推定心志应 1–2 条、权重和 1，实际 %s" % str(bare["drives"]))
	check("drives" in bare["inferred"], "推定心志应登记到 inferred")
	check(bare["kin"] == [] and bare["fame"] == {} and int(bare["birth_year"]) == 0, "无补丁时新字段取缺省值")
	check(Migrate.infer_drives(cards[0]) == Migrate.infer_drives(cards[0]), "推定心志应可复现")

	var revenge: Dictionary = cards[0].duplicate(true)
	revenge["knots"] = [{"id": "knot_001", "object": {"kind": "person", "id": cards[1]["id"]}, "intensity": 80}]
	check(Migrate.infer_drives(revenge)[0]["id"] == "报仇", "强度 ≥60 的对象型心结应推定出报仇心志")

	var state = Migrate.to_state(migrated[0], 7200)
	check(state.id == migrated[0]["id"] and state.drives == migrated[0]["drives"], "PersonState 应带上卡上心志")
	check(state.drive_weight(str(migrated[0]["drives"][0]["id"])) > 0.0 and state.drive_weight("不存在") == 0.0, "drive_weight 查询")
	check(state.axes.size() == 14 and state.axes == state.axes_base, "开局人格轴应有 14 条且等于锚点")
	for knot in state.knots:
		check(int(knot["since_xun"]) == 7200, "卡上心结应从开局旬算起")
		check(not state.knot_on(knot["object"]["kind"], knot["object"]["id"]).is_empty(), "knot_on 应找到卡上心结")
	check(state.age(200) == 200 - int(migrated[0]["birth_year"]), "age 按生年计算")

	print("CARD_MIGRATE: %s（%d 处失败）" % ["PASS" if failures.is_empty() else "FAIL", failures.size()])
	quit(1 if not failures.is_empty() else 0)
