extends SceneTree

const Store = preload("res://scripts/core/game_state.gd")
const Combat = preload("res://scripts/war/battle/combat_system.gd")
const Adapter = preload("res://scripts/agents/agent_adapter.gd")
const Policy = preload("res://scripts/agents/baseline_policy.gd")
var failures: Array = []

class DecisionStub extends Node:
	var model := "test-stub"
	var metrics: Dictionary = {"fallbacks": 0}
	var desired := "hold"
	func choose_batch(contexts: Array) -> Dictionary:
		var results: Dictionary = {}
		for context in contexts:
			var result: Dictionary = {}
			for candidate in context["candidates"]:
				if candidate["action"]["type"] == desired:
					result = {"candidate_id": candidate["id"], "reason_summary": "测试选择", "source": "model"}
					break
			if result.is_empty(): result = Policy.choose(context)
			results[context["request_id"]] = result
		return results


func _initialize() -> void:
	call_deferred("_run")


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		push_error(message)


func _sandbox() -> Node:
	var sandbox := Store.new()
	sandbox.persist_enabled = false
	sandbox._load_demo()
	sandbox.war.rules["strategy"] = {}
	return sandbox


## 刘备势力在官渡剧本里没有历史人物卡，取可派遣的生成将（按名字排序后的第 index 个）。
func _officer_of(sandbox: Node, faction: String, index: int = 0) -> String:
	var officers: Array = sandbox.war.available_officers(faction)
	return str(officers[index]["id"]) if index < officers.size() else ""


func _officer(sandbox: Node, name: String) -> String:
	for officer in sandbox.war.roster.officers.values():
		if officer["name"] == name: return str(officer["id"])
	return ""


func _city(sandbox: Node, id: String, faction: String, troops: int, grain: int = 10000) -> void:
	var city: Dictionary = sandbox.city_state(id)
	city["faction"] = faction
	city["garrison"] = troops
	city["grain"] = grain
	city["training"] = 70
	city["equipment"] = 70
	city["defense"] = 20
	city["units"] = {"infantry": troops, "archers": 0, "cavalry": 0}


func _ledger(sandbox: Node) -> int:
	var total: int = 0
	for city in sandbox.scenario["places"].values():
		total += int(city.get("garrison", 0)) + int(city.get("wounded", 0)) + int(city.get("war_dead", 0)) + int(city.get("prisoners", 0))
	for army in sandbox.war.state["armies"].values():
		total += int(army["dead"]) + int(army["captured"]) + int(army.get("dispersed",0))
		if army["status"] != "ended": total += Combat.strength(army) + int(army["wounded"])
	return total


