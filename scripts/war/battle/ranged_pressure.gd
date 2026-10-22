class_name RangedPressure
extends RefCounted
## 远程压制：受到仍可见的远程打击后，部队的即时应对。

const Tactical = preload("res://scripts/war/battle/tactical_battlefield.gd")
const Combat = preload("res://scripts/war/battle/combat_system.gd")

# React only to a recent hit whose source is still observed. This changes the
# immediate action, never the commander's assignment or the player's permissions.
static func attacker(war, unit: Dictionary) -> Dictionary:
	if not unit.has("tactical") or unit["returning"] or unit["status"] == "ended": return {}
	if int(war.state["tick"]) - int(unit.get("last_enemy_tick", -100)) > 2: return {}
	var id := str(unit.get("last_enemy_id", ""))
	var intel: Dictionary = unit["intel"]["enemies"].get(id, {})
	if int(intel.get("observed_at", -100)) != int(war.state["tick"]): return {}
	var enemy: Dictionary = war.state["armies"].get(id, {})
	if enemy.is_empty() or enemy["status"] == "ended" or not enemy.has("tactical") or not war.hostile(str(unit["faction"]), str(enemy["faction"])): return {}
	if Tactical.distance(unit, enemy) != 2 or Tactical.attack_range(enemy) != 2: return {}
	return enemy

static func respond(war, corps: Dictionary) -> void:
	var root: Dictionary = war.state["armies"].get(corps["root_id"], {})
	if root.is_empty() or root.get("corps_task", {}).get("type", "") != "command" or root.get("objective_complete", false): return
	if corps.get("autonomous_deployment", false) and not corps.get("deployed", false): return
	var enemy := attacker(war, root)
	if enemy.is_empty(): return
	var orders: Dictionary = war.orders_for(root)
	var estimate := int(root["intel"]["enemies"][enemy["id"]].get("strength_estimate", 0))
	if orders["engage"] and Combat.strength(root) >= estimate * 0.75 and float(root["morale"]) >= 40 and float(root["organization"]) >= 35:
		root["action"] = {"type": "engage", "enemy": enemy["id"]}
		root["last_reason"] = "中军受射，逼近弓兵反击"
	elif orders["retreat"]:
		root["action"] = {"type": "evade", "enemy": enemy["id"]}
		root["last_reason"] = "中军受射，避开箭阵并呼叫友军压制"
	# Redirect one nearby combat detachment; reserves and explicit tasks stay intact.
	if not orders["engage"]: return
	var escort: Dictionary = {}
	for id in corps["units"]:
		var unit: Dictionary = war.state["armies"][id]
		if unit["status"] == "ended" or unit["returning"] or not unit.has("tactical") or not war.orders_for(unit)["engage"]: continue
		if unit.get("corps_task", {}).get("type", "") not in ["main_attack", "flank", "support"] or unit.get("objective_complete", false): continue
		if Tactical.distance(root, unit) > 3 or Tactical.contact_state(war, unit)["adjacent_enemies"] > 0: continue
		if int(unit["intel"]["enemies"].get(enemy["id"], {}).get("observed_at", -100)) != int(war.state["tick"]): continue
		if escort.is_empty() or Tactical.distance(unit, enemy) < Tactical.distance(escort, enemy): escort = unit
	if not escort.is_empty():
		escort["action"] = {"type": "engage", "enemy": enemy["id"]}
		escort["tactical"]["attack_target"] = enemy["id"]
		escort["tactical"]["target_until"] = int(war.state["tick"]) + 2
		escort["last_reason"] = "压制射击中军的敌军弓兵"
