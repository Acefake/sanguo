extends CanvasLayer
## 游戏主设置：左分类、右内容，一页一组。
##
## 「人物智能」页：档位卡片对应 ai_runtime.json 的 presets（纯规则 / 本机轻量 / 本机标准 / 云端），
## 下面一行连接状态与开关；接口、模型名、API Key、等待上限、并发收进「高级」。
## API Key 只显示来源（环境变量 / 设置 / 未配置），输入框永远留空，不回显也不显示掩码；
## 留空保存即保持原值。
## 界面只建一次，open() 只回填数值。

const Tokens = preload("res://scripts/ui/theme/ui_tokens.gd")
const Widgets = preload("res://scripts/ui/theme/ui_widgets.gd")
## 运行档位的预设；在 feat/ai-model-queue 合入前本分支没有这个文件，届时只有「纯规则」可选。
const RUNTIME_PATH := "res://data/people/ai_runtime.json"
const TIERS := [
	{"id": "rules_only", "title": "纯规则", "note": "最快，不调用模型"},
	{"id": "local_light", "title": "本机轻量", "note": ""},
	{"id": "local_standard", "title": "本机标准", "note": ""},
	{"id": "cloud", "title": "云端", "note": "自填接口与模型"},
]
const SCOPES := [["本地决策", "local"], ["仅主帅", "commanders"], ["所有武将", "all"]]
const PANEL_SIZE := Vector2(880, 600)

var store: Node
## 设置浮层的根。GameState 用 window.hide() 关闭它。
var window: Control
var endpoint: LineEdit
var model: LineEdit
## 新 API Key 输入框：secret，打开时清空。
var key: LineEdit
var enabled: CheckButton
var timeout: SpinBox
var parallel: SpinBox
var budget: SpinBox
var reasoning: CheckButton
var notice: Label

var _presets: Dictionary = {}
var _key_env: PackedStringArray = []
var _pages: Dictionary = {}
var _nav: Dictionary = {}
var _nav_group := ButtonGroup.new()
var _tier_group := ButtonGroup.new()
var _tier_cards: Dictionary = {}
var _status_dot: ColorRect
var _status: Label
var _key_source: Label
var _clear_key := false
var _advanced: VBoxContainer
var _advanced_button: Button
var _scope_group := ButtonGroup.new()
var _scope_pills: Dictionary = {}
var _return_button: Button


func _ready() -> void:
	layer = 50
	store = get_node("/root/GameState")
	_read_runtime()
	window = Control.new()
	window.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	window.visible = false
	Widgets.adopt_theme(window)
	add_child(window)
	window.add_child(Widgets.shade())
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	window.add_child(center)
	var panel := Widgets.panel()
	panel.custom_minimum_size = PANEL_SIZE
	var flush := preload("res://scripts/ui/theme/ui_theme_builder.gd").panel_box(0)
	flush.bg_color.a = 1.0
	panel.add_theme_stylebox_override("panel", flush)
	center.add_child(panel)
	var column := Widgets.vbox(0)
	panel.add_child(column)
	column.add_child(_header())
	column.add_child(Widgets.rule())
	var body := Widgets.hbox(0)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(body)
	body.add_child(_navigation())
	body.add_child(VSeparator.new())
	var pages := MarginContainer.new()
	pages.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for side in ["left", "right", "top", "bottom"]: pages.add_theme_constant_override("margin_" + side, Tokens.space(4))
	body.add_child(pages)
	_pages["game"] = _game_page()
	_pages["agent"] = _agent_page()
	for id in _pages: pages.add_child(_pages[id])
	column.add_child(Widgets.rule())
	column.add_child(_footer())
	_show_page("agent")


func _header() -> Control:
	var bar := MarginContainer.new()
	for side in ["left", "right"]: bar.add_theme_constant_override("margin_" + side, Tokens.space(4))
	for side in ["top", "bottom"]: bar.add_theme_constant_override("margin_" + side, Tokens.space(2))
	var row := Widgets.hbox(2)
	bar.add_child(row)
	var heading := Widgets.title("设置")
	heading.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(heading)
	row.add_child(Widgets.text_button("关闭", window.hide))
	return bar


