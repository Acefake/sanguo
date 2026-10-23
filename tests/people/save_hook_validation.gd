extends SceneTree
## 主存档接入：GameState._save() 把 People 与 PeopleEvents 写进 user://city_campaign.json 同一文件的 people 键，
## _load_save() 读回后人物状态与未结算事件一致；没有 people 键的旧档不动人物系统。
## 需要 GameState 能加载（缺失脚本在本地或空壳环境里就位）。
##
##   godot --headless --path . --script res://tests/people/save_hook_validation.gd

const TEST_SAVE := "user://people_save_hook_test.json"

var failures: Array[String] = []


func check(value: bool, message: String) -> void:
	if not value:
		failures.append(message)
		push_error(message)


func normalized(state: Dictionary) -> String:
	return JSON.stringify(JSON.parse_string(JSON.stringify(state)), "", true)


func _initialize() -> void:
	var game: Node = root.get_node("GameState")
	var people: Node = root.get_node("People")
	var bus: Node = root.get_node("PeopleEvents")
	var old_path: String = game.save_path
	var old_persist: bool = game.persist_enabled
	game.save_path = TEST_SAVE
	game.persist_enabled = true
	people.load_scenario("guandu")
	bus.drain()
	bus.emit("praised", str(people.persons.keys()[0]), str(people.persons.keys()[1]))
	var before := normalized(people.export_state())
	game._save()

	var payload: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(TEST_SAVE))
	check(payload.has("people") and int(payload["people"].get("people_version", 0)) == 1, "存档应有 people 键与 people_version 1")
	check(payload["people"].get("events", {}).get("pending", []).size() == 1, "未结算事件应随存档保存")

	people.import_state({"people_version": 1})
	bus.drain()
	game._load_save()
	check(normalized(people.export_state()) == before, "读档后人物状态应与存档时一致")
	check(bus.drain().size() == 1, "读档后未结算事件应还原")

	payload.erase("people")
	var file := FileAccess.open(TEST_SAVE, FileAccess.WRITE)
	file.store_string(JSON.stringify(payload))
	file.close()
	var current := normalized(people.export_state())
	game._load_save()
	check(normalized(people.export_state()) == current, "没有 people 键的旧档不应改动人物系统")

	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_SAVE))
	game.save_path = old_path
	game.persist_enabled = old_persist
	print("PEOPLE_SAVE_HOOK: %s（%d 处失败）" % ["PASS" if failures.is_empty() else "FAIL", failures.size()])
	quit(1 if not failures.is_empty() else 0)
