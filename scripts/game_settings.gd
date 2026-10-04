extends CanvasLayer

const CitySkin = preload("res://scripts/city_ui_skin.gd")
var window: Window
var store: Node
var endpoint: LineEdit
var model: LineEdit
var key: LineEdit
var enabled: CheckButton
var timeout: SpinBox
var notice: Label

func _ready() -> void:
	store = get_node("/root/GameState")
	window = Window.new()
	window.title = "游戏主设置 · 武将智能体"
	window.size = Vector2i(640, 720)
	window.transient = true
	window.exclusive = true
	window.visible = false
	window.close_requested.connect(window.hide)
	add_child(window)
	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.add_theme_stylebox_override("panel", CitySkin.paper(1.0, 20))
	window.add_child(panel)
	var scroll := ScrollContainer.new()
	panel.add_child(scroll)
	var rows := VBoxContainer.new()
	rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rows.add_theme_constant_override("separation", 10)
	scroll.add_child(rows)
	_label(rows, "武将智能体")
	_label(rows, "每位武将独立判断，共用下方模型服务；未启用或请求失败时由本地策略接管。")
	enabled = CheckButton.new()
	enabled.text = "启用模型自主决策"
	enabled.add_theme_color_override("font_color", CitySkin.INK)
	rows.add_child(enabled)
	endpoint = _field(rows, "接口地址（包含 /chat/completions）")
	model = _field(rows, "模型名")
	key = _field(rows, "API Key（保存到本机配置，重启自动读取）")
	key.secret = true
	_label(rows, "等待上限（秒）")
	timeout = SpinBox.new()
	timeout.min_value = 2
	timeout.max_value = 60
	rows.add_child(timeout)
	var save := Button.new()
	save.text = "保存设置"
	CitySkin.style_button(save, true)
	save.pressed.connect(_save)
	rows.add_child(save)
	notice = _label(rows, "")
	var close := Button.new()
	close.text = "返回游戏"
	CitySkin.style_button(close)
	close.pressed.connect(window.hide)
	rows.add_child(close)
	var battle := Button.new()
	battle.text = "小沛中型对战 · 全武将出阵／重置"
	CitySkin.style_button(battle)
	battle.pressed.connect(func():
		if store.busy: notice.text = "请先完成本轮推进。"
		else: store.start_battle_test()
	)
	rows.add_child(battle)
	var back := Button.new()
	back.text = "结束测试，返回原战役"
	CitySkin.style_button(back)
	back.pressed.connect(func():
		if store.busy: notice.text = "请先完成本轮推进。"
		elif store.battle_test: store.leave_battle_test()
	)
	rows.add_child(back)

func open() -> void:
	enabled.button_pressed = store.agent.enabled
	endpoint.text = store.agent.endpoint
	model.text = store.agent.model
	key.text = store.agent.api_key
	timeout.value = store.agent.timeout_seconds
	notice.text = ""
	if store.busy and not store.time_paused: store.toggle_time_pause()
	window.popup_centered()

func _save() -> void:
	if store.busy:
		notice.text = "请先完成本轮十日推进，再保存模型设置。"
		return
	notice.text = store.agent.configure({"enabled": enabled.button_pressed, "endpoint": endpoint.text, "model": model.text, "api_key": key.text, "timeout": timeout.value})

func _label(parent: Node, text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_color_override("font_color", CitySkin.INK)
	label.add_theme_font_override("font", CitySkin.font())
	parent.add_child(label)
	return label

func _field(parent: Node, caption: String) -> LineEdit:
	_label(parent, caption)
	var field := LineEdit.new()
	field.custom_minimum_size.y = 36
	parent.add_child(field)
	return field

