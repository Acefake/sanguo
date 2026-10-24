extends "res://tests/war/duel/duel_v2_validation.gd"

# Focused state/event regression; use duel_v2_validation.gd for the seed corpus.
func run() -> void:
	var store = root.get_node("GameState")
	store.persist_enabled = false
	store.agent.enabled = false
	store.prepare_battle_test(true)
	edges(store.war,store)
	print("DUEL_ROUNDS_OK checks=%d failures=%d" % [checks,failures.size()])
	quit(0 if failures.is_empty() else 1)
