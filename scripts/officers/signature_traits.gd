class_name SignatureTraits
extends RefCounted
## 专属特性的执行：武圣首次威压、小霸王连胜冲击。
##
## 参数都来自 TraitRegistry 里该特性的 mechanism，这里不出现人物名或特性名。

const Traits = preload("res://scripts/officers/trait_registry.gd")
const Process = preload("res://scripts/officers/officer_process.gd")


## 连胜后首次主动接敌：标记已用，并给对方挂一次士气冲击，由 battle_morale 结算。
static func opening(attacker: Dictionary, defender: Dictionary) -> bool:
	var chain := Traits.mechanism(attacker, "victory_chain")
	if chain.is_empty() or not bool(attacker.get("victory_chain", false)) or bool(attacker.get("opening_used", false)): return false
	if attacker.get("action", {}).get("type", "") not in chain["actions"]: return false
	attacker["opening_used"] = true
	defender["incoming_shock"] = float(chain["shock"])
	return true


## 首次与高名望敌将正面交锋：敌直属部队士气下降，同一目标只一次，远射不触发。
static func first_contact(attacker: Dictionary, defender: Dictionary, melee: bool = true) -> bool:
	var awe := Traits.mechanism(attacker, "first_contact_awe")
	if awe.is_empty() or not melee or attacker.get("action", {}).get("type", "") not in awe["actions"]: return false
	if Process.value(defender, "名望") < float(awe["min_enemy_renown"]): return false
	var targets: Array = attacker.get("battle_contacts", [])
	var target := str(defender.get("officer_id", defender.get("id", "")))
	if target.is_empty() or target in targets: return false
	# 列表有界，长战役里存档不会无限增长。
	if targets.size() >= int(awe["contact_memory"]): targets.pop_front()
	targets.append(target)
	attacker["battle_contacts"] = targets
	defender["morale"] = maxf(0.0, float(defender.get("morale", 100)) - float(awe["morale"]))
	return true
