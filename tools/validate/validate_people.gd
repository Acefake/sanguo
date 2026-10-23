extends SceneTree
## 人物数据校验（01-人物数据模型 §5），CI 用：有 error 时退出码 1，warning 只打印。
##
##   godot --headless --path . --script res://tools/validate/validate_people.gd -- [--scenario=guandu]
##
## 读当前剧本人物卡（OfficerRepository）与 data/people/ 下的补丁、圈子、不上场人物、心志表、前史事件，
## 迁到 schema 7 后逐条校验；R1 在 res://scripts 下查人名、字、势力名。规则本身在 scripts/people/people_validation.gd。

const Repository = preload("res://scripts/officers/officer_repository.gd")
const Store = preload("res://scripts/people/person_store.gd")
const Migrate = preload("res://scripts/people/card_migrate.gd")
const Validation = preload("res://scripts/people/people_validation.gd")

const WORLD_SCENARIO := "res://data/scenario_world_demo.json"
const WORLD_POSITIONS := "res://data/war/world_3d_positions.json"


func _initialize() -> void:
	var scenario := "guandu"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--scenario="): scenario = arg.trim_prefix("--scenario=")
	var dir := Store.DATA_DIR + scenario + "/"
	var offstage_list: Array = Store.read_json(Store.DATA_DIR + "offstage.json")
	var cards := Migrate.migrate_all(Repository.cards(), Store.read_json(dir + "persons_s7.json"))
	var refs := {
		"offstage": _by_id(offstage_list), "circles": _by_id(Store.read_json(Store.DATA_DIR + "circles.json")),
		"drives": Migrate.drives_doc(), "cities": _cities(), "factions": _factions(cards + offstage_list),
	}
	var reports := [
		Validation.check_cards(cards, refs),
		Validation.check_seed_events(Store.read_json(dir + "seed_events.json")["events"], _by_id(cards + offstage_list).keys(), refs["cities"]),
		{"errors": Validation.scan_names("res://scripts", Validation.protected_names(Repository.cards(), offstage_list)), "warnings": []},
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


func _by_id(entries: Array) -> Dictionary:
	var out := {}
	for entry in entries: out[str(entry["id"])] = entry
	return out


func _cities() -> Array:
	var world: Dictionary = Store.read_json(WORLD_SCENARIO)
	var positions: Dictionary = Store.read_json(WORLD_POSITIONS)
	var out: Array = world.get("places", {}).keys()
	for id in positions.get("positions", {}).keys() + positions.get("city_aliases", {}).keys():
		if id not in out: out.append(id)
	return out


func _factions(entries: Array) -> Array:
	var out: Array = []
	for entry in entries:
		var faction := str(entry.get("faction", ""))
		if not faction.is_empty() and faction not in out: out.append(faction)
	return out
