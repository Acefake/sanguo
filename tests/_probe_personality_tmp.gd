extends SceneTree

const Brain = preload("res://scripts/agents/unit_brain.gd")
const Evaluator = preload("res://scripts/agents/tactical_evaluator.gd")
const Plan = preload("res://scripts/agents/tactical_plan.gd")

var store

func _initialize() -> void:
	call_deferred("run")

func profile(values: Dictionary) -> Dictionary:
	var axes := ["野心", "风险承受", "耐心", "决断", "自制", "猜疑", "自尊", "同理心", "秩序偏好", "务实", "记仇", "容人", "贪欲", "忠义"]
	var result := {}
	for axis in axes:
		result[axis] = int(values.get(axis, 50))
	return result

func run() -> void:
	print("STAGE start")
	store = root.get_node_or_null("GameState")
	if store == null:
		print("STAGE no_gamestate")
		quit(2)
		return
	store.persist_enabled = false
	store.agent.enabled = false
	store.prepare_battle_test(true, "plains_clash", 42)
	print("STAGE prepared")
	var war = store.war
	var side: Array = war.active_armies("liu_bei")
	print("STAGE armies ", side.size())
	if side.size() < 2:
		quit(3)
		return
	var army: Dictionary = side[1]
	var officer: Dictionary = war.roster.officers[army["officer_id"]]
	var original: Dictionary = officer["personality"].duplicate(true)
	Plan.ensure(war, army)
	var cases := {
		"flat": profile({}),
		"zhuge": profile({"野心": 72, "风险承受": 70, "耐心": 98, "决断": 89, "自制": 96, "猜疑": 64, "自尊": 78, "同理心": 86, "秩序偏好": 100, "务实": 99, "记仇": 35, "容人": 88, "贪欲": 10, "忠义": 98}),
		"weiyan": profile({"野心": 84, "风险承受": 92, "耐心": 66, "决断": 94, "自制": 73, "猜疑": 69, "自尊": 98, "同理心": 49, "秩序偏好": 67, "务实": 91, "记仇": 69, "容人": 50, "贪欲": 28, "忠义": 79}),
		"yuanshao": profile({"野心": 88, "风险承受": 62, "耐心": 58, "决断": 52, "自制": 54, "猜疑": 86, "自尊": 96, "同理心": 64, "秩序偏好": 78, "务实": 60, "记仇": 70, "容人": 72, "贪欲": 48, "忠义": 56})
	}
	for label in ["flat", "zhuge", "weiyan", "yuanshao"]:
		officer["personality"] = cases[label]
		army["battle_ai"]["plan"] = {}
		army["battle_ai"]["local_state"] = "active"
		var ctx := Brain.context(war, army)
		var result := Evaluator.choose(ctx)
		var ranked := Evaluator.rank(ctx)
		var top: Array = []
		for entry in ranked.slice(0, 3):
			top.append("%s=%.2f" % [entry["candidate"]["canonical_plan"]["template"], float(entry["score"])])
		print("PROBE %s pick=%s score=%.2f margin=%.2f personality=%.2f top=%s" % [label, result.get("candidate_id", ""), float(result.get("score", 0)), float(result.get("margin", 0)), float(result.get("score_breakdown", {}).get("人格倾向", 0)), ",".join(top)])
	officer["personality"] = original
	print("STAGE done")
	quit(0)
