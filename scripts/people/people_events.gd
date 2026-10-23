class_name PeopleEventBus
extends Node
## Autoload「PeopleEvents」：人物事件总线（00-总览 §6）。
##
## 战争侧和人物模块只经这里发结构化事件：只记事实（谁、对谁、什么事、附加数据），不带评价；
## 评价由每个人自己的记忆规则在旬末产生。总线只做三件事：编号、广播 event_emitted、
## 把事件排进本旬队列等旬末 drain()。不解释事件、不写人物状态。
## 队列和编号随存档走（export_state/import_state），读档后编号不重复。

signal event_emitted(event: Dictionary)

var _seq := 0
var _pending: Array = []


## 发出一条事件，返回带编号的事件字典 {eid, kind, actor, target, data}。
func emit(kind: String, actor: String, target: String = "", data: Dictionary = {}) -> Dictionary:
	_seq += 1
	var event := {"eid": "ev_%06d" % _seq, "kind": kind, "actor": actor, "target": target, "data": data.duplicate(true)}
	_pending.append(event)
	event_emitted.emit(event)
	return event


## 取走本旬排队的全部事件（按发出顺序），队列清空。
func drain() -> Array:
	var events := _pending
	_pending = []
	return events


func export_state() -> Dictionary:
	return {"seq": _seq, "pending": _pending.duplicate(true)}


func import_state(data: Dictionary) -> void:
	_seq = int(data.get("seq", 0))
	_pending = data.get("pending", []).duplicate(true)