func _run() -> void:
	var sandbox: Node = _sandbox()
	_city(sandbox, "luoyang", "liu_bei", 10000)
	_city(sandbox, "hongnong", "yuan_shao", 1600)
	var id: String = _officer_of(sandbox, "liu_bei")
	var total: int = _ledger(sandbox)
	var grain: int = int(sandbox.city_state("luoyang")["grain"])
	var preview: Dictionary = sandbox.war.preview_dispatch("luoyang", "hongnong", id)
	_check(bool(preview["ok"]) and int(preview["strength"]) == 6000, "自动动员人数错误")
	_check(int(sandbox.city_state("luoyang")["grain"]) == grain and _ledger(sandbox) == total, "预览不应改变库存")
	var dispatch: Dictionary = sandbox.war.dispatch("luoyang", "hongnong", id)
	_check(bool(dispatch["ok"]), "派遣未成功")
	var army: Dictionary = sandbox.war.state["armies"][dispatch["army_id"]]
	_check(_ledger(sandbox) == total and int(sandbox.city_state("luoyang")["grain"]) + int(army["grain"]) == grain, "派遣未保持兵粮守恒")
	_check(not bool(sandbox.war.dispatch("luoyang", "hongnong", id)["ok"]), "同一将领能够重复出征")
	_check(not bool(sandbox.war.dispatch("hongnong", "luoyang", id)["ok"]), "玩家能够动员敌城")
	var context: Dictionary = sandbox.war.context_for(army)
	var secret_city: Dictionary = sandbox.city_state("xiangping")
	secret_city["garrison"] += 5000
	_check(context == sandbox.war.context_for(army), "同轮决策快照被实时城市变化改写")
	secret_city["garrison"] -= 5000
	_check(not bool(sandbox.war.validate_decision(context, {"candidate_id": "spawn:9999"})["ok"]), "非法模型行动通过校验")
	_check(sandbox.war.roster.officers[id]["personality"].size() == 14, "人物人格轴未限制为14项")
	_check(not bool(sandbox.war.preview_dispatch("hongnong", "luoyang", id)["ok"]), "敌方城池能够使用本方主将")
	_check(sandbox.action_error("hongnong", "recruit").contains("敌方"), "开战后玩家仍能在敌城征兵")
	_check(int(sandbox.war.player_city_intel("xiangping")["strength_estimate"]) == int(secret_city["garrison"]), "远方城池实时兵力不可见")
	var fake := DecisionStub.new()
	root.add_child(fake)
	await sandbox.war.step(fake)
	_check(str(army["location"]["edge"]) == "" and army["last_decision"] == 1, "模型选择等待未改变实际行动")
	_check(not bool(sandbox.war.validate_decision(context, {"candidate_id": "hold"})["ok"]), "旧请求能够重复执行")
	fake.queue_free()
	for index in range(100):
		await sandbox.war.step()
		_check(_ledger(sandbox) == total, "战争过程中兵员账本失衡，第%d日" % index)
		if army["status"] == "ended" and sandbox.war.active_armies().is_empty(): break
	_check(army["status"] == "ended", "自主战争没有结束")
	_check(not sandbox.war.state["reports"].any(func(report): return report["kind"] in ["行军报告", "交战", "围城", "任务结束"]), "日常行军或小队任务结束仍主动发报")
	_check(int(army.get("last_observation", {}).get("tick", -1)) == int(sandbox.war.state["tick"]), "静默位置快照未持续更新")
	_check(sandbox.war.state["decisions"].size() > 1, "没有记录实际决策")
	print("WAR_RESULT ", army["outcome"], " days=", sandbox.war.state["tick"], " decisions=", sandbox.war.state["decisions"].size())
	# Snapshot restoration must preserve the 64-bit RNG state without JSON rounding.
	var encoded: Dictionary = JSON.parse_string(JSON.stringify(sandbox.war.export_state()))
	var clone: Node = _sandbox()
	clone.scenario = sandbox.scenario.duplicate(true)
	clone.war.setup(clone, encoded)
	# setup reloads default rules; replay must use the same disabled strategy as the sandbox.
	clone.war.rules = sandbox.war.rules.duplicate(true)
	_check(sandbox.war.rng.state == clone.war.rng.state, "随机状态经过JSON后丢失精度")
	await sandbox.war.step()
	await clone.war.step()
	var original_state: Dictionary = sandbox.war.export_state()
	var restored_state: Dictionary = clone.war.export_state()
	if not _equivalent(original_state, restored_state):
		var f := FileAccess.open("res://docs/validation/war-replay-debug.json", FileAccess.WRITE)
		f.store_string(JSON.stringify({"original": original_state, "restored": restored_state}))
	_check(_equivalent(original_state, restored_state), "载入快照后战争状态出现分歧")
	clone.free()
	sandbox.free()
	await _road_contact()
	await _supply_and_withdrawal()
	_blocked_return()
	await _save_migration()
	await _adapter_checks()
	_personality_checks()
	await _clock_checks()
	if failures.is_empty():
		print("WAR_VALIDATION_OK: dispatch, conservation, authority, full visibility, personality, model actions, road contact, supply, siege, return, migration, RNG and adapter failures")
	quit(0 if failures.is_empty() else 1)


func _road_contact() -> void:
	var sandbox: Node = _sandbox()
	_city(sandbox, "luoyang", "liu_bei", 10000)
	_city(sandbox, "hongnong", "yuan_shao", 10000)
	var attacker_id: String = _officer_of(sandbox, "liu_bei")
	var defender_id: String = _officer(sandbox, "颜良")
	var a: Dictionary = sandbox.war._mobilize(sandbox.war.preview_dispatch("luoyang", "hongnong", attacker_id))
	var b: Dictionary = sandbox.war._mobilize(sandbox.war.preview_dispatch("hongnong", "luoyang", defender_id))
	var c: Dictionary = sandbox.war._mobilize(sandbox.war.preview_dispatch("luoyang", "hongnong", _officer_of(sandbox, "liu_bei", 1)))
	var path: Dictionary = sandbox.war.graph.path("luoyang", "hongnong")
	_check(path["edges"].size() == 1, "道路接敌测试需要直连路线")
	var edge: String = str(path["edges"][0])
	a["location"] = {"node": "luoyang", "edge": edge, "from": "luoyang", "to": "hongnong", "progress": 0.4}
	b["location"] = {"node": "hongnong", "edge": edge, "from": "hongnong", "to": "luoyang", "progress": 0.4}
	c["location"] = a["location"].duplicate(true)
	a["action"] = {"type": "continue"}
	b["action"] = {"type": "continue"}
	c["action"] = {"type": "continue"}
	var total: int = _ledger(sandbox)
	var motions: Dictionary = sandbox.war._move_all()
	sandbox.war._resolve_contacts(motions)
	_check(a.has("tactical") and b.has("tactical") and c.has("tactical"), "道路遭遇没有部署实际战场")
	for index in range(12):
		await sandbox.war.step()
		if int(a["dead"]) > 0 and int(b["dead"]) > 0 and int(c["dead"]) > 0: break
	_check(int(a["dead"]) + int(c["dead"]) > 0 and int(b["dead"]) > 0, "相向行军发生穿透，未接敌")
	_check(int(c.get("combat_tick", -1)) >= 0, "同场援军没有参与战斗")
	_check(_ledger(sandbox) == total, "道路战斗未保持兵员守恒")
	var restored: Node = _sandbox()
	restored.scenario = sandbox.scenario.duplicate(true)
	restored.war.setup(restored, JSON.parse_string(JSON.stringify(sandbox.war.export_state())))
	await sandbox.war.step()
	await restored.war.step()
	if not _equivalent(sandbox.war.export_state(), restored.war.export_state()):
		var file := FileAccess.open("res://docs/validation/war-road-replay-debug.json", FileAccess.WRITE)
		file.store_string(JSON.stringify({"original": sandbox.war.export_state(), "replay": restored.war.export_state()}, "\t"))
	_check(_equivalent(sandbox.war.export_state(), restored.war.export_state()), "交战中恢复快照后，后续决策或战损出现分歧")
	restored.free()
	sandbox.free()


