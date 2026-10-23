class_name MapGraph
extends RefCounted
## 战役路网：城池与道路、邻接、带缓存的最短路径、封锁、可见节点与坐标。

var places: Dictionary = {}
var edges: Dictionary = {}
var adjacent: Dictionary = {}
var blocked: Array = []
var closed_routes: Array = []


func setup(data: Dictionary) -> void:
	places.clear(); edges.clear(); adjacent.clear(); blocked.clear(); closed_routes.clear()
	invalidate_paths()
	for place in data.get("places", []):
		places[str(place["id"])] = place
		adjacent[str(place["id"])] = []
	for edge in data.get("routes", []):
		edges[str(edge["id"])] = edge
		adjacent[str(edge["from"])].append({"node": str(edge["to"]), "edge": str(edge["id"])})
		adjacent[str(edge["to"])].append({"node": str(edge["from"]), "edge": str(edge["id"])})


func neighbors(node: String) -> Array:
	var result: Array = []
	for link in adjacent.get(node, []):
		if not blocked.has(node) and not blocked.has(link["node"]) and not closed_routes.has(link["edge"]):
			result.append(link)
	return result


# Candidate generation and the outcome forecast both ask for the same routes, so a
# whole-graph Dijkstra per pair per army per decision dominated the day loop. Routes
# only change when a pass is blocked, so memoise on that generation.
var _path_cache: Dictionary = {}
var _path_generation: int = 0


func invalidate_paths() -> void:
	_path_generation += 1
	_path_cache.clear()


## 路径缓存的代数：封锁变化或重新 setup 时加一。依赖路径结果的外部缓存用它判断是否过期。
func path_generation() -> int:
	return _path_generation


func set_blocked(nodes: Array) -> void:
	if str(blocked) == str(nodes): return
	blocked = nodes
	invalidate_paths()


func path(start: String, finish: String, excluded: Array = []) -> Dictionary:
	var exclusions := excluded.duplicate()
	exclusions.sort()
	var key := "%s>%s:%s" % [start, finish, str(exclusions)]
	if _path_cache.has(key): return _path_cache[key]
	var result := _search(start, finish, exclusions)
	_path_cache[key] = result
	return result


func _search(start: String, finish: String, excluded: Array = []) -> Dictionary:
	if not places.has(start) or not places.has(finish):
		return {"found": false, "nodes": [], "edges": [], "cost": 0.0}
	var distance: Dictionary = {start: 0.0}
	var previous: Dictionary = {}
	var visited: Dictionary = {}
	var frontier: Array = [start]
	while not frontier.is_empty():
		frontier.sort_custom(func(a, b): return float(distance[a]) < float(distance[b]) if float(distance[a]) != float(distance[b]) else str(a) < str(b))
		var current: String = str(frontier.pop_front())
		if visited.has(current):
			continue
		visited[current] = true
		if current == finish:
			break
		for link in neighbors(current):
			var next: String = str(link["node"])
			if excluded.has(next) and next != finish: continue
			var cost: float = float(distance[current]) + float(edges[link["edge"]].get("cost", 1))
			if not visited.has(next) and (not distance.has(next) or cost < float(distance[next])):
				distance[next] = cost
				previous[next] = {"node": current, "edge": link["edge"]}
				frontier.append(next)
	if not visited.has(finish):
		return {"found": false, "nodes": [], "edges": [], "cost": 0.0}
	var nodes: Array = [finish]
	var links: Array = []
	var cursor: String = finish
	while cursor != start:
		links.push_front(previous[cursor]["edge"])
		cursor = str(previous[cursor]["node"])
		nodes.push_front(cursor)
	return {"found": true, "nodes": nodes, "edges": links, "cost": distance[finish]}


func visible_nodes(node: String, radius: int = 1) -> Array:
	var result: Array = [node]
	var frontier: Array = [node]
	for step in range(radius):
		var next: Array = []
		for current in frontier:
			for link in neighbors(str(current)):
				if not result.has(link["node"]):
					result.append(link["node"])
					next.append(link["node"])
		frontier = next
	return result


func position(location: Dictionary) -> Vector2:
	var node: String = str(location.get("node", ""))
	var edge_id: String = str(location.get("edge", ""))
	if edge_id == "" or not edges.has(edge_id):
		var place: Dictionary = places.get(node, {})
		return Vector2(float(place.get("x", 0)), float(place.get("y", 0)))
	var edge: Dictionary = edges[edge_id]
	var start: Dictionary = places[str(edge["from"])]
	var finish: Dictionary = places[str(edge["to"])]
	var progress: float = float(location.get("progress", 0))
	if str(location.get("from", "")) != str(edge["from"]):
		progress = 1.0 - progress
	return Vector2(float(start["x"]), float(start["y"])).lerp(Vector2(float(finish["x"]), float(finish["y"])), progress)


func name_of(node: String) -> String:
	return str(places.get(node, {}).get("name", node))
