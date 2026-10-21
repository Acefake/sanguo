class_name CampaignActions
extends RefCounted
## 行动执行与收束：执行已决定的行动、规划撤退路线、任务结束时兵员粮草归城。
##
## 所有函数都是静态的，第一个参数 war 是 CampaignState 实例（不标类型，避免与它互相引用）。

const Process = preload("res://scripts/officers/officer_process.gd")
const Fate = preload("res://scripts/war/campaign/officer_fate.gd")
const Combat = preload("res://scripts/war/battle/combat_system.gd")
const Corps = preload("res://scripts/war/campaign/army_corps.gd")


## 执行一个行动并产生副作用（行军路线、撤退、补粮、求援军报）。
static func _execute(war, army: Dictionary, action: Dictionary) -> void:
	if not war.supply_enabled() and action.get("type", "") == "resupply": return
	# 换了命令才有整理与展开的延迟；同一命令延续不重复扣。
	if str(action.get("type", "")) != str(army.get("action", {}).get("type", "")):
		Process.issue_order(army, {"terrain": war._terrain(str(army["location"]["node"])), "action": str(action.get("type", ""))})
	army["action"] = action.duplicate(true)
	var location: Dictionary = army["location"]
	match str(action["type"]):
		"march":
			var destination := str(action["target"])
			if destination != str(army["target"]) and not war.can_cross(str(army["faction"]), destination): army["action"] = {"type": "hold"}; return
			location["from"] = location["node"]
			location["to"] = action["target"]
			location["edge"] = action["edge"]
			location["progress"] = 0.0
		"scout": army["scouted_at"] = int(war.state["tick"])
		"withdraw":
			army["returning"] = true
			if str(army["outcome"]) == "":
				army["outcome"] = "撤退"
			war.state["missions"][army["id"]]["status"] = "returning"
			_start_return(war, army)
		"resupply":
			var city: Dictionary = war.store.city_state(str(location["node"]))
			var need: int = maxi(0, int(ceil(war.daily_food(army) * float(war.rules["carry_days"]) - float(army["grain"]))))
			var take: int = mini(need, mini(int(city.get("grain", 0)), int(ceil(war.daily_food(army) * 10))))
			city["grain"] -= take
			army["grain"] += take
			war.store.city_changed.emit(str(location["node"]))
		"request_support":
			army["last_support"] = int(war.state["tick"])
			war._report(army, "求援", "%s请求增援，目前兵力%d。" % [army["name"], Combat.strength(army)], true)


## 规划回师：掉头或走向最近的友城；无路可退时逐日散亡。
static func _start_return(war, army: Dictionary) -> void:
	if army.has("tactical"): return
	var location: Dictionary = army["location"]
	if str(location.get("edge", "")) != "":
		if not bool(location.get("reversed", false)):
			var old_from: String = str(location["from"])
			location["from"] = location["to"]
			location["node"] = location["to"]
			location["to"] = old_from
			location["progress"] = 1.0 - float(location["progress"])
			location["reversed"] = true
		return
	var best: Dictionary = {}
	var best_cost: float = INF
	var destination: String = ""
	# Equal-cost retreat cities need the same tie-break before and after JSON load.
	var friendly_ids: Array = war.store.scenario.get("places", {}).keys()
	friendly_ids.sort()
	for id in friendly_ids:
		var city: Dictionary = war.store.city_state(str(id))
		if not city.has("garrison") or str(city.get("faction", "")) != str(army["faction"]):
			continue
		var path: Dictionary = war.route(str(army["faction"]), str(location["node"]), str(id))
		if bool(path["found"]) and float(path["cost"]) < best_cost:
			best = path
			best_cost = float(path["cost"])
			destination = str(id)
	if destination == "":
		# 无可达友城时不能无限期滞留：逐日散亡、逐日衰退，逾期按溃散收束，
		# 否则 returning 永远为真，月度推进被 active_armies 非空永久拒绝。
		var since := int(army.get("return_stalled_since", war.state["tick"]))
		army["return_stalled_since"] = since
		var stalled := int(war.state["tick"]) - since
		if stalled == 0:
			war._report(army, "退路受阻", "%s没有可达的友城，暂时驻守并请求支援。" % army["name"], true)
		Combat.apply_loss(army, maxi(1, int(ceil(Combat.strength(army) * 0.05))))
		army["morale"] = maxf(0.0, float(army["morale"]) - 6.0)
		army["last_reason"] = "退路断绝，部众正在散亡（%d/%d日）" % [stalled, int(war.rules.get("return_stall_days", 10))]
		if stalled >= int(war.rules.get("return_stall_days", 10)) or Combat.strength(army) <= 0:
			_finish(war, army, "退路断绝，部众散亡")
		return
	army.erase("return_stalled_since")
	army["return_destination"] = destination
	if best["nodes"].size() == 1:
		_finish(war, army, str(army.get("outcome", "撤退")))
	else:
		location["from"] = location["node"]
		location["to"] = best["nodes"][1]
		location["edge"] = best["edges"][0]
		location["progress"] = 0.0
		location["reversed"] = false


