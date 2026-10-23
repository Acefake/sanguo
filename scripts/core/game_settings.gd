extends CanvasLayer

const CitySkin = preload("res://scripts/ui/city_ui_skin.gd")
var window: Window
var store: Node
var endpoint: LineEdit
var model: LineEdit
var key: LineEdit
var enabled: CheckButton
var model_scope: OptionButton
var timeout: SpinBox
var parallel: SpinBox
var budget: SpinBox
var reasoning: CheckButton
var notice: Label

func _ready() -> void:
	store = get_node("/root/GameState")
	window = Window.new()
	CitySkin.theme_window(window)
	window.title = "游戏主设置  武将智能体"
	window.size = Vector2i(640, 600)
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
	_label(rows, "主帅分配职责，每支小部队依据自己的武将、敌情与授权自主判断目标、站位和配合；模型未配置时本地策略完整作战。")
	enabled = CheckButton.new()
	enabled.text = "启用模型自主决策"
	enabled.add_theme_color_override("font_color", CitySkin.INK)
	rows.add_child(enabled)
	_label(rows,"模型参与范围")
	model_scope = OptionButton.new()
	for item in [["本地决策","local"],["仅主帅使用模型","commanders"],["所有武将使用模型","all"]]:
		model_scope.add_item(item[0])
		model_scope.set_item_metadata(model_scope.item_count-1,item[1])
	rows.add_child(model_scope)
	endpoint = _field(rows, "接口地址（/chat/completions 或 Ollama /api/chat）")
	model = _field(rows, "模型名")
	key = _field(rows, "API Key（保存到本机配置，重启自动读取）")
	key.secret = true
	_label(rows, "等待上限（秒）")
	timeout = SpinBox.new()
	timeout.min_value = 2
	timeout.max_value = 60
	rows.add_child(timeout)
	reasoning = CheckButton.new()
	reasoning.text = "关闭模型思考（Ollama／OpenRouter）"
	reasoning.add_theme_color_override("font_color", CitySkin.INK)
	rows.add_child(reasoning)
	_label(rows, "武将保留独立性格、观察和记忆，共享模型权重。主帅签发军令，主将临机执行，参军独立建议。Ollama无需API Key。")
	var local := Button.new()
	local.text = "使用本机小模型  Ollama Qwen3 1.7B"
	CitySkin.style_button(local)
	local.pressed.connect(func():
		enabled.button_pressed = true
		endpoint.text = "http://127.0.0.1:11434/api/chat"
		model.text = "qwen3:1.7b"
		key.text = ""
		parallel.value = 1
		budget.value = 15
		timeout.value = 15
		reasoning.button_pressed = true
		notice.text = "预设已填写，检测成功后保存。请先启动Ollama并运行 ollama pull qwen3:1.7b。"
	)
	rows.add_child(local)
	var probe := Button.new()
	probe.text = "检测本地服务与模型"
	CitySkin.style_button(probe)
	probe.pressed.connect(_probe_local)
	rows.add_child(probe)
	_label(rows, "同时请求将领数（1–6）")
	parallel = SpinBox.new()
	parallel.min_value = 1
	parallel.max_value = 6
	rows.add_child(parallel)
	_label(rows, "后台请求时间预算（秒；战斗持续使用本地判断）")
	budget = SpinBox.new()
	budget.min_value = 2
	budget.max_value = 30
	rows.add_child(budget)
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
	battle.text = "选择验证战场  攻城 / 平原 / 山地 / 林地"
	CitySkin.style_button(battle)
	battle.pressed.connect(func():
		if store.busy: notice.text = "请先完成本轮推进。"
		else: window.hide(); store.open_battle_scenarios()
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
	for i in range(model_scope.item_count):
		if model_scope.get_item_metadata(i) == store.agent.model_mode: model_scope.select(i)
	endpoint.text = store.agent.endpoint
	model.text = store.agent.model
	key.text = store.agent.api_key
	timeout.value = store.agent.timeout_seconds
	parallel.value = store.agent.concurrency
	budget.value = store.agent.decision_budget_seconds
	reasoning.button_pressed = store.agent.disable_reasoning
	notice.text = ""
	if store.busy and not store.time_paused: store.toggle_time_pause()
	window.popup_centered()

func _save() -> void:
	if store.busy:
		notice.text = "请先完成本轮十日推进，再保存模型设置。"
		return
	notice.text = store.agent.configure({"enabled": enabled.button_pressed, "model_mode": model_scope.get_item_metadata(model_scope.selected), "endpoint": endpoint.text, "model": model.text, "api_key": key.text, "timeout": timeout.value, "concurrency": parallel.value, "decision_budget": budget.value, "disable_reasoning": reasoning.button_pressed})

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


func _probe_local() -> void:
	if not endpoint.text.begins_with("http://127.0.0.1:11434/") and not endpoint.text.begins_with("http://localhost:11434/"):
		notice.text = "检测按钮用于本机11434端口的Ollama服务。"
		return
	var request := HTTPRequest.new()
	request.timeout = 3
	request.body_size_limit = 1048576
	add_child(request)
	notice.text = "正在检测本地模型服务……"
	var error := request.request(endpoint.text.get_slice("/api/", 0) + "/api/tags")
	if error != OK:
		notice.text = "无法发起检测，请先启动Ollama。"
		request.queue_free()
		return
	var response: Array = await request.request_completed
	request.queue_free()
	if int(response[0]) != HTTPRequest.RESULT_SUCCESS or int(response[1]) != 200:
		notice.text = "本地服务未就绪，请先启动Ollama。"
		return
	var data: Variant = JSON.parse_string(response[3].get_string_from_utf8())
	if not data is Dictionary:
		notice.text = "本地服务响应无效。"
		return
	for available in data.get("models", []):
		if available.get("name", "") == model.text or available.get("model", "") == model.text:
			notice.text = "服务正常，模型已安装；点击保存设置即可使用。"
			return
	notice.text = "服务正常，但未安装所选模型。运行 ollama pull " + model.text
