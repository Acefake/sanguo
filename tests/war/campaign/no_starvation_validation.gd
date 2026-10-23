extends SceneTree

const Store = preload("res://scripts/core/game_state.gd")
const Adapter = preload("res://scripts/agents/agent_adapter.gd")
const Corps = preload("res://scripts/war/campaign/army_corps.gd")
var failures: Array = []

func check(ok: bool, message: String) -> void:
	if not ok: failures.append(message); push_error(message)

func _initialize() -> void:
	var store := Store.new()
	store.persist_enabled = false
	store._load_demo()
	var war = store.war
	var home: Dictionary = store.city_state("luoyang")
	home["faction"] = "liu_bei"
	home["garrison"] = 10000
	home["units"] = {"infantry": 10000, "archers": 0, "cavalry": 0}
	home["grain"] = 0
	var officer_id := str(war.available_officers("liu_bei")[0]["id"])
	var preview: Dictionary = war.preview_dispatch("luoyang", "hongnong", officer_id)
	check(not war.supply_enabled() and preview["ok"] and preview["strength"] > 0, "零粮仍能出征")
	var army: Dictionary = war._mobilize(preview)
	army["morale"] = 85.0
	army["organization"] = 85.0
	var count: int = war.Combat.strength(army)
	for day in range(30):
		war.state["tick"] = day
		war._upkeep()
	check(war.Combat.strength(army) == count and not army["returning"], "断粮不再减员或强制撤退")
	check(army["morale"] >= 85 and army["organization"] >= 85, "断粮不再降低士气组织")
	check(war.state["reports"].all(func(r): return r["kind"] != "缺粮"), "不再生成缺粮军报")
	var context: Dictionary = war.context_for(army)
	check(context["army"]["grain_days"] == 999 and not context["supply_enabled"], "本地策略不再判断缺粮")
	check(context["candidates"].all(func(c): return c["action"]["type"] != "resupply" and not c.get("forecast", {}).has("grain_after")), "移除补给候选和粮草预测")
	var adapter := Adapter.new()
	adapter.endpoint = "http://127.0.0.1:11434/api/chat"
	var payload: Dictionary = adapter._build_payload(context)
	check(not str(payload["messages"][1]["content"]).contains("grain_days"), "模型不再收到粮草判断字段")
	adapter.free()
	var before: int = home["grain"]
	store._consume_city_food()
	check(home["grain"] == before, "驻军不消耗口粮")
	var enemy: Dictionary = store.city_state("hongnong")
	enemy["faction"] = "yuan_shao"
	enemy["grain"] = 0
	enemy["garrison"] = 1200
	enemy["units"] = {"infantry": 1200, "archers": 0, "cavalry": 0}
	army["location"] = {"node": "hongnong", "edge": "", "progress": 0.0}
	army["action"] = {"type": "besiege"}
	war.state["tick"] += 1
	war._resolve_sieges()
	check(enemy["garrison"] == 1200 and war.state["sieges"]["hongnong"]["morale"] == 100, "零粮守军在准备阶段仍受断粮惩罚")
	var saved: Dictionary = war.export_state()
	war.setup(store, saved)
	check(not war.supply_enabled() and war.state["armies"].has(army["id"]), "旧存档可读取且系统保持关闭")
	store.free()
	print("NO_STARVATION: " + ("PASS" if failures.is_empty() else str(failures)))
	quit(0 if failures.is_empty() else 1)