func _supply_and_withdrawal() -> void:
	var sandbox: Node = _sandbox()
	_city(sandbox, "luoyang", "liu_bei", 10000)
	var preview: Dictionary = sandbox.war.preview_dispatch("luoyang", "hongnong", _officer_of(sandbox, "liu_bei"))
	var army: Dictionary = sandbox.war._mobilize(preview)
	army["grain"] = 0.0
	var food_before: int = int(sandbox.city_state("luoyang")["grain"])
	sandbox.war._execute(army, {"type": "resupply"})
	_check(int(army["grain"]) + int(sandbox.city_state("luoyang")["grain"]) == food_before, "补给凭空产生或损失粮草")
	var total: int = _ledger(sandbox)
	sandbox.war._execute(army, {"type": "withdraw"})
	_check(army["status"] == "ended" and _ledger(sandbox) == total, "归营重复增加或丢失兵员")
	var before_return: int = int(sandbox.city_state("luoyang")["garrison"])
	sandbox.war._finish(army, "撤退")
	_check(int(sandbox.city_state("luoyang")["garrison"]) == before_return, "重复归营导致复制军队")
	sandbox.free()


# 退路受阻：没有可达友城时部队不能无限期滞留。旧实现只发一条军报后返回，
# returning 永远为真，月度推进被 active_armies 非空永久拒绝，且每日新增紧急军报。
func _blocked_return() -> void:
	var sandbox: Node = _sandbox()
	sandbox.persist_enabled = false
	var war = sandbox.war
	_city(sandbox, "luoyang", "liu_bei", 10000)
	var army: Dictionary = war._mobilize(war.preview_dispatch("luoyang", "hongnong", _officer_of(sandbox, "liu_bei")))
	army.erase("tactical")
	army["returning"] = true
	army["outcome"] = "撤退"
	# 临时让本方所有城池都不可达，模拟被困在敌后。
	var hidden := {}
	for id in sandbox.scenario.get("places", {}):
		var city: Dictionary = sandbox.city_state(str(id))
		if str(city.get("faction", "")) == str(war.state["player_faction"]):
			hidden[id] = city["faction"]
			city["faction"] = "yuan_shao"
	var reports_before: int = war.state["reports"].size()
	for day in range(3):
		war.state["tick"] += 1
		war._start_return(army)
		war._observe_all()
	_check(str(army["action"]["type"]) != "withdraw" and int(army["last_decision"]) == -10, "受阻断言污染了前置状态")
	_check(army["returning"] and war.state["reports"].size() == reports_before, "退路受阻应静默，不主动发报")
	_check(army["memory"].any(func(item): return item["kind"] == "退路受阻"), "退路受阻未保留本地意图记录")
	_check(int(army.get("last_observation", {}).get("tick", -1)) == int(war.state["tick"]), "退路受阻时地图快照停止更新")
	_check(int(war.ledger(army)["missing"]) == 0, "散亡过程中兵员账本出现缺口")
	var days: int = int(war.rules.get("return_stall_days", 10))
	for day in range(days + 1):
		war.state["tick"] += 1
		war._start_return(army)
	_check(str(army["status"]) == "ended" and str(army["outcome"]) == "退路断绝，部众散亡", "退路长期受阻的部队没有收束")
	_check(int(war.ledger(army)["missing"]) == 0, "退路受阻收束时兵员账本出现缺口")
	for id in hidden: sandbox.city_state(str(id))["faction"] = hidden[id]
	sandbox.free()


