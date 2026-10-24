extends SceneTree
const Brain = preload("res://scripts/agents/unit_brain.gd")
const Officers = preload("res://scripts/agents/officer_brain.gd")
var records: Array = []
func _initialize() -> void: call_deferred("run")
func run() -> void:
	var store: Node = root.get_node("GameState")
	store.persist_enabled = false
	store.agent.enabled = false
	for count in [20,40,80]:
		store.prepare_battle_test(true,"plains_clash",42)
		var war = store.war
		var originals: Array = war.active_armies().duplicate(true)
		war.state["corps"] = {}
		war.state["armies"] = {}
		var board: Dictionary = war.state["battlefield"]
		var spaces: Array = []
		for q in range(int(board["min_column"])+1,int(board["max_column"])):
			for r in range(int(board["min_row"])+1,int(board["max_row"])):
				var cell: int = war.Tactical.cell_at(q,r)
				if war.Tactical.can_enter(war,originals[0],cell): spaces.append(cell)
		assert(spaces.size() >= count)
		for i in range(count):
			var unit: Dictionary = originals[i%originals.size()].duplicate(true)
			var id := "stress-%03d" % i
			var officer := "stress-officer-%03d" % i
			war.roster.officers[officer] = war.roster.officers[unit["officer_id"]].duplicate(true)
			war.roster.officers[officer]["id"] = officer
			unit["id"] = id
			unit["officer_id"] = officer
			unit["departure_at"] = 0
			unit["tactical"]["cell"] = spaces[i]
			unit.erase("battle_ai")
			unit.erase("corps_id")
			unit["corps_task"] = {"type":"main_attack"}
			unit["operation"] = {"role":"main_attack","support_id":""}
			war.state["armies"][id] = unit
		Officers.initialize(war)
		war._observe_all()
		var saved: Dictionary = war.export_state()
		var timings: Array = []
		for repetition in range(13):
			war.state = saved.duplicate(true)
			Brain.decide(war)
			assert(war.state["battle_ai_metrics"]["actors"] == count)
			if repetition > 0: timings.append(war.state["battle_ai_metrics"]["decision_ms"])
			await process_frame
		timings.sort()
		var record := {"actors":count,"samples":timings.size(),"decision_p50_ms":timings[timings.size()/2],"decision_p95_ms":timings[-1],"suggested_20ms_target_met":timings[-1] <= 20,"settings":war.Policy.weights()["tactical"],"stages":war.state["battle_ai_metrics"]["stages_ms"],"context_us":war.state["battle_ai_metrics"]["context_us"]}
		records.append(record)
		print("TACTICAL_PERF ",JSON.stringify(record))
	FileAccess.open("res://docs/validation/tactical-performance-2026-10-10.json",FileAccess.WRITE).store_string(JSON.stringify({"records":records,"method":"Complete local decision stage, identical frozen war input reset outside timing, one warm-up and twelve timed samples. Synthetic unique officer identities and real walkable grid. Other machine load is not controlled."},"\t"))
	store.restore_battle_test()
	print("TACTICAL_PERFORMANCE_OK")
	quit()
