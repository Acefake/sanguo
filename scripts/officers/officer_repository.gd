class_name OfficerRepository
extends RefCounted
## 人物卡的唯一入口。
##
## 当前剧本的人物卡只从这里读：第一次查询时读一次 PATH、校验一次，之后只回答查询。
## 返回的都是深拷贝，调用方改动不会写回仓库。卡面到运行时字典的换算仍在 officer_card.gd。

const PATH := "res://data/scenarios/guandu/officers.json"

static var _cards: Array = []
static var _by_id: Dictionary = {}
static var _errors: Array[String] = []
static var _loaded := false


## 全部人物卡，按文件顺序。
static func cards() -> Array:
	_ensure()
	return _cards.duplicate(true)


## 指定 id 的人物卡；没有时返回空字典。
static func card(id: String) -> Dictionary:
	_ensure()
	return _by_id.get(id, {}).duplicate(true)


## 加载时发现的问题（文件缺失、格式不对、id 缺失或重复）。
static func errors() -> Array[String]:
	_ensure()
	return _errors.duplicate()


static func _ensure() -> void:
	if _loaded: return
	_loaded = true
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(PATH)) if FileAccess.file_exists(PATH) else null
	if not parsed is Array:
		_errors.append("人物卡读取失败：%s 不存在或不是数组" % PATH)
	else:
		for entry in parsed:
			if not entry is Dictionary or str(entry.get("id", "")).is_empty() or str(entry.get("name", "")).is_empty():
				_errors.append("人物卡缺 id 或 name：%s" % JSON.stringify(entry).left(80))
				continue
			var id := str(entry["id"])
			if _by_id.has(id):
				_errors.append("人物卡 id 重复：%s" % id)
				continue
			_by_id[id] = entry
			_cards.append(entry)
	for error in _errors: push_error(error)