func _navigation() -> Control:
	var margin := MarginContainer.new()
	margin.custom_minimum_size.x = 188
	for side in ["left", "right", "top", "bottom"]: margin.add_theme_constant_override("margin_" + side, Tokens.space(2))
	var column := Widgets.vbox(0)
	margin.add_child(column)
	for entry in [["game", "游戏"], ["agent", "人物智能"]]:
		var id: String = entry[0]
		var item := Widgets.nav(entry[1], _nav_group, func() -> void: _show_page(id))
		column.add_child(item)
		_nav[id] = item
	return margin


func _footer() -> Control:
	var bar := MarginContainer.new()
	for side in ["left", "right"]: bar.add_theme_constant_override("margin_" + side, Tokens.space(4))
	for side in ["top", "bottom"]: bar.add_theme_constant_override("margin_" + side, Tokens.space(2))
	var row := Widgets.hbox(2)
	bar.add_child(row)
	notice = Widgets.muted("", true)
	notice.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(notice)
	row.add_child(Widgets.secondary("还原", _fill))
	var save := Widgets.primary("保存", _save)
	save.custom_minimum_size.x = 112
	row.add_child(save)
	return bar


func _page(heading: String, description: String) -> VBoxContainer:
	var page := Widgets.vbox(2)
	page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	page.add_child(Widgets.title(heading))
	if not description.is_empty(): page.add_child(Widgets.muted(description, true))
	return page


func _game_page() -> Control:
	var page := _page("游戏", "")
	page.add_child(Widgets.label("独立战场", "DimLabel"))
	var row := Widgets.hbox(2)
	page.add_child(row)
	row.add_child(Widgets.secondary("选择验证战场", func() -> void:
		if store.busy: notice.text = "请先完成本轮推进。"
		else:
			window.hide()
			store.open_battle_scenarios()))
	_return_button = Widgets.secondary("结束测试，返回原战役", func() -> void:
		if store.busy: notice.text = "请先完成本轮推进。"
		elif store.battle_test: store.leave_battle_test())
	row.add_child(_return_button)
	return page


func _agent_page() -> Control:
	var page := _page("人物智能", "武将用模型做取舍与发言；拿不到结果时按本地策略执行，不会卡住时间。")
	var area := Widgets.scroll(page)
	page.add_child(Widgets.label("运行档位", "DimLabel"))
	var tiers := Widgets.hbox(1)
	page.add_child(tiers)
	for tier in _tier_list(): tiers.add_child(_tier_card(tier))
	var status_row := Widgets.hbox(1)
	page.add_child(status_row)
	_status_dot = ColorRect.new()
	_status_dot.custom_minimum_size = Vector2(8, 8)
	_status_dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	status_row.add_child(_status_dot)
	_status = Widgets.muted("")
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	status_row.add_child(_status)
	status_row.add_child(Widgets.text_button("检测本机服务", _probe_local))
	page.add_child(Widgets.rule())
	enabled = Widgets.toggle_row("让武将用模型决策")
	page.add_child(enabled)
	reasoning = Widgets.toggle_row("关闭模型思考（更快）")
	page.add_child(reasoning)
	var scope_row := Widgets.hbox(1)
	page.add_child(scope_row)
	var scope_caption := Widgets.label("模型参与范围")
	scope_caption.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scope_row.add_child(scope_caption)
	for scope in SCOPES:
		var pill := Widgets.pill(scope[0], _scope_group)
		scope_row.add_child(pill)
		_scope_pills[scope[1]] = pill
	page.add_child(Widgets.rule())
	_advanced_button = Widgets.text_button("高级  ›    接口地址、模型名、API Key、等待上限、并发", _toggle_advanced)
	_advanced_button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	page.add_child(_advanced_button)
	_advanced = Widgets.vbox(1)
	_advanced.visible = false
	page.add_child(_advanced)
	endpoint = _field("接口地址", "/chat/completions 或 Ollama /api/chat")
	model = _field("模型名", "")
	_key_source = Widgets.muted("")
	_advanced.add_child(_field_row("API Key", _key_source))
	key = LineEdit.new()
	key.secret = true
	key.placeholder_text = "粘贴新的 Key；留空保持不变"
	key.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var key_row := Widgets.hbox(1)
	key_row.add_child(key)
	key_row.add_child(Widgets.text_button("清除已保存的 Key", func() -> void:
		_clear_key = true
		key.text = ""
		_key_source.text = "保存后清除"))
	_advanced.add_child(key_row)
	timeout = _spin("等待上限（秒）", 2, 60)
	parallel = _spin("同时请求将领数", 1, 6)
	budget = _spin("后台请求时间预算（秒）", 2, 30)
	enabled.toggled.connect(func(_on: bool) -> void: _sync_tier())
	endpoint.text_changed.connect(func(_text: String) -> void: _sync_tier())
	model.text_changed.connect(func(_text: String) -> void: _sync_tier())
	return area


