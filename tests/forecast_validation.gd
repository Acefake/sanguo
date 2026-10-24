extends SceneTree

const Forecast = preload("res://scripts/agents/forecast.gd")
const Combat = preload("res://scripts/war/combat_system.gd")
const Tactical = preload("res://scripts/war/tactical_battlefield.gd")
var failures: Array[String] = []

func _initialize() -> void: call_deferred("_run")

func check(value: bool, message: String) -> void:
	if not value:
		failures.append(message)
		push_error(message)

func _run() -> void:
	var store: Node = root.get_node("GameState")
	store.persist_enabled = false
	store.prepare_battle_test(true)
	var war = store.war
	war._observe_all()
	var own: Dictionary = war.active_armies("liu_bei")[0]
	var terrain: String = Tactical.terrain_class(int(own["tactical"]["cell"])) if own.has("tactical") else "plains"
	var enemies := {"e1": {"id": "e1", "unit_mix_estimate": {"infantry": 800, "archers": 200, "cavalry": 0}, "strength_estimate": 1000, "routing": false}}
	var engage := {"id": "engage:e1", "action": {"type": "engage", "enemy": "e1"}, "description": "交战"}
	var hold := {"id": "hold", "action": {"type": "hold"}, "description": "驻守"}
	var march := {"id": "march:luoyang", "action": {"type": "march", "target": "luoyang", "edge": ""}, "description": "行军"}
	var candidates: Array = [engage, hold, march]
	var state_before: String = JSON.stringify(war.state)
	var rng_before: int = war.rng.state
	Forecast.annotate(war, own, candidates, {"terrain": terrain, "enemies": enemies})
	check(JSON.stringify(war.state) == state_before, "预估修改了战局状态")
	check(war.rng.state == rng_before, "预估消耗了随机数")
	check(engage["forecast"].has("own_loss") and int(engage["forecast"]["own_loss"]) > 0, "接战候选没有损失预估")
	check(engage["forecast"]["kill_ratio"] > 0 and not engage["forecast"]["notes"].is_empty(), "接战预估缺少杀伤比或依据")
	check(not hold["forecast"].has("own_loss"), "无对手的驻守候选出现了损失预估")
	check(hold["forecast"]["notes"].is_empty(), "无对手候选不应有依据")
	check(march["forecast"].has("eta_days") and march["forecast"].has("flank_risk"), "行军候选缺少到达日或夹击风险")
	var estimate: Dictionary = Forecast.ESTIMATE.duplicate(true)
	estimate["units"] = {"infantry": 800, "archers": 200, "cavalry": 0}
	estimate["initial_strength"] = 1000
	estimate["action"] = {"type": "hold"}
	estimate["name"] = "敌军"
	var direct: Dictionary = Combat.losses_detail(estimate, own, war.rules, terrain, 1.0)
	check(absi(int(engage["forecast"]["own_loss"]) - int(direct["loss"])) <= 1, "预估与同一公式的直接结算不一致")
	check(Combat.losses(estimate, own, war.rules, terrain, 1.0) == int(direct["loss"]), "losses() 与 losses_detail() 结果不一致")
	# 情报缺失：完全没有侦察记录时不报错，字段留空。
	var bare := {"id": "engage:none", "action": {"type": "engage", "enemy": "none"}, "description": "交战"}
	Forecast.annotate(war, own, [bare], {"terrain": terrain, "enemies": {}})
	check(not bare["forecast"].has("own_loss") and not bare["forecast"].has("kill_ratio"), "情报缺失时不应给出损失预估")
	var source: int = own["tactical"]["cell"]
	var near: int = Tactical.neighbors(source)[0]
	var sight := {"observed_at":war.state["tick"],"tactical_cell":near,"strength_estimate":1000,"unit_mix_estimate":{"infantry":1000,"archers":0,"cavalry":0}}
	Forecast.annotate(war,own,[hold],{"terrain":terrain,"enemies":{"near":sight}})
	check(hold["forecast"].get("under_attack",false),"当前相邻敌情没有产生受击预估")
	sight["observed_at"] = int(war.state["tick"])-1
	Forecast.annotate(war,own,[hold],{"terrain":terrain,"enemies":{"near":sight}})
	check(not hold["forecast"].has("own_loss"),"过期敌情产生当前受击预估")
	var far := -1
	var board: Dictionary = Tactical.board_for(war,own)
	for step in Tactical.neighbors(source):
		for candidate in Tactical.neighbors(step):
			if Tactical.cell_distance(source,candidate) == 2 and Tactical.can_enter(war,own,candidate) and preload("res://scripts/war/city_fortifications.gd").line_of_sight(board,source,candidate): far = candidate; break
		if far >= 0: break
	check(far >= 0,"没有合法两格射击预估位置")
	if far >= 0:
		sight["observed_at"] = war.state["tick"]
		sight["tactical_cell"] = far
		Forecast.annotate(war,own,[hold],{"terrain":terrain,"enemies":{"far":sight}})
		check(not hold["forecast"].has("own_loss"),"两格之外的步兵产生受击预估")
		sight["unit_mix_estimate"] = {"infantry":0,"archers":1000,"cavalry":0}
		Forecast.annotate(war,own,[hold],{"terrain":terrain,"enemies":{"far":sight}})
		estimate = Forecast._estimate_from(sight)
		estimate["ranged_attack"] = true
		direct = Combat.losses_detail(estimate,own,war.rules,terrain,1.0)
		check(hold["forecast"].get("own_loss",-1) == direct["loss"],"两格弓兵没有按远射公式预估")
	check(JSON.stringify(war.state) == state_before and war.rng.state == rng_before,"距离预估修改战局或随机数")
	store.restore_battle_test()
	print("FORECAST_OK: read-only, no rng use, formula-consistent estimates, missing intel defaults" if failures.is_empty() else "FORECAST_FAILED")
	quit(0 if failures.is_empty() else 1)
