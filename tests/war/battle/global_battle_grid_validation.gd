extends SceneTree

const Tactical = preload("res://scripts/war/battle/tactical_battlefield.gd")

func _initialize() -> void: call_deferred("run")

func run() -> void:
	var store: Node = root.get_node("GameState")
	store.persist_enabled = false
	store.prepare_battle_test(true)
	var grid = Tactical.grid()
	var board: Dictionary = store.war.state["battlefield"]
	assert(board["grid"] == "global")
	for army in store.war.active_armies():
		var cell: int = int(army["tactical"]["cell"])
		assert(grid.valid(cell) and grid.walkable(cell))
		assert(grid.pick(Tactical.world_cell(cell)) == cell)
		assert(Tactical.neighbors(cell) == grid.neighbors(cell))
		for neighbor in grid.neighbors(cell): assert(Tactical.cell_distance(cell, neighbor) == 1)
	for cell in board["blocked"]: assert(not grid.walkable(int(cell)))
	for day in range(8):
		await store.war.step(null)
		for army in store.war.active_armies():
			if army.has("tactical"): assert(grid.walkable(int(army["tactical"]["cell"])))
	print("GLOBAL_BATTLE_GRID_OK: shared IDs, six neighbors, world registration, terrain and eight-day movement")
	quit()
