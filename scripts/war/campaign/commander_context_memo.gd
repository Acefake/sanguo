extends RefCounted
## 一个军团在一次 plan_background 里的主帅上下文复用。
##
## plan_background 对每个军团每天要构造 3–5 次 commander_context（取模型答案时复查、本地兜底、
## 复查旧提案、准备新请求），而这几次之间只要没有下达军令，军团和战场状态都没有变，构造结果逐字节相同。
## 本对象只活在 plan_background 处理一个军团的那一段里，换军团、换日都是新对象。
##
## 失效条件（显式、保守）：
## - 每次下达军令（record_background_order 调 issue）之后调用 invalidate()，下一次一律重建；
## - 只认构造它的那个军团，军团 id 不同就重建；
## - 返回的是同一个字典：调用方只能改顶层的标记键（background、decision_trigger），这两个键每次都会重新赋值。

var _corps_id := ""
var _context: Dictionary = {}


## 已缓存且属于该军团时返回缓存的上下文，否则返回空字典（由调用方重建后 store）。
func lookup(corps_id: String) -> Dictionary:
	return _context if _corps_id == corps_id else {}


## 记下刚构造好的上下文。
func store(corps_id: String, context: Dictionary) -> void:
	_corps_id = corps_id
	_context = context


## 军团状态可能已经改变（下达了军令）：丢弃缓存。
func invalidate() -> void:
	_corps_id = ""
	_context = {}