func _tier_card(tier: Dictionary) -> Button:
	var id: String = tier["id"]
	var card := Widgets.card_button(_tier_group, func() -> void: _apply_tier(id))
	card.custom_minimum_size = Vector2(0, 64)
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var text := Widgets.vbox(0)
	text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	text.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	text.offset_left = Tokens.space(2)
	text.offset_top = Tokens.space(1) + 2
	text.offset_right = -Tokens.space(1)
	card.add_child(text)
	text.add_child(Widgets.label(tier["title"]))
	var preset := _preset(id)
	var note: String = tier["note"] if not str(tier["note"]).is_empty() else str(preset.get("model", ""))
	var available := id == "rules_only" or _presets.has(id)
	if not available:
		note = "需要 ai_runtime 预设"
		card.tooltip_text = "本分支缺少 %s，合入 feat/ai-model-queue 后可选。" % RUNTIME_PATH
	var caption := Widgets.label(note, "DimLabel")
	caption.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	text.add_child(caption)
	card.disabled = not available
	_tier_cards[id] = card
	return card


func _field(caption: String, placeholder: String) -> LineEdit:
	var field := LineEdit.new()
	field.placeholder_text = placeholder
	field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_advanced.add_child(_field_row(caption, field))
	return field


func _spin(caption: String, low: int, high: int) -> SpinBox:
	var spin := SpinBox.new()
	spin.min_value = low
	spin.max_value = high
	spin.custom_minimum_size.x = 120
	_advanced.add_child(_field_row(caption, spin))
	return spin


func _field_row(caption: String, control: Control) -> Control:
	var row := Widgets.hbox(2)
	var name := Widgets.label(caption)
	name.custom_minimum_size.x = 168
	row.add_child(name)
	row.add_child(control)
	return row


func _read_runtime() -> void:
	if not FileAccess.file_exists(RUNTIME_PATH): return
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(RUNTIME_PATH))
	if not data is Dictionary: return
	_presets = data.get("presets", {})
	for name in data.get("api_key_env", []): _key_env.append(str(name))


## 档位卡片：四个已知档位按固定顺序，ai_runtime presets 里另有的档位接在后面（标题用其 id）。
## 合入 feat/ai-model-queue 后四档都有预设、全部可选；文件缺失时只有「纯规则」可选。
func _tier_list() -> Array:
	var tiers: Array = TIERS.duplicate()
	var known := TIERS.map(func(tier: Dictionary) -> String: return tier["id"])
	for id in _presets:
		if not known.has(str(id)): tiers.append({"id": str(id), "title": str(id), "note": ""})
	return tiers


## 预设的「选择」通道：{endpoint, model}；纯规则为空。
func _preset(id: String) -> Dictionary:
	return _presets.get(id, {}).get("select", {})


func _apply_tier(id: String) -> void:
	if id == "rules_only":
		enabled.button_pressed = false
		return
	var preset := _preset(id)
	enabled.button_pressed = true
	endpoint.text = str(preset.get("endpoint", ""))
	model.text = str(preset.get("model", ""))
	if id == "cloud" and not _advanced.visible: _toggle_advanced()


## 当前配置对应哪张档位卡：未启用为纯规则；接口与模型对上某个预设即该档；其余算云端（自定义）。
func _current_tier() -> String:
	if not enabled.button_pressed: return "rules_only"
	for id in ["local_light", "local_standard"]:
		var preset := _preset(id)
		if not preset.is_empty() and preset.get("endpoint", "") == endpoint.text and preset.get("model", "") == model.text: return id
	return "cloud"


