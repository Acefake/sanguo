extends SceneTree
const Officers = preload("res://scripts/agents/officer_brain.gd")
const Policy = preload("res://scripts/agents/baseline_policy.gd")
const Adapter = preload("res://scripts/agents/agent_adapter.gd")
const Roster = preload("res://scripts/agents/officer_context.gd")
var failures: Array[String] = []
class StaffAgent extends Node:
	var model := "staff-fixture"
	var endpoint := "fixture://staff"
	var enabled := true
	var metrics := {"fallbacks":0}
	func supports_background_decisions() -> bool: return true
	func can_request_model(ctx: Dictionary) -> bool: return ctx.get("level","") == "adviser"
	func choose_batch(contexts: Array) -> Dictionary:
		var result := {}
		for ctx in contexts: result[ctx["request_id"]] = {"candidate_id":ctx["candidates"][0]["id"],"reason_summary":"依据已知军情核实敌情","source":"model"}
		return result
func _initialize() -> void: call_deferred("run")
func check(ok: bool, text: String) -> void:
	if not ok: failures.append(text); push_error(text)
func run() -> void:
	var store: Node = root.get_node("GameState")
	store.persist_enabled = false
	store.agent.enabled = false
	store.prepare_battle_test(true,"plains_clash",42)
	var war = store.war
	await war.step()
	var identities := {}
	var adviser: Dictionary = {}
	for corps in war.state["corps"].values():
		for id in corps["members"]:
			check(war.state["officer_agents"].has(id),"武将缺少独立agent身份")
			var agent: Dictionary = war.state["officer_agents"][id]
			check(not identities.has(agent["actor_key"]),"武将agent重复注册")
			identities[agent["actor_key"]] = true
			if agent["role"] == "adviser":
				adviser = agent
				check(agent["facets"].has("adviser"),"参军没有自主建议")
				check(agent["binding"]["army_id"] == "","参军创建了幽灵部队")
	check(not adviser.is_empty(),"真实六人军团没有参军agent")
	var ctx := Officers.context(war,adviser)
	var bodies: Dictionary = war.state["armies"].duplicate(true)
	Officers.choose(ctx)
	check(war.state["armies"] == bodies,"参谋决策修改实际部队")
	check(ctx["authority"]["advice_only"] and not ctx["authority"]["may_execute"],"参军越过主帅军令权限")
	var low: Dictionary = ctx.duplicate(true)
	var high: Dictionary = ctx.duplicate(true)
	low["weak_count"] = 1
	high["weak_count"] = 1
	low["candidates"] = [{"id":"support","action":{"type":"advise","kind":"support"},"description":"救援"}]
	high["candidates"] = low["candidates"].duplicate(true)
	low["officer"]["personality"]["同理心"] = 0
	high["officer"]["personality"]["同理心"] = 100
	check(Officers.rank(high)[0]["score"] > Officers.rank(low)[0]["score"],"参谋人格没有影响判断")
	var adapter := Adapter.new()
	root.add_child(adapter)
	adapter.enabled = true
	adapter.endpoint = "http://127.0.0.1:1/api/chat"
	adapter.model = "fixture"
	adapter.model_mode = "commanders"
	check(not adapter.can_request_model(ctx),"仅主帅模式请求了参军")
	adapter.model_mode = "all"
	var sent: Dictionary = JSON.parse_string(adapter._build_payload(ctx)["messages"][1]["content"])
	for key in ["officer","knowledge","authority","task"]: check(sent.has(key),"参谋payload缺少 "+key)
	check(Policy.choose(ctx)["candidate_id"] == Officers.choose(ctx)["candidate_id"],"本地模型回退丢失参军决策")
	var saved: Dictionary = war.export_state()
	war.setup(store,JSON.parse_string(JSON.stringify(saved)))
	check(war.state["officer_agents"].has(adviser["officer_id"]),"读档丢失武将agent")
	var corps: Dictionary = war.state["corps"][adviser["binding"]["corps_id"]]
	var cctx: Dictionary = war.Corps.commander_context(war,corps)
	check(not cctx["officer_advice"].is_empty(),"独立参谋建议未送达主帅")
	war.state["officer_states"][adviser["officer_id"]]["status"] = "available"
	Officers.sync(war)
	check(war.state["officer_agents"][adviser["officer_id"]]["role"] == "resident","归营武将仍在战区发出建议")
	# Bad card values are defaulted or clamped with explicit provenance.
	var roster := Roster.new()
	roster.setup([{"id":"fixture","name":"数值样本","substats":[["bad",140,-3]],"sections":{"人格数值":"风险承受:-20 耐心:9999 同理心:bad 自制:65.5"}}],{})
	var card: Dictionary = roster.officers["fixture"]
	check(card["skills"]["带兵"] == 50 and card["skills"]["布阵"] == 120 and card["skills"]["水练"] == 0,"异常技能没有合理默认或截断")
	check(card["personality"]["风险承受"] == 0 and card["personality"]["耐心"] == 100 and card["personality"]["同理心"] == 50 and card["personality"]["自制"] == 65,"人格解析截断数字或丢失符号")
	check(card["data_sources"]["skills"]["带兵"] == "invalid_default" and card["data_sources"]["personality"]["同理心"] == "invalid_default","异常默认值没有来源记录")
	# Exercise model adoption at the next boundary and its saved deterministic replay.
	store.prepare_battle_test(true,"plains_clash",42)
	war = store.war
	var fixture := StaffAgent.new()
	root.add_child(fixture)
	await war.step(fixture)
	var before: Dictionary = war.export_state()
	await war.step(fixture)
	var records: Array = war.state["battle_ai_model_log"].filter(func(r): return str(r["actor_key"]).begins_with("officer:"))
	check(not records.is_empty(),"参军模型没有在边界采纳")
	var expected: Array = war.active_armies().map(func(a): return [a["id"],a["units"],a["tactical"]["cell"]])
	war.setup(store,JSON.parse_string(JSON.stringify(before)))
	war.state["battle_ai_replay"] = records.duplicate(true)
	await war.step()
	var replayed: Array = war.active_armies().map(func(a): return [a["id"],a["units"],a["tactical"]["cell"]])
	check(preload("res://scripts/agents/tactical_plan.gd").normalized(expected) == preload("res://scripts/agents/tactical_plan.gd").normalized(replayed),"参军回复存档重放改变战斗")
	check(war.state["officer_agents"].values().any(func(a): return a.get("facets",{}).get("adviser",{}).get("source","") == "model"),"参军重放没有采纳记录")
	fixture.queue_free()
	adapter.queue_free()
	store.restore_battle_test()
	print("OFFICER_AGENTS_OK" if failures.is_empty() else "OFFICER_AGENTS_FAILED")
	quit(0 if failures.is_empty() else 1)
