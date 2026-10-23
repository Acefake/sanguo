extends RefCounted
## StrategicAI.lord_of 的记忆：各势力君主只在武将资料或武将状态变化后才重新推选。
##
## FactionLifecycle.maintain 每天两次为全部 21 个势力各推选一次君主，每次都对全部武将排序并逐个
## 算特性修正后的名望、威仪（约 3.7 ms）。lord_of 只读三样东西：roster.officers、势力名、武将状态表；
## 特性修正（Process.value）只取决于武将字典本身。
##
## 失效条件（每次调用都核对，不靠写入方通知）：roster.officers 或传入的武将状态表与上次快照内容不同，
## 就丢弃全部记忆并重新快照。命中时返回的是推选当时 roster.officers 里的那个武将字典。

const Strategic = preload("res://scripts/war/campaign/strategic_ai.gd")

var _officers_snapshot: Dictionary = {}
var _states_snapshot: Dictionary = {}
var _lords: Dictionary = {}


## 与 StrategicAI.lord_of(roster, faction, officer_states) 结果相同。
func lord(roster, faction: String, officer_states: Dictionary) -> Dictionary:
	if roster.officers != _officers_snapshot or officer_states != _states_snapshot:
		_officers_snapshot = roster.officers.duplicate(true)
		_states_snapshot = officer_states.duplicate(true)
		_lords.clear()
	if not _lords.has(faction): _lords[faction] = Strategic.lord_of(roster, faction, officer_states)
	return _lords[faction]