## 高亮与当前配置对应的档位卡；对应的卡不可选时全部取消高亮。
func _sync_tier() -> void:
	var current: Button = _tier_cards[_current_tier()]
	for id in _tier_cards:
		var card: Button = _tier_cards[id]
		card.set_pressed_no_signal(card == current and not card.disabled)


func _key_source_text() -> String:
	if not store.agent.api_key.is_empty(): return "已保存在设置"
	for name in _key_env:
		if not OS.get_environment(name).strip_edges().is_empty(): return "已从环境变量 %s 读取" % name
	return "未配置"


func _show_page(id: String) -> void:
	for page in _pages: _pages[page].visible = page == id
	_nav[id].set_pressed_no_signal(true)


func _toggle_advanced() -> void:
	_advanced.visible = not _advanced.visible
	_advanced_button.text = ("高级  ⌄" if _advanced.visible else "高级  ›") + "    接口地址、模型名、API Key、等待上限、并发"


## 从当前智能体配置回填全部控件。
func _fill() -> void:
	enabled.button_pressed = store.agent.enabled
	for scope in _scope_pills: _scope_pills[scope].set_pressed_no_signal(scope == store.agent.model_mode)
	endpoint.text = store.agent.endpoint
	model.text = store.agent.model
	key.text = ""
	_clear_key = false
	_key_source.text = _key_source_text()
	timeout.value = store.agent.timeout_seconds
	parallel.value = store.agent.concurrency
	budget.value = store.agent.decision_budget_seconds
	reasoning.button_pressed = store.agent.disable_reasoning
	_sync_tier()
	_set_status(str(store.agent.last_status), store.agent.enabled)
	notice.text = ""


func _set_status(text: String, ok: bool) -> void:
	_status.text = text
	_status_dot.color = Tokens.color("green") if ok else Tokens.color("dim")


func open() -> void:
	_fill()
	_return_button.visible = store.battle_test
	if store.busy and not store.time_paused: store.toggle_time_pause()
	window.show()


func _selected_scope() -> String:
	for scope in _scope_pills:
		if _scope_pills[scope].button_pressed: return scope
	return store.agent.model_mode


func _save() -> void:
	if store.busy:
		notice.text = "请先完成本轮十日推进，再保存模型设置。"
		return
	var values := {"enabled": enabled.button_pressed, "model_mode": _selected_scope(), "endpoint": endpoint.text, "model": model.text, "timeout": timeout.value, "concurrency": parallel.value, "decision_budget": budget.value, "disable_reasoning": reasoning.button_pressed}
	if _clear_key: values["api_key"] = ""
	elif not key.text.strip_edges().is_empty(): values["api_key"] = key.text
	notice.text = store.agent.configure(values)
	key.text = ""
	_clear_key = false
	_key_source.text = _key_source_text()
	_set_status(str(store.agent.last_status), store.agent.enabled)


func _probe_local() -> void:
	if not endpoint.text.begins_with("http://127.0.0.1:11434/") and not endpoint.text.begins_with("http://localhost:11434/"):
		_set_status("检测只针对本机 11434 端口的 Ollama 服务。", false)
		return
	var request := HTTPRequest.new()
	request.timeout = 3
	request.body_size_limit = 1048576
	add_child(request)
	_set_status("正在检测本地模型服务……", false)
	var error := request.request(endpoint.text.get_slice("/api/", 0) + "/api/tags")
	if error != OK:
		_set_status("无法发起检测，请先启动 Ollama。", false)
		request.queue_free()
		return
	var response: Array = await request.request_completed
	request.queue_free()
	if int(response[0]) != HTTPRequest.RESULT_SUCCESS or int(response[1]) != 200:
		_set_status("本地服务未就绪，请先启动 Ollama。", false)
		return
	var data: Variant = JSON.parse_string(response[3].get_string_from_utf8())
	if not data is Dictionary:
		_set_status("本地服务响应无效。", false)
		return
	for available in data.get("models", []):
		if available.get("name", "") == model.text or available.get("model", "") == model.text:
			_set_status("本机服务已连接  ·  %s" % model.text, true)
			return
	_set_status("服务正常，但未安装 %s：运行 ollama pull %s" % [model.text, model.text], false)
