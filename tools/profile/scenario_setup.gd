extends RefCounted
## 剖析用剧本：在演示剧本上按 JSON 描述追加开局动作（只用于测量与回归，不进游戏代码路径）。
##
## 文件格式（data/war/perf_scenarios/*.json）：
##   {"id": "...", "summary": "...", "days": 30,
##    "mobilize": [{"home": "城池 id", "target": "城池 id", "officer": "可选，武将 id", "orders": {可选，覆盖军令字段}}]}
## mobilize 逐条用 preview_dispatch + _mobilize 组建独立部队（不编军团），与势力战略 AI 出兵走同一通道；
## 不写 officer 时取该城势力可出征武将（按名字排序）里第一个能通过预览的。军令先取君主的进攻军令
## （与势力战略 AI 相同），再用 orders 覆盖（例如 {"retreat": false} 让部队不在出发地就撤回）。
## 任何一条失败都报错并返回 false。

const StrategicAI = preload("res://scripts/war/campaign/strategic_ai.gd")


## 读取剧本描述；路径为空时返回空字典。
static func load_spec(path: String) -> Dictionary:
	if path == "": return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not parsed is Dictionary:
		push_error("剖析剧本不是有效的 JSON 对象：" + path)
		return {}
	return parsed


## 在已载入演示剧本的 store 上执行开局动作。
static func apply(store, spec: Dictionary) -> bool:
	var war = store.war
	for entry in spec.get("mobilize", []):
		var home := str(entry["home"])
		var target := str(entry["target"])
		var faction := str(store.city_state(home).get("faction", ""))
		var preview := {}
		var candidates: Array = [str(entry["officer"])] if entry.has("officer") else war.available_officers(faction).map(func(officer): return str(officer["id"]))
		for officer_id in candidates:
			preview = war.preview_dispatch(home, target, officer_id)
			if bool(preview.get("ok", false)): break
		if not bool(preview.get("ok", false)):
			push_error("剖析剧本出兵失败 %s→%s：%s" % [home, target, str(preview.get("message", "没有可出征武将"))])
			return false
		var army: Dictionary = war._mobilize(preview)
		army["orders"] = StrategicAI.lord_orders(StrategicAI.lord_of(war.roster, faction, war.state["officer_states"]), "attack")
		army["orders"].merge(entry.get("orders", {}), true)
	war._observe_all()
	return true
