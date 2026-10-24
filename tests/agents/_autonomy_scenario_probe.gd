extends SceneTree

# 临时探针（非交付测试）：对比自主决策开启/强制服从两种设定下，
# plains_clash 在相同种子内是否能在100日内产生胜负。
const Autonomy = preload("res://scripts/agents/officer_autonomy.gd")

func _initialize() -> void: call_deferred("run")

func probe(store: Node, force: String, seed_value: int) -> Dictionary:
	store.prepare_battle_test(false, "plains_clash", seed_value)
	var war = store.war
	if force != "":
		war.rules["corps"] = {"autonomy": {"forced_stance": force}}
	var counted := {"object": 0, "act": 0, "days": 0}
	for day in range(100):
		await war.step(null)
		counted["days"] = day + 1
		for corps in war.state["corps"].values():
			for entry in corps.get("autonomy", {}).get("stances", {}).values():
				if str(entry.get("stance", "")) == "object": counted["object"] += 1
				elif str(entry.get("stance", "")) == "act": counted["act"] += 1
		if war.state["battlefield"].has("winner"):
			counted["winner"] = str(war.state["battlefield"]["winner"])
			break
	if not counted.has("winner"): counted["winner"] = "交战中"
	return counted

func run() -> void:
	var store: Node = root.get_node("GameState")
	store.persist_enabled = false
	for scenario in ["city_relief", "plains_clash"]:
		for seed_value in [1910901, 42]:
			var live := await probe2(store, "", scenario, seed_value)
			print("PROBE live %s %d " % [scenario, seed_value], JSON.stringify(live))
			var obey := await probe2(store, "obey", scenario, seed_value)
			print("PROBE obey %s %d " % [scenario, seed_value], JSON.stringify(obey))
	quit(0)

func probe2(store: Node, force: String, scenario: String, seed_value: int) -> Dictionary:
	store.prepare_battle_test(false, scenario, seed_value)
	var war = store.war
	if force != "":
		war.rules["corps"] = {"autonomy": {"forced_stance": force}}
	var counted := {"object": 0, "act": 0, "days": 0}
	for day in range(120 if scenario == "city_relief" else 100):
		await war.step(null)
		counted["days"] = day + 1
		for corps in war.state["corps"].values():
			for entry in corps.get("autonomy", {}).get("stances", {}).values():
				if str(entry.get("stance", "")) == "object": counted["object"] += 1
				elif str(entry.get("stance", "")) == "act": counted["act"] += 1
		if war.state["battlefield"].has("winner"):
			counted["winner"] = str(war.state["battlefield"]["winner"])
			break
	if not counted.has("winner"): counted["winner"] = "交战中"
	return counted