## 结束任务：兵员粮草归城或计入被俘，更新任务与武将状态，发结束军报。
static func _finish(war, army: Dictionary, outcome: String) -> void:
	if str(army["status"]) == "ended":
		return
	var node: String = str(army["location"]["node"])
	var city: Dictionary = war.store.city_state(node)
	var strength: int = Combat.strength(army)
	if outcome == "失去指挥溃散":
		army["grain"] = 0.0
	elif city.has("garrison") and str(city.get("faction", "")) == str(army["faction"]):
		war._sync_inventory(city)
		for type in Combat.TYPES:
			city["units"][type] += int(army["units"][type])
		city["garrison"] += strength
		city["wounded"] = int(city.get("wounded", 0)) + int(army["wounded"])
		var wounded_units: Dictionary = army.get("wounded_units", {"infantry": int(army["wounded"]), "archers": 0, "cavalry": 0})
		for type in Combat.TYPES: city["wounded_units"][type] += int(wounded_units.get(type, 0))
		if city.has("grain"): city["grain"] += int(floor(float(army["grain"])))
		army["returned_strength"] = strength
		army["returned_wounded"] = army["wounded"]
		army["returned_grain"] = int(floor(float(army["grain"])))
		army["deposited"] += strength
		army["units"] = {"infantry": 0, "archers": 0, "cavalry": 0}
		army["grain"] = 0.0
		war.store.city_changed.emit(node)
	elif outcome == "军队覆没" and int(army["wounded"]) > 0:
		army["captured"] += int(army["wounded"])
		army["wounded"] = 0
	elif strength > 0:
		# 在非本方节点收束（家乡易手、退路断绝、守援/期限到期）：存活兵员既不能
		# 进城也不该凭空消失，按被俘入账，否则 initial ≠ dead+wounded+captured+现存。
		Combat.apply_loss(army, strength, true)
		army["surrendered_at"] = node
		war._report(army, "部众被收容", "%s在%s收束，%d人解甲被俘。" % [army["name"], war.graph.name_of(node), strength], true)
	army.erase("return_stalled_since")
	army["status"] = "ended"
	army["outcome"] = outcome
	war.state["missions"][army["id"]]["status"] = "ended"
	war.state["missions"][army["id"]]["result"] = outcome
	war.state["officer_states"][army["officer_id"]] = {"status": "available" if outcome != "军队覆没" and not army.get("duel_wounded", false) else "recovering", "city": node, "available_after": int(war.state["tick"]) + (int(war.rules["duel"]["recover_days"]) if army.get("duel_wounded", false) else 10)}
	if army.get("duel_wounded", false): war.state["officer_states"][army["officer_id"]]["duel_wounded"] = true
	army.erase("pending_request")
	army.erase("approved_action")
	army["trust"] = float(army.get("trust", 0.0)) * 0.5
	army["resentment"] = float(army.get("resentment", 0.0)) * 0.5
	Corps.on_finish(war, army)
	Fate.restore(war)
	war._report(army, "任务结束", "%s：%s。归队%d，伤兵%d，阵亡%d，被俘%d，留驻%d，溃散%d。" % [army["name"], outcome, int(army.get("returned_strength", 0)), int(army["wounded"]), int(army["dead"]), int(army["captured"]), int(army["deposited"]) - int(army.get("returned_strength", 0)), int(army.get("dispersed", 0))], true)
