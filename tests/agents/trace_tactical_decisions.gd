extends SceneTree
const Brain = preload("res://scripts/agents/unit_brain.gd")
const Evaluator = preload("res://scripts/agents/tactical_evaluator.gd")
var records: Array = []
func _initialize() -> void: call_deferred("run")
func run() -> void:
	var store: Node = root.get_node("GameState")
	store.persist_enabled = false
	store.agent.enabled = false
	var scenario := "marsh_battle"
	var rounds := 120
	var seed_value := 42
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--scenario="): scenario = arg.substr(11)
		if arg.begins_with("--rounds="): rounds = int(arg.substr(9))
		if arg.begins_with("--seed="): seed_value = int(arg.substr(7))
	store.prepare_battle_test(false,scenario,seed_value)
	for day in range(rounds):
		await store.war.step()
		if store.war.state["battlefield"].has("winner"): break
	var frozen := Brain.freeze(store.war)
	for army in store.war.active_armies():
		if army["returning"]: continue
		var ctx := Brain.context(store.war,army,frozen)
		var ranked := Evaluator.rank(ctx)
		var top: Array = []
		for entry in ranked.slice(0,5):
			top.append({"plan":entry["candidate"]["canonical_plan"],"action":entry["candidate"]["action"],"score":entry["score"],"breakdown":entry["breakdown"]})
		var row := {"id":army["id"],"name":army["name"],"cell":ctx["self"]["cell"],"role":ctx["task"]["role"],"local_state":ctx["local_state"],"strength":ctx["self"]["strength"],"units":ctx["self"]["units"],"contact":ctx["self"]["contact"],"health":[army["organization"],army["morale"],army["fatigue"]],"plan":ctx["current_plan"],"allies":ctx["knowledge"]["allies"],"enemies":ctx["knowledge"]["enemies"],"top":top,"history":army.get("battle_ai",{}).get("history",[]).slice(-20),"last_damage":[army.get("daily_loss_tick",-1),army.get("daily_loss",0)]}
		records.append(row)
		print("TACTICAL_TRACE ",JSON.stringify({"name":row["name"],"cell":row["cell"],"role":row["role"],"top":top}))
	FileAccess.open("res://docs/validation/tactical-trace-"+scenario+".json",FileAccess.WRITE).store_string(JSON.stringify({"scenario":scenario,"round":store.war.state["battle_round"],"winner":store.war.state["battlefield"].get("winner",""),"sieges":store.war.state["sieges"],"corps":store.war.state["corps"].values().map(func(c): return {"id":c["id"],"siege_approach":c.get("siege_approach",false),"orders":c["orders"].slice(-5)}),"fortifications":store.war.state["battlefield"].get("fortifications",{}),"units":records},"\t"))
	store.restore_battle_test()
	quit()
