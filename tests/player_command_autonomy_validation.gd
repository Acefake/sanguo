extends SceneTree
var failures: Array[String] = []
func _initialize(): call_deferred("run")
func check(ok: bool, message: String) -> void:
	if not ok: failures.append(message); push_error(message)
func run() -> void:
	var store = root.get_node("GameState")
	store.persist_enabled = false
	store.prepare_battle_test()
	var war = store.war
	var army: Dictionary = war.active_armies("liu_bei")[0]
	var deputy: Dictionary = army.duplicate(true)
	deputy["id"] = "command-autonomy-deputy"
	deputy["officer_id"] = "command-autonomy-officer"
	deputy["returning"] = false
	deputy["corps_task"] = {"type":"main_attack"}
	deputy["orders"] = {"engage":true}
	var card: Dictionary = war.roster.officers[army["officer_id"]].duplicate(true)
	card["id"] = deputy["officer_id"]
	war.roster.officers[card["id"]] = card
	var corps: Dictionary = {"id":"test-player-orders","root_id":army["id"],"commander_id":army["officer_id"],"name":"test","faction":"liu_bei","members":[army["officer_id"],deputy["officer_id"]],"units":[army["id"],deputy["id"]],"orders":[],"appointments":{army["officer_id"]:"主帅",deputy["officer_id"]:"前锋"},"supply":{},"known_supplies":{}}
	army["corps_id"] = corps["id"]
	deputy["corps_id"] = corps["id"]
	war.state["corps"] = {corps["id"]:corps}
	war.state["armies"][deputy["id"]] = deputy
	war.state["officer_states"][deputy["officer_id"]] = {"status":"deployed"}
	war.rules["corps"] = war.rules.get("corps", {})
	war.rules["corps"]["autonomy"] = {"forced_stance":"object"}
	var result: Dictionary = war.command_army(str(army["id"]), {"engage":false}, false)
	check(result.get("ok", false), "玩家作战命令入口失败")
	check(deputy["orders"].get("engage", false), "玩家统一命令覆盖拒命成员旧意图")
	result = war.command_army(str(army["id"]), {}, true)
	check(result.get("ok", false), "玩家撤军命令入口失败")
	check(not deputy["returning"], "玩家撤军直接强制拒命成员撤退")
	# Occupation expands the after-battle transition to the entire corps.
	deputy["action"] = {"type":"flank", "enemy":"test-enemy"}
	deputy["autonomy"] = {"stance":"act", "until":int(war.state["tick"]) + 2}
	deputy["mission_type"] = "capture"
	deputy["target"] = "xiaopei"
	deputy["orders"]["after_battle"] = "withdraw"
	var before: Dictionary = deputy["action"].duplicate(true)
	var city: Dictionary = store.city_state("xiaopei")
	war._capture_city(army, [army], "xiaopei", city)
	check(deputy["action"] == before and not deputy["returning"], "占领后全军撤退覆盖有效自行行动")
	war._upkeep()
	check(deputy["action"] == before and not deputy["returning"], "占领后upkeep延迟覆盖有效自行行动")
	deputy["orders"]["after_battle"] = "hold"
	war._capture_city(army, [army], "xiaopei", city)
	check(deputy["action"] == before, "占领后全军hold覆盖有效自行行动")
	print("PLAYER_COMMAND_AUTONOMY_OK" if failures.is_empty() else "PLAYER_COMMAND_AUTONOMY_FAILED: " + str(failures))
	quit(0 if failures.is_empty() else 1)
