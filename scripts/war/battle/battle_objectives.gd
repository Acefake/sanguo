extends RefCounted

# Control uses physical presence, not orders or omniscient AI target selection.
static func update(war) -> void:
	if not war.store.battle_test: return
	var board: Dictionary = war.state.get("battlefield", {})
	if board.has("winner") or not board.has("control_point"): return
	var point: Dictionary = board["control_point"]
	var tick: int = war.state["tick"]
	if int(point.get("updated_at", -1)) == tick: return
	point["updated_at"] = tick
	var present := {}
	for army in war.Tactical.participants(war, board):
		if army["returning"] or float(army["morale"]) < 25 or float(army["organization"]) < 20 or war.Combat.strength(army) < 500: continue
		if war.Tactical.cell_distance(int(army["tactical"]["cell"]), int(point["cell"])) > int(point.get("radius", 1)): continue
		present[str(army["faction"])] = true
	point["contested"] = present.size() > 1
	if present.size() != 1:
		point["owner"] = ""
		point["progress"] = 0
		return
	var owner: String = str(present.keys()[0])
	point["progress"] = int(point["progress"]) + 1 if owner == point["owner"] else 1
	point["owner"] = owner
	if int(point["progress"]) < int(point["hold_days"]): return
	board["winner"] = owner
	board["ended_at"] = tick
	board["victory_reason"] = "%s连续控制%d日" % [point["name"], point["hold_days"]]
	war.Feedback.event(war, "据点控制", board["victory_reason"], owner)
	for army in war.active_armies(owner):
		war._report(army, "战局结果", board["victory_reason"] + "，本军赢得战场。", true)
		break

static func status_text(war) -> String:
	var board: Dictionary = war.state.get("battlefield", {})
	var point: Dictionary = board.get("control_point", {})
	if point.is_empty(): return str(board.get("objective_text", ""))
	if board.has("winner"): return str(board.get("victory_reason", "战斗已结束"))
	if point.get("contested", false): return str(point["name"]) + "  双方争夺中，控制计时中断"
	var faction: String = str(point.get("owner", ""))
	if faction == "": return "%s  尚未控制  需连续%d日" % [point["name"], point["hold_days"]]
	var name: String = str(war.store.scenario.get("factions", {}).get(faction, {}).get("name", faction))
	return "%s  %s控制 %d/%d日" % [point["name"], name, point["progress"], point["hold_days"]]
