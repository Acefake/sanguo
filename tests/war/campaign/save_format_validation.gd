extends SceneTree
## 存档格式检验：后台写盘的存档能完整读回；旧格式（带缩进）的存档照样能读；连续两次存档以后一次为准。
##
##   godot --headless --path . --script res://tests/war/campaign/save_format_validation.gd

const Store = preload("res://scripts/core/game_state.gd")
const PATH := "user://save_format_validation.json"

var failures: Array[String] = []


func _initialize() -> void: call_deferred("_run")


func check(value: bool, message: String) -> void:
	if not value:
		failures.append(message)
		push_error(message)


## 存档里原样保存、读档后应相同的部分：城池、编年、日期与行动力。按 JSON 往返后的值比较（整数读回为浮点）。
func _digest(store) -> Variant:
	return JSON.parse_string(JSON.stringify({"places": store.scenario["places"], "chronicles": store.chronicles, "date": [store.year, store.month, store.day], "action_points": store.action_points}))


## 读档后的完整状态（含战役经 setup 迁移后的状态），用于比较新旧两种格式读出来是否相同。
func _full(store) -> String:
	return JSON.stringify(_digest(store)) + JSON.stringify(store.war.export_state())


func _restored():
	var store = Store.new()
	store.persist_enabled = false
	store.save_path = PATH
	store._load_demo()
	store._load_save()
	return store


func _run() -> void:
	var source = Store.new()
	source.save_path = PATH
	source._load_demo()
	source.persist_enabled = false
	for day in 12: await source.war.step(null)
	source.persist_enabled = true
	source._save()
	var expected: Variant = _digest(source)
	var restored = _restored()
	check(_digest(restored) == expected, "后台写盘的存档读回后与存档时不同")
	check(restored.war.state["armies"].size() == source.war.state["armies"].size() and restored.war.rng.state == source.war.rng.state, "后台写盘的存档丢失军队或随机状态")
	var compact_full := _full(restored)
	var text := FileAccess.get_file_as_string(PATH)
	check(not text.contains("\n\t"), "存档仍带缩进")
	restored.free()

	# 旧格式：与原先 _save 相同的带缩进 JSON。
	var legacy := FileAccess.open(PATH, FileAccess.WRITE)
	legacy.store_string(JSON.stringify({"version": 3, "year": source.year, "month": source.month, "day": source.day, "action_points": source.action_points, "places": source.scenario.get("places", {}), "chronicles": source.chronicles, "war": source.war.export_state()}, "\t"))
	legacy.close()
	restored = _restored()
	check(_full(restored) == compact_full, "旧格式（带缩进）存档与新格式读回的状态不同")
	restored.free()

	# 连续两次存档：后一次写盘必须等前一次结束，读到的是后一次。
	source.action_points = 2
	source._save()
	source.action_points = 1
	source._save()
	restored = _restored()
	check(restored.action_points == 1, "连续存档后读到的不是最后一次")
	restored.free()

	source.free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH))
	print("SAVE_FORMAT_VALIDATION_OK" if failures.is_empty() else "SAVE_FORMAT_VALIDATION_FAILED")
	quit(0 if failures.is_empty() else 1)
