extends RefCounted
## 界面设计令牌的唯一读取口：颜色、字号、间距、圆角、控件尺寸、动效时长都来自 data/ui/theme.json。
##
## 代码里不写颜色或字号常量，一律经这里取值。JSON 在第一次访问时读入并缓存，之后是字典查表。
## 未知的令牌名是程序错误：直接 assert，而不是悄悄退回某个默认色。

const PATH := "res://data/ui/theme.json"

static var _data: Dictionary
static var _colors: Dictionary
static var _title_font: SystemFont
static var _body_font: SystemFont


static func _table(group: String) -> Dictionary:
	if _data.is_empty():
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(PATH))
		assert(parsed is Dictionary, "无法读取界面令牌：" + PATH)
		_data = parsed
	assert(_data.has(group), "theme.json 缺少分组：" + group)
	return _data[group]


static func _value(group: String, name: String) -> Variant:
	var table := _table(group)
	assert(table.has(name), "theme.json 缺少令牌：%s.%s" % [group, name])
	return table[name]


## 颜色令牌，如 "text"、"accent"。可选 alpha 覆盖令牌自带的透明度。
static func color(name: String, alpha := -1.0) -> Color:
	if not _colors.has(name):
		_colors[name] = Color.html(str(_value("color", name)))
	var result: Color = _colors[name]
	if alpha >= 0.0:
		result.a = alpha
	return result


## 透明度令牌（0–1），如 "panel"、"hover"。
static func alpha(name: String) -> float:
	return float(_value("alpha", name))


## 字号令牌（px），三档：title/display 标题、body 正文、note/caption 注释。
static func font_size(name: String) -> int:
	return int(_value("font_size", name))


## 间距：8 的倍数。space(2) == 16。
static func space(steps := 1) -> int:
	return int(_value("space", "unit")) * steps


## 圆角令牌（px），如 "panel"、"pill"。
static func radius(name: String) -> int:
	return int(_value("radius", name))


## 控件尺寸令牌（px），如 "height"、"border"。
static func control(name: String) -> int:
	return int(_value("control", name))


## 动效时长令牌（秒）。
static func motion(name: String) -> float:
	return float(_value("motion", name))


## 标题字体（楷体一族）。共享实例，字形缓存跨界面复用。
static func title_font() -> SystemFont:
	if _title_font == null:
		_title_font = _system_font("title")
	return _title_font


## 正文与小字字体（无衬线），楷体在 15px 以下笔画糊成一团。
static func body_font() -> SystemFont:
	if _body_font == null:
		_body_font = _system_font("body")
	return _body_font


static func _system_font(name: String) -> SystemFont:
	var font := SystemFont.new()
	font.font_names = PackedStringArray(_value("font", name))
	return font
