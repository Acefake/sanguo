class_name PeopleEventBus
extends Node
## Autoload「PeopleEvents」：人物事件总线（00-总览 §6）。
##
## 战争侧和人物模块只经这里发结构化事件：只记事实（谁、对谁、什么事、附加数据），不带评价；
## 评价由每个人自己的记忆规则在旬末产生。总线只做三件事：编号、广播 event_emitted、
## 把事件排进本旬队列等旬末 drain()。不解释事件、不写人物状态。
## 只接受 memory_rules.event_catalog 里可发的 kind；memory_only（由别的事件派生的记忆）和目录外的 kind 报错并丢弃。
## 队列和编号随存档走（export_state/import_state），读档后编号不重复。

signal event_emitted(event: Dictionary)

const Memory = preload("res://scripts/people/memory.gd")
const RULES_PATH := "res://data/people/memory_rules.json"

static var _catalog: Array = []

var _seq := 0
var _pending: Array = []


## 发出一条事件，返回带编号的事件字典 {eid, kind, actor, target, data}；kind 不在事件目录时返回空字典。
func emit(kind: String, actor: String, target: String = "", data: Dictionary = {}) -> Dictionary:
	if kind not in catalog():
		push_error("人物事件 %s 不在 memory_rules.event_catalog 的可发事件里（memory_only 不能直接发）" % kind)
		return {}
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


## Autoload「PeopleEvents」节点。与 PersonStore.autoload() 同理：经测试 preload 链编译的脚本不写全局名，
## 也不能从不在场景树里的节点用 /root 路径取。
static func autoload() -> PeopleEventBus:
	return (Engine.get_main_loop() as SceneTree).root.get_node("PeopleEvents")


## 可发的事件 kind（读一次 memory_rules.json 后缓存）。
static func catalog() -> Array:
	if _catalog.is_empty():
		_catalog = Memory.catalog_kinds(JSON.parse_string(FileAccess.get_file_as_string(RULES_PATH)))
	return _catalog


func export_state() -> Dictionary:
	return {"seq": _seq, "pending": _pending.duplicate(true)}


func import_state(data: Dictionary) -> void:
	_seq = int(data.get("seq", 0))
	_pending = data.get("pending", []).duplicate(true)
