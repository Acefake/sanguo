extends SceneTree

const Fort = preload("res://scripts/war/city_fortifications.gd")
func _initialize() -> void: call_deferred("run")
func run() -> void:
	var store = root.get_node("GameState")
	store.persist_enabled = false
	store._load_demo()
	var missing: Array = []
	var illegal: Array = []
	var ferries: Array = []
	var mountain_roads: Array = []
	var buildings := {}
	for site in Fort.sites(store).values():
		for cell in site["cells"]: buildings[int(cell)] = true
	for edge in store.war.graph.edges.values():
		var path := Fort.road_path(store, edge["from"], edge["to"])
		if path.is_empty(): missing.append(edge["id"])
		for cell in path:
			var water: bool = Fort.Grid.shared().terrain(cell) in Fort.WATER_CODES
			if water and not ferries.has(edge["id"]): ferries.append(edge["id"])
			var mountain: bool = Fort.Grid.shared().terrain(cell) in Fort.MOUNTAIN_ROAD_CODES
			if mountain and not mountain_roads.has(edge["id"]): mountain_roads.append(edge["id"])
			if buildings.has(cell) or (not Fort.Grid.shared().walkable(cell) and not water and not mountain): illegal.append({"edge": edge["id"], "cell": cell})
	var file := FileAccess.open("res://docs/validation/campaign-routes-2026-10-06.json", FileAccess.WRITE)
	file.store_string(JSON.stringify({"routes": store.war.graph.edges.size(), "missing": missing, "illegal": illegal, "ferry_routes": ferries, "mountain_roads": mountain_roads}, "\t"))
	print("CAMPAIGN_ROUTES ", store.war.graph.edges.size(), " MISSING ", missing, " ILLEGAL ", illegal)
	var connected := true
	for node in store.war.graph.places:
		if not store.war.graph.path("xiaopei", node)["found"]: connected = false; print("ISOLATED ", node)
	print("CAMPAIGN_ROUTES_OK" if missing == store.war.graph.closed_routes and connected and illegal.is_empty() else "CAMPAIGN_ROUTES_FAILED")
	quit(0 if missing == store.war.graph.closed_routes and connected and illegal.is_empty() else 1)
