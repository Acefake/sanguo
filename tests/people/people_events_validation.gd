extends SceneTree
## 事件总线：People 与 PeopleEvents 已注册为 Autoload；emit 编号递增并广播，drain 按发出顺序取走并清空；
## 存读档后编号续上、未结算事件保留。
##
##   godot --headless --path . --script res://tests/people/people_events_validation.gd

const Bus = preload("res://scripts/people/people_events.gd")

var failures: Array[String] = []


func check(value: bool, message: String) -> void:
	if not value:
		failures.append(message)
		push_error(message)


func _initialize() -> void:
	check(root.get_node_or_null("People") != null and root.get_node_or_null("PeopleEvents") is Bus, "People、PeopleEvents 应注册为 Autoload")
	var bus := Bus.new()
	var heard: Array = []
	bus.event_emitted.connect(func(event): heard.append(event))
	var data := {"lord": "p_001"}
	var first := bus.emit("appointed", "p_002", "p_001", data)
	data["lord"] = "changed"
	bus.emit("battle_won", "p_001")
	check(first["eid"] == "ev_000001" and first["data"]["lord"] == "p_001", "事件编号从 ev_000001 起，data 被复制")
	check(heard.size() == 2 and heard[1]["kind"] == "battle_won" and heard[1]["target"] == "", "每条事件都广播")
	var saved: Dictionary = JSON.parse_string(JSON.stringify(bus.export_state()))
	var drained := bus.drain()
	check(drained.map(func(e): return e["kind"]) == ["appointed", "battle_won"] and bus.drain().is_empty(), "drain 按顺序取走并清空")

	var restored := Bus.new()
	restored.import_state(saved)
	check(restored.drain().size() == 2, "读档保留未结算事件")
	check(restored.emit("praised", "p_003")["eid"] == "ev_000003", "读档后编号续上")
	bus.free()
	restored.free()

	print("PEOPLE_EVENTS: %s（%d 处失败）" % ["PASS" if failures.is_empty() else "FAIL", failures.size()])
	quit(1 if not failures.is_empty() else 0)
