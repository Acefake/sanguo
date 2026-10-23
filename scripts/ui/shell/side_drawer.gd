extends PanelContainer
## 地图右侧唯一的抽屉：标题、副标题、分页胶囊、内容区。打开新对象时替换旧内容，不叠第二块面板。
##
## 内容区是一个页面栈：host(page) 把页面放进来（已在栈里就复用）并只显示它；
## 常驻页面（军报簿、部队详情容器）因此只建一次。开合用 Tween 做 ≤150ms 的位移与淡入，
## 不在推进（step）里做布局计算。直接调用 show()/hide() 仍然有效（立即开合，无动画）。

signal tab_selected(id: String)
signal closed

const Tokens = preload("res://scripts/ui/theme/ui_tokens.gd")
const Widgets = preload("res://scripts/ui/theme/ui_widgets.gd")
## 内容区宽 = WIDTH − 面板两侧内边距（各 24）；部队名牌固定 334 宽，所以至少 384。
const WIDTH := 384
const SLIDE := 24.0

var title_label: Label
var subtitle_label: Label
var pages: Control
var _tab_row: HBoxContainer
var _tab_group := ButtonGroup.new()
var _tabs: Array[Button] = []
var _tab_ids: Array[String] = []
var _tween: Tween


func _init() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_RIGHT_WIDE)
	offset_left = -WIDTH - Tokens.space(2)
	offset_right = -Tokens.space(2)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var column := Widgets.vbox(2)
	add_child(column)
	var head := Widgets.hbox(1)
	column.add_child(head)
	var titles := Widgets.vbox(0)
	titles.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(titles)
	title_label = Widgets.title("")
	title_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	titles.add_child(title_label)
	subtitle_label = Widgets.label("", "MutedLabel")
	subtitle_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	titles.add_child(subtitle_label)
	var close_button := Widgets.text_button("关闭", close)
	close_button.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	head.add_child(close_button)
	_tab_row = Widgets.hbox(1)
	column.add_child(_tab_row)
	pages = Control.new()
	pages.size_flags_vertical = Control.SIZE_EXPAND_FILL
	pages.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(pages)
	visible = false


## 设置抬头与分页并打开抽屉。tabs 为 [[id, 文字], ...]，空数组隐藏分页行。
func present(title: String, subtitle := "", tabs: Array = [], active := "") -> void:
	title_label.text = title
	subtitle_label.text = subtitle
	subtitle_label.visible = not subtitle.is_empty()
	_set_tabs(tabs, active)
	if not visible: _slide_in()


## 把页面放进内容区（复用已有的），只显示它。页面铺满内容区。
func host(page: Control) -> void:
	if page.get_parent() != pages:
		if page.get_parent() != null: page.get_parent().remove_child(page)
		page.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		pages.add_child(page)
	for child in pages.get_children():
		if child is CanvasItem: child.visible = child == page


func close() -> void:
	if not visible: return
	_kill_tween()
	_tween = create_tween().set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	_tween.tween_property(self, "modulate:a", 0.0, Tokens.motion("drawer_seconds"))
	_tween.tween_callback(func() -> void:
		hide()
		modulate.a = 1.0
		closed.emit())


func _slide_in() -> void:
	_kill_tween()
	show()
	modulate.a = 0.0
	var settle := position.x
	position.x = settle + SLIDE
	_tween = create_tween().set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT).set_parallel()
	_tween.tween_property(self, "modulate:a", 1.0, Tokens.motion("drawer_seconds"))
	_tween.tween_property(self, "position:x", settle, Tokens.motion("drawer_seconds"))


func _kill_tween() -> void:
	if _tween != null and _tween.is_valid(): _tween.kill()
	modulate.a = 1.0


## 分页胶囊按需补建、多余的隐藏，重复打开不新建节点。
func _set_tabs(tabs: Array, active: String) -> void:
	_tab_row.visible = not tabs.is_empty()
	_tab_ids.clear()
	while _tabs.size() < tabs.size():
		var index := _tabs.size()
		var pill := Widgets.pill("", _tab_group, func() -> void: tab_selected.emit(_tab_ids[index]))
		_tab_row.add_child(pill)
		_tabs.append(pill)
	for i in _tabs.size():
		var shown := i < tabs.size()
		_tabs[i].visible = shown
		if not shown: continue
		_tab_ids.append(str(tabs[i][0]))
		_tabs[i].text = str(tabs[i][1])
		_tabs[i].set_pressed_no_signal(str(tabs[i][0]) == active)