func _save_migration() -> void:
	var sandbox: Node = _sandbox()
	sandbox.save_path = "user://war_validation_temp.json"
	var legacy: Dictionary = {"version": 1, "year": 192, "month": 3, "action_points": 2, "places": sandbox.scenario["places"].duplicate(true), "chronicles": []}
	var file := FileAccess.open(sandbox.save_path, FileAccess.WRITE)
	file.store_string(JSON.stringify(legacy))
	file.close()
	sandbox._load_save()
	_check(sandbox.year == 192 and sandbox.month == 3 and sandbox.day == 1 and sandbox.war.active_armies().is_empty(), "旧存档迁移错误")
	_city(sandbox, "luoyang", "liu_bei", 10000)
	var dispatch: Dictionary = sandbox.war.dispatch("luoyang", "hongnong", _officer_of(sandbox, "liu_bei"))
	await sandbox.war.step()
	sandbox.persist_enabled = true
	sandbox._save()
	var restored: Node = _sandbox()
	restored.save_path = sandbox.save_path
	restored._load_save()
	_check(restored.war.state["armies"].has(dispatch["army_id"]) and restored.war.rng.state == sandbox.war.rng.state, "新存档丢失军队或随机状态")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(sandbox.save_path))
	restored.free()
	sandbox.free()


func _adapter_checks() -> void:
	var adapter := Adapter.new()
	root.add_child(adapter)
	_check(adapter.configure({"enabled": true, "endpoint": "file:///secret", "model": "x"}, false).contains("http"), "接口配置没有拒绝非法URL")
	_check(adapter._decode_response(0, 401, "{}".to_utf8_buffer()).has("error"), "HTTP错误没有回退")
	_check(adapter._decode_response(0, 200, "{\"choices\":[]}".to_utf8_buffer()).has("error"), "空模型响应未被拒绝")
	var decoded: Dictionary = adapter._decode_response(0, 200, JSON.stringify({"choices": [{"message": {"content": "{\"candidate_id\":\"hold\",\"reason_summary\":\"整顿部队\"}"}}]}).to_utf8_buffer())
	_check(decoded.get("candidate_id", "") == "hold" and decoded.get("source", "") == "model", "合法模型响应解析失败")
	adapter.configure({"enabled": true, "endpoint": "http://127.0.0.1:1/v1/chat/completions", "model": "unavailable", "timeout": 2}, false)
	var results: Dictionary = await adapter.choose_batch([{"request_id": "timeout-test", "candidates": [{"id": "hold", "action": {"type": "hold"}}]}])
	_check(results.get("timeout-test", {}).get("source", "") == "baseline" and int(adapter.metrics["failures"]) == 1, "连接失败后未正常接管")
	adapter.queue_free()


func _personality_checks() -> void:
	var situation: Dictionary = {"officer": {"personality": {"风险承受": 90, "耐心": 50}}, "army": {"strength": 1000, "grain_days": 20, "morale": 90, "organization": 90}, "enemies": [{"strength_estimate": 1300}], "candidates": [{"id": "engage", "action": {"type": "engage"}}, {"id": "withdraw", "action": {"type": "withdraw"}}]}
	var daring: Dictionary = Policy.choose(situation)
	situation["officer"]["personality"]["风险承受"] = 10
	var cautious: Dictionary = Policy.choose(situation)
	_check(daring["candidate_id"] == "engage" and cautious["candidate_id"] == "withdraw", "风险人格没有改变实际行动选择")


func _clock_checks() -> void:
	var bulk: Node = _sandbox()
	var daily: Node = _sandbox()
	for sandbox in [bulk, daily]:
		for city in sandbox.scenario["places"].values():
			if not city.has("population"): continue
			city["population"] = 0
			city["economy"] = 0
			city["garrison"] = 1000
			city["grain"] = 10000
	await bulk.advance_month()
	for index in range(30): await daily.advance_day()
	_check(bulk.month == daily.month and bulk.day == daily.day and int(bulk.city_state("luoyang")["grain"]) == int(daily.city_state("luoyang")["grain"]), "按日与按月推进重复或遗漏驻军粮耗")
	_check(int(bulk.city_state("luoyang")["grain"]) == 10000, "停用断粮系统后驻军仍消耗粮草")
	bulk.free()
	daily.free()


func _equivalent(a: Variant, b: Variant) -> bool:
	if typeof(a) in [TYPE_INT, TYPE_FLOAT] and typeof(b) in [TYPE_INT, TYPE_FLOAT]:
		return absf(float(a) - float(b)) < 0.00000001
	if a is Dictionary and b is Dictionary:
		if a.size() != b.size(): return false
		for key in a:
			if not b.has(key) or not _equivalent(a[key], b[key]): return false
		return true
	if a is Array and b is Array:
		if a.size() != b.size(): return false
		for index in range(a.size()):
			if not _equivalent(a[index], b[index]): return false
		return true
	return a == b
