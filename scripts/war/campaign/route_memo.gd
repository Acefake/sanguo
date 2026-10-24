extends RefCounted
## CampaignState.route() 的记忆：按（势力，起点，终点）记下结果，通行状态一变就整表作废。
##
## route() 原来每次都对全图地点逐一 can_cross 求排除表（约 0.3 ms），战略评估日一天要调上千次，
## 其中只有两三百个不同组合。排除表只取决于各地点的归属和势力关系，路径本身由 MapGraph 按封锁代数缓存。
##
## 失效条件（每次调用都核对，不靠写入方通知，任何一项不同就清空重来）：
## - 剧本城池表、别名表、路网地点表不是同一个对象，或城池数、路网地点数变了；
## - 任一路网地点对应的城池字典被换掉，或它的 faction 变了；
## - 势力关系表内容变了；
## - MapGraph 的路径代数变了（封锁变化或重新 setup），或封锁、关闭道路的数量变了。
## 命中时返回的是原先同一个 MapGraph 缓存对象，与不缓存时 route() 的返回值完全相同。


var _scenario_places = null
var _aliases = null
var _aliases_snapshot: Dictionary = {}
var _graph_places = null
var _graph_generation := -1
var _blocked_count := -1
var _closed_count := -1
var _relations_snapshot: Dictionary = {}
var _places_count := -1
## 每个路网地点：canonical 城池 id、当时的城池字典（没有城池为 null）、当时的归属。
var _canonical: PackedStringArray = PackedStringArray()
var _cities: Array = []
var _owners: PackedStringArray = PackedStringArray()
var _entries: Dictionary = {}


## 与 CampaignState.route() 原实现结果相同的寻路，按通行状态记忆。
func route(war, faction: String, start: String, finish: String) -> Dictionary:
	if not _valid(war): _reset(war)
	var key := faction + "|" + start + "|" + finish
	var cached = _entries.get(key)
	if cached != null: return cached
	var excluded: Array = []
	for node in war.graph.places:
		if node != start and node != finish and not war.can_cross(faction, str(node)): excluded.append(node)
	var result: Dictionary = war.graph.path(start, finish, excluded)
	_entries[key] = result
	return result


func _valid(war) -> bool:
	var store = war.store
	var places: Dictionary = store.scenario.get("places", {})
	var graph = war.graph
	if not is_same(places, _scenario_places) or places.size() != _places_count: return false
	if not is_same(store.city_aliases, _aliases) or store.city_aliases != _aliases_snapshot: return false
	if not is_same(graph.places, _graph_places) or graph.places.size() != _canonical.size(): return false
	if graph.path_generation() != _graph_generation or graph.blocked.size() != _blocked_count or graph.closed_routes.size() != _closed_count: return false
	if war.state.get("relations", {}) != _relations_snapshot: return false
	for index in _canonical.size():
		var city = _cities[index]
		if city == null:
			if places.has(_canonical[index]): return false
			continue
		if not is_same(places.get(_canonical[index]), city) or str(city.get("faction", "")) != _owners[index]: return false
	return true


func _reset(war) -> void:
	var store = war.store
	var places: Dictionary = store.scenario.get("places", {})
	_entries.clear()
	_scenario_places = places
	_places_count = places.size()
	_aliases = store.city_aliases
	_aliases_snapshot = store.city_aliases.duplicate(true)
	_graph_places = war.graph.places
	_graph_generation = war.graph.path_generation()
	_blocked_count = war.graph.blocked.size()
	_closed_count = war.graph.closed_routes.size()
	_relations_snapshot = war.state.get("relations", {}).duplicate(true)
	_canonical = PackedStringArray()
	_cities = []
	_owners = PackedStringArray()
	for node in war.graph.places:
		var id: String = store.canonical_city_id(str(node))
		var city = places.get(id) if id != "" else null
		_canonical.append(id if id != "" else str(node))
		_cities.append(city)
		_owners.append(str(city.get("faction", "")) if city != null else "")
