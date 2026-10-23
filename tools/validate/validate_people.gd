extends SceneTree
## 人物数据校验（01-人物数据模型 §5），CI 用：有 error 时退出码 1，warning 只打印。
##
##   godot --headless --path . --script res://tools/validate/validate_people.gd -- [--pack=guandu]
##
## 读当前剧本人物卡（OfficerRepository）与人物包 data/people/<包>/ 的补丁、前史事件，迁到 schema 7 后逐条校验；
## 词条查 data/people/libraries/，城池与势力查世界剧本；再核对事件目录、衰减档、关系规则、心志规则互相覆盖；
## R1 在 res://scripts 下查人名、字、势力名。规则本身在 scripts/people/people_validation.gd。

const Repository = preload("res://scripts/officers/officer_repository.gd")
const Store = preload("res://scripts/people/person_store.gd")
const Migrate = preload("res://scripts/people/card_migrate.gd")
const Validation = preload("res://scripts/people/people_validation.gd")


func _initialize() -> void:
	var pack := "guandu"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--pack="): pack = arg.trim_prefix("--pack=")
	var dir := Store.DATA_DIR + pack + "/"
	var refs := Validation.load_refs()
	var cards := Migrate.migrate_all(Repository.cards(), Store.read_json(dir + "persons_s7.json"))
	var memory_rules: Dictionary = Store.read_json(Store.DATA_DIR + "memory_rules.json")
	var people_ids: Array = cards.map(func(card): return str(card["id"])) + refs["offstage"].keys()
	var reports := [
		Validation.check_cards(cards, refs),
		Validation.check_seed_events(Store.read_json(dir + "seed_events.json")["events"], people_ids, refs["cities"], Validation.catalog_kinds(memory_rules)),
		Validation.check_rule_tables(memory_rules, refs["drives"], Store.read_json(Store.DATA_DIR + "relation_rules.json")),
		{"errors": Validation.scan_names("res://scripts", Validation.protected_names(Repository.cards(), refs["offstage"].values())), "warnings": []},
	]
	var errors: Array = []
	var warnings: Array = []
	for report in reports:
		errors.append_array(report["errors"])
		warnings.append_array(report["warnings"])
	for line in warnings: print("  WARN  ", line)
	for line in errors: print("  ERROR ", line)
	print("VALIDATE_PEOPLE: %d 张卡，%d error，%d warning —— %s" % [cards.size(), errors.size(), warnings.size(), "PASS" if errors.is_empty() else "FAIL"])
	quit(0 if errors.is_empty() else 1)
