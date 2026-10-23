extends SceneTree
## 检验战场观看界面的冒烟校验：载入场景、逐个战场重置并跑完，界面状态与推演结果一致。
##
##   godot --headless --path . --script res://tests/war/proving/proving_ground_view_validation.gd

const Data = preload("res://scripts/war/proving/battlefield_data.gd")

var failures: Array[String] = []


func check(value: bool, message: String) -> void:
	if not value:
		failures.append(message)
		push_error(message)


func _initialize() -> void:
	var view: Control = load("res://scenes/war/proving_ground.tscn").instantiate()
	root.add_child(view)
	await process_frame
	check(view.field_choice.item_count == Data.ids().size(), "战场下拉应列出全部战场")
	for i in view.field_choice.item_count:
		view.field_choice.select(i)
		view._load_field()
		view.step_once()
		check(view.sim.tick == 1, "%s 单步后应在第 1 刻" % view.field["id"])
		view.run_to_end()
		check(view.sim.finished(), "%s 跑完后应结束" % view.field["id"])
		check(view.log_text.get_parsed_text().contains("理由"), "%s 日志应含决策理由" % view.field["id"])
		check(view.status.text.contains("结束"), "%s 状态栏应显示结束" % view.field["id"])
		check(view.detail_text.get_parsed_text().contains("增益"), "%s 部队详情应含增益" % view.field["id"])
	view.queue_free()
	await process_frame
	print("PROVING_GROUND_VIEW_VALIDATION: " + ("PASS" if failures.is_empty() else "FAIL " + str(failures)))
	quit(0 if failures.is_empty() else 1)
