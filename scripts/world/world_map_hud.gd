extends Control
## 3D 大地图的界面外壳：顶栏（势力 · 日期 · 推进与速度 · 入口）、左下小地图、地图工具弹层。
##
## 右侧抽屉与底部军报浮条属于军务界面（campaign_ui），这里只负责地图本身的入口。
## 顶栏文字由 GameState 的信号驱动刷新；推进中每 0.25 秒补刷一次进度，不逐帧重算。

const TopBar = preload("res://scripts/ui/shell/top_bar.gd")
const Minimap = preload("res://scripts/ui/shell/minimap.gd")
const Tokens = preload("res://scripts/ui/theme/ui_tokens.gd")
const Widgets = preload("res://scripts/ui/theme/ui_widgets.gd")
const MINIMAP_TEXTURE := "res://assets/rtk14/terrain/source_albedo.png"
const BUSY_REFRESH_SECONDS := 0.25

var map: Node3D
var top_bar: PanelContainer
var minimap: PanelContainer
var tools: PopupPanel
var tool_list: VBoxContainer
var store: Node
var _busy_timer := 0.0


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	Widgets.adopt_theme(self)
	store = get_node("/root/GameState")
	top_bar = TopBar.new()
	add_child(top_bar)
	var entries := [["reports", "军情"], ["armies", "部队"], ["officers", "人物"]]
	if not store.battle_test: entries += [["city", "城务"], ["talents", "人才"]]
	for entry in entries + [["tools", "地图"], ["help", "帮助"], ["settings", "设置"]]:
		top_bar.add_entry(entry[0], entry[1])
	if store.battle_test: top_bar.add_entry("scenarios", "换战场")
	top_bar.flow_pressed.connect(_flow)
	top_bar.speed_selected.connect(func(scale: float) -> void:
		store.time_scale = scale
		refresh())
	top_bar.entry_pressed.connect(_entry)
	minimap = Minimap.new()
	add_child(minimap)
	if ResourceLoader.exists(MINIMAP_TEXTURE):
		minimap.setup(load(MINIMAP_TEXTURE), map.WORLD_SIZE, func() -> Array: return [map.camera_target, map.distance])
	minimap.focus_requested.connect(func(point: Vector2) -> void:
		map.target_goal = Vector3(point.x, map.target_goal.y, point.y))
	tools = PopupPanel.new()
	add_child(tools)
	tool_list = Widgets.vbox(1)
	tool_list.custom_minimum_size.x = 200
	tools.add_child(tool_list)
	store.campaign_progress.connect(refresh)
	store.campaign_changed.connect(refresh)
	store.city_changed.connect(func(_id: String) -> void: refresh())
	refresh()


func _process(delta: float) -> void:
	if not store.busy: return
	_busy_timer += delta
	if _busy_timer < BUSY_REFRESH_SECONDS: return
	_busy_timer = 0.0
	refresh()


## 重写顶栏全部文字。只在状态变化或推进进度时调用。
func refresh() -> void:
	var faction_id: String = str(store.war.state.get("player_faction", "liu_bei"))
	var faction: Dictionary = store.scenario.get("factions", {}).get(faction_id, {})
	var cities := 0
	for city in store.scenario.get("places", {}).values():
		if str(city.get("faction", "")) == faction_id: cities += 1
	var armies: int = store.war.active_armies(faction_id).size()
	var color := Color.html(str(faction["color"])) if faction.has("color") else Tokens.color("green")
	top_bar.set_faction(str(faction.get("short", "")), str(faction.get("name", "")), color, "城 %d  ·  在外部队 %d  ·  命令书 %d" % [cities, armies, store.action_points])
	var period: String = ["上旬", "中旬", "下旬"][clampi((store.day - 1) / 10, 0, 2)]
	var phase := ""
	if is_instance_valid(map.army_world): phase = map.army_world.ui.time_phase_text()
	top_bar.set_date("%d 年 %d 月 %s" % [store.year, store.month, period], phase)
	var ended: bool = not store.war.state.get("campaign_result", {}).is_empty()
	var flow := (("继续" if store.time_paused else "暂停") if store.busy else "进行")
	top_bar.set_flow(flow, not ended, store.time_scale)


## 添加一项地图工具（植被、城名、画质等），收在「地图」入口的弹层里。
func add_tool(control: Control) -> void:
	tool_list.add_child(control)


func _flow() -> void:
	if is_instance_valid(map.army_world): map.army_world.ui._next_turn()


func _entry(id: String) -> void:
	match id:
		"reports": _reports()
		"armies": _show_armies()
		"officers": map._open_officers()
		"city": _campaign_page("show_city_policy")
		"talents": _campaign_page("show_talents")
		"tools": _show_tools()
		"help": _help()
		"settings": store.open_settings()
		"scenarios": store.open_battle_scenarios()


func _show_tools() -> void:
	var anchor: Control = top_bar.find_child("Entry_tools", true, false)
	tools.position = Vector2i(int(anchor.global_position.x), int(top_bar.get_global_rect().end.y) + Tokens.space(1))
	tools.popup()


## 3D 地图上没有战役工具行，城务、人才从顶栏入口打开战役抽屉页。
func _campaign_page(method: String) -> void:
	if is_instance_valid(map.army_world): map.army_world.ui.call(method)


func _reports() -> void:
	if is_instance_valid(map.army_world): map.army_world.ui.show_reports()


func _show_armies() -> void:
	if is_instance_valid(map.army_world):
		map.army_world.army_choice.get_popup().popup(Rect2i(int(get_viewport_rect().size.x) - 320, int(top_bar.get_global_rect().end.y) + Tokens.space(1), 300, 100))


func _help() -> void:
	var dialog := AcceptDialog.new()
	dialog.title = "地图操作"
	dialog.dialog_text = "滚轮缩放，左键 / 中键拖动，右键旋转\n点选城池查看，WASD 移动，Q / E 环绕\nF 全国视野，Home 朝北，G 切换格线\n空格推进 / 暂停，城池菜单可出阵或进入\n左下小地图点击可移动镜头"
	add_child(dialog)
	dialog.confirmed.connect(dialog.queue_free)
	dialog.popup_centered()
