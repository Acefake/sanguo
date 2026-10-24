extends SceneTree

const Scheduler = preload("res://scripts/agents/decision_scheduler.gd")
const Brain = preload("res://scripts/agents/unit_brain.gd")
const Adapter = preload("res://scripts/agents/agent_adapter.gd")
var failures: Array[String] = []

class Fixture extends Node:
	var model := "fault-fixture"
	var endpoint := "fixture://offline"
	var enabled := true
	var concurrency := 6
	var metrics := {"calls":0,"fallbacks":0}
	var active := 0
	var peak := 0
	var calls: Array = []
	func supports_background_decisions() -> bool: return true
	func can_request_model(_ctx: Dictionary) -> bool: return true
	func choose_batch(contexts: Array) -> Dictionary:
		var ctx: Dictionary = contexts[0]
		active += 1
		peak = maxi(peak,active)
		metrics["calls"] += 1
		calls.append(ctx.get("actor_key",ctx["request_id"]))
		await get_tree().create_timer(0.3 if str(ctx["request_id"]).contains("slow") else 0.015).timeout
		active -= 1
		return {ctx["request_id"]:{"candidate_id":ctx["candidates"][0]["id"],"reason_summary":"测试规范战术","source":"model"}}

func _initialize() -> void: call_deferred("run")
func check(ok: bool, message: String) -> void:
	if not ok: failures.append(message); push_error(message)

func stub(id: String, level: String = "unit", tick: int = 1) -> Dictionary:
	return {"actor_key":id,"army_id":id,"level":level,"request_id":id+":"+str(tick),"battle_round":tick,"observation_revision":tick,"candidates":[{"id":"c00","action":{"type":"hold"}}]}

func run() -> void:
	var fixture := Fixture.new()
	root.add_child(fixture)
	var scheduler := Scheduler.new()
	scheduler.begin_round(1)
	scheduler.submit([stub("unit:slow"),stub("unit:fast")],fixture,{"unit:slow":"s","unit:fast":"f"})
	await create_timer(0.06).timeout
	check(scheduler.ready.has("unit:fast") and not scheduler.ready.has("unit:slow"),"快回复被整批慢回复阻塞")
	# 答案只在提交点（下一回合）可取。
	check(scheduler.take("unit:fast","f",1).is_empty(),"提交点之前就采用了模型答案")
	scheduler.begin_round(2)
	check(not scheduler.take("unit:fast","f",2).is_empty(),"当前合法回复未独立消费")
	scheduler.clear()
	await create_timer(0.32).timeout
	check(scheduler.ready.is_empty(),"重开后旧在途回复污染新场景")
	fixture.calls.clear()
	scheduler.begin_round(1)
	var contexts: Array = []
	var signatures := {}
	for i in range(80):
		var level := "commander" if i % 10 == 0 else "adviser" if i % 10 == 1 else "unit"
		var key := ("corps:" if level == "commander" else "officer:" if level == "adviser" else "unit:")+str(i)
		contexts.append(stub(key,level))
		signatures[key] = "s"
	var models: Node = root.get_node("ModelQueue")
	scheduler.submit(contexts,fixture,signatures)
	# 同一人同一类决策只留最新请求：重复提交不让队列增长；并发不超过夹具的上限。
	scheduler.submit(contexts,fixture,signatures)
	check(models.queued_count() + models.inflight_count() <= contexts.size() and fixture.peak <= fixture.concurrency,"队列或并发越界")
	await create_timer(0.09).timeout
	check(fixture.peak <= fixture.concurrency and not fixture.calls.is_empty(),"并发越界或请求没有发出")
	for tick in range(2,24):
		scheduler.begin_round(tick)
		var fresh: Array = []
		for ctx in contexts:
			var copy: Dictionary = ctx.duplicate(true)
			copy["battle_round"] = tick
			copy["request_id"] = copy["actor_key"]+":"+str(tick)
			fresh.append(copy)
		scheduler.submit(fresh,fixture,signatures)
		await create_timer(0.08).timeout
		for ctx in fresh: scheduler.take(ctx["actor_key"],"s",tick)
	check(fixture.calls.any(func(k): return str(k).begins_with("corps:")) and fixture.calls.any(func(k): return str(k).begins_with("unit:")),"主帅或部将调度饥饿")
	check(fixture.calls.any(func(k): return str(k).begins_with("officer:")),"参军调度饥饿")
	var served := {}
	for key in fixture.calls: served[key] = true
	print("MODEL_FAIRNESS served=",served.size(),"/",contexts.size()," missing=",contexts.filter(func(c): return not served.has(c["actor_key"])).map(func(c): return c["actor_key"]))
	check(served.size() == contexts.size(),"持续重提的80位武将仍有个人饥饿")
	scheduler.clear()
	var adapter := Adapter.new()
	root.add_child(adapter)
	var store: Node = root.get_node("GameState")
	store.persist_enabled = false
	store.prepare_battle_test(true,"plains_clash",42)
	await store.war.step()
	var ctx := Brain.context(store.war,store.war.active_armies()[1])
	adapter.endpoint = "http://127.0.0.1:1/api/chat"
	adapter.model = "fixture"
	adapter.enabled = true
	adapter.model_mode = "commanders"
	check(not adapter.can_request_model(ctx),"仅主帅模式仍请求部将")
	adapter.model_mode = "all"
	check(adapter.can_request_model(ctx),"全员模式部将不可请求")
	var payload := adapter._build_payload(ctx)
	var sent: Dictionary = JSON.parse_string(payload["messages"][1]["content"])
	for field in ["self","knowledge","current_plan","officer","task","authority"]: check(sent.has(field),"部将模型压缩丢失 "+field)
	check(not JSON.stringify(sent).contains("grain_days"),"补给关闭仍发送粮食风险")
	var failures_response := adapter.Client.decode(adapter.endpoint,HTTPRequest.RESULT_SUCCESS,200,"{bad".to_utf8_buffer())
	check(failures_response.has("error"),"畸形JSON未触发回退")
	check(adapter.Client.decode(adapter.endpoint,HTTPRequest.RESULT_CANT_CONNECT,503,PackedByteArray()).has("error"),"网络错误未触发回退")
	var result := await adapter.choose_batch([ctx])
	check(result[ctx["request_id"]].get("source","") != "model","断网没有本地接管")
	store.restore_battle_test()
	fixture.queue_free()
	adapter.queue_free()
	print("UNIT_MODEL_OK" if failures.is_empty() else "UNIT_MODEL_FAILED "+str(failures))
	quit(0 if failures.is_empty() else 1)
