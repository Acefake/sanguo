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

## 抬头左侧的圆形头像（部队页显示主将头像；其他页隐藏）。
const AVATAR := 52
var avatar: TextureRect
var _avatar_frame: PanelContainer
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
	# 上下内边距收紧到 16（左右仍 24），抬头与分页间距 8：把纵向空间让给内容区，概况页默认不用长滚动。
	var column := Widgets.vbox(1)
	add_child(column)
	var head := Widgets.hbox(1)
	column.add_child(head)
	# 头像放进抬头，与标题同一行：不再在内容区顶上占一大块头像区。
	_avatar_frame = PanelContainer.new()
	_avatar_frame.custom_minimum_size = Vector2(AVATAR, AVATAR)
	_avatar_frame.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_avatar_frame.clip_children = CanvasItem.CLIP_CHILDREN_AND_DRAW
	var ring := preload("res://scripts/ui/theme/ui_theme_builder.gd").box(Tokens.color("raised", -1, "glass"), "pill")
	ring.set_corner_radius_all(AVATAR / 2)
	_avatar_frame.add_theme_stylebox_override("panel", ring)
	_avatar_frame.visible = false
	head.add_child(_avatar_frame)
	avatar = TextureRect.new()
	avatar.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	avatar.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	avatar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_avatar_frame.add_child(avatar)
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


## 面板样式取自所在子树主题（地图上是 glass），只把上下内边距收紧到 16。
## 只在第一次进树时做一次（覆盖样式本身会触发主题变更通知，不能挂在 theme_changed 上）。
func _apply_padding() -> void:
	if has_theme_stylebox_override("panel"): return
	var style := get_theme_stylebox("panel", "PanelContainer").duplicate() as StyleBox
	style.content_margin_top = Tokens.space(2)
	style.content_margin_bottom = Tokens.space(2)
	add_theme_stylebox_override("panel", style)


func _notification(what: int) -> void:
	if what == NOTIFICATION_ENTER_TREE: _apply_padding()


## 抬头头像；null 隐藏。每次 present() 都会先清空，需要头像的页面在 present 之后设置。
func set_avatar(texture: Texture2D) -> void:
	avatar.texture = texture
	_avatar_frame.visible = texture != null


## 分页胶囊按钮（测试与快捷键用）；没有该页时返回 null。
func tab_button(id: String) -> Button:
	var index := _tab_ids.find(id)
	return _tabs[index] if index >= 0 else null


## 设置抬头与分页并打开抽屉。tabs 为 [[id, 文字], ...]，空数组隐藏分页行。
func present(title: String, subtitle := "", tabs: Array = [], active := "") -> void:
	title_label.text = title
	set_avatar(null)
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
