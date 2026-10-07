extends SceneTree

const Experience = preload("res://scripts/agents/experience.gd")
const Policy = preload("res://scripts/agents/baseline_policy.gd")
var failures: Array[String] = []

class WarStub extends RefCounted:
	var state: Dictionary
	func _init(tick: int) -> void: state = {"tick": tick, "armies": {}}


func _initialize() -> void: call_deferred("_run")

func check(value: bool, message: String) -> void:
	if not value:
		failures.append(message)
		push_error(message)

func _run() -> void:
	var war := WarStub.new(1)
	var army := {"id": "a1", "units": {"infantry": 1000, "archers": 0, "cavalry": 0}}
	Experience.ensure(army)
	check(army["experience"].has("enemy_notes") and army["experience"].has("battle_log") and army["experience"].has("streak"), "缺省经验结构未建立")
	# 1) 写入与连胜/连败。
	Experience.record_win(war, army, "e1", "交战取胜")
	Experience.record_win(war, army, "e1", "交战取胜")
	check(int(army["experience"]["streak"]["wins"]) == 2 and army["experience"]["battle_log"].size() == 2, "连胜未累加或未记入战报")
	Experience.record_loss(war, army, "e2", "溃败")
	check(int(army["experience"]["streak"]["wins"]) == 0 and int(army["experience"]["streak"]["losses"]) == 1, "连败未重置连胜")
	check(bool(army["experience"]["enemy_notes"]["e2"]["beat_us"]), "被击败的敌军未记入宿敌")
	# 2) 上限。
	for index in range(12): Experience.record_loss(war, army, "enemy%d" % index, "战斗")
	check(army["experience"]["enemy_notes"].size() <= 6, "宿敌记录超过上限")
	check(army["experience"]["battle_log"].size() <= 10, "战报记录超过上限")
	# 3) 漂移有界且可衰减。
	Policy.weights()["experience"]["drift_enabled"] = true
	var drifting := {"id": "a2", "units": {"infantry": 1000, "archers": 0, "cavalry": 0}}
	Experience.ensure(drifting)
	war.state["armies"]["a2"] = drifting
	for index in range(20): Experience.record_loss(war, drifting, "e%d" % index, "战斗")
	check(absf(float(drifting["experience"]["drift"]["风险承受"])) <= 12.0, "漂移幅度突破上限")
	check(float(drifting["experience"]["drift"]["自制"]) > 0.0, "连败没有提高谨慎")
	for day in range(400):
		war.state["tick"] = day
		Experience.decay(war)
	check(drifting["experience"]["drift"].is_empty(), "漂移没有随时间衰减")
	Policy.weights()["experience"]["drift_enabled"] = false
	# 4) 档案摘要有界且可用。
	var summary: Dictionary = Experience.summary(drifting)
	check(summary.has("drift") and summary.has("enemy_notes") and summary.has("recent") and summary["recent"].size() <= 3, "经验摘要异常")
	# 5) 存档恢复。
	var store: Node = root.get_node("GameState")
	store.persist_enabled = false
	store.prepare_battle_test(true)
	var living = store.war.active_armies()[0]
	Experience.ensure(living)
	living["experience"]["streak"]["wins"] = 4
	living["experience"]["enemy_notes"]["boss"] = {"tendency": "", "last_seen": 3, "beat_us": true}
	var saved: Dictionary = store.war.export_state()
	store.war.setup(store, saved)
	var restored: Dictionary = store.war.state["armies"][living["id"]]
	check(int(restored["experience"]["streak"]["wins"]) == 4 and bool(restored["experience"]["enemy_notes"]["boss"]["beat_us"]), "存档丢失经验")
	# 6) 缺省档位（无 experience 的旧军）不报错。
	var legacy := {"id": "old", "units": {"infantry": 500, "archers": 0, "cavalry": 0}}
	Experience.ensure(legacy)
	Experience.record_win(war, legacy, "", "无对手")
	check(legacy["experience"]["battle_log"].size() >= 1, "缺省档位写入失败")
	store.restore_battle_test()
	print("EXPERIENCE_OK: bounded notes and log, bounded drifting that decays, save restore, legacy defaults" if failures.is_empty() else "EXPERIENCE_FAILED")
	quit(0 if failures.is_empty() else 1)
