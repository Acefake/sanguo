extends SceneTree


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var sandbox = load("res://scripts/game_state.gd").new()
	sandbox.persist_enabled = false
	for action_id in sandbox.ACTIONS:
		sandbox._load_demo()
		sandbox.action_points = 3
		sandbox.chronicles.clear()
		var before: Dictionary = sandbox.city_state("xuchang").duplicate(true)
		var preview: Dictionary = sandbox.preview_action("xuchang", action_id)
		if not bool(preview["ok"]) or sandbox.city_state("xuchang") != before or sandbox.action_points != 3 or not sandbox.chronicles.is_empty():
			_fail("预览改变状态或未给出结果：" + str(action_id))
			return
		sandbox.apply_action("xuchang", action_id)
		if sandbox.city_state("xuchang") != preview["after"] or sandbox.action_points != preview["action_points_after"]:
			_fail("实际施行与预览不一致：" + str(action_id))
			return
	sandbox._load_demo()
	sandbox.action_points = 3
	sandbox.city_state("xuchang")["order"] = 97
	if int(sandbox.preview_action("xuchang", "govern")["after"]["order"]) != 100:
		_fail("预览未限制民心上限")
		return
	sandbox.city_state("xuchang")["treasury"] = 0
	var previous: Dictionary = sandbox.city_state("xuchang").duplicate(true)
	for chosen in ["recruit", "unknown"]:
		var rejected: Dictionary = sandbox.preview_action("xuchang", chosen)
		if bool(rejected["ok"]) or rejected["before"] != rejected["after"] or sandbox.city_state("xuchang") != previous:
			_fail("失败预览改变状态")
			return
	sandbox.action_points = 0
	if bool(sandbox.preview_action("xuchang", "tax")["ok"]):
		_fail("行动力为零时预览仍允许施行")
		return
	sandbox.free()
	print("行动预览检查通过：十类命令与实际结果一致，预览无副作用，失败与数值上限正确。")
	quit(0)


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
