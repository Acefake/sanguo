extends PanelContainer
## 左下角小地图：整张地形底图 + 当前镜头的取景框；点击把镜头移到该处。
##
## 世界坐标 (x, z) ∈ [0, world_size] 线性映射到底图。取景框只在镜头目标或距离变化时重画，
## 每 0.1 秒最多检查一次，不随帧重排。

signal focus_requested(point: Vector2)

const Tokens = preload("res://scripts/ui/theme/ui_tokens.gd")
const SIZE := Vector2(196, 196)
const CHECK_SECONDS := 0.1
## 取景框边长 ≈ 镜头距离 × 该系数（俯视 58° 时屏幕大致覆盖的地面宽度）。
const VIEW_FACTOR := 1.1

var world_size := 2048.0
var _map: TextureRect
var _frame: Control
var _view := Rect2()
var _timer := 0.0
## 返回 [Vector3 镜头目标, float 镜头距离]；由持有者提供，避免小地图依赖地图脚本。
var camera_probe: Callable


func setup(texture: Texture2D, size_of_world: float, probe: Callable) -> void:
	_map.texture = texture
	world_size = size_of_world
	camera_probe = probe


func _init() -> void:
	anchor_top = 1.0
	anchor_bottom = 1.0
	offset_left = Tokens.space(2)
	offset_right = Tokens.space(2) + SIZE.x
	offset_top = -Tokens.space(2) - SIZE.y
	offset_bottom = -Tokens.space(2)
	grow_vertical = Control.GROW_DIRECTION_BEGIN
	# 细边浅框：只留 3px 纸色边与圆角，地图本身就是内容，不再垫深色厚框。
	var style := preload("res://scripts/ui/theme/ui_theme_builder.gd").panel_box(0, "glass")
	style.set_content_margin_all(3)
	add_theme_stylebox_override("panel", style)
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_map = TextureRect.new()
	_map.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_map.stretch_mode = TextureRect.STRETCH_SCALE
	_map.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_map)
	_frame = Control.new()
	_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_frame.draw.connect(_draw_frame)
	add_child(_frame)


func _process(delta: float) -> void:
	_timer += delta
	if _timer < CHECK_SECONDS or not camera_probe.is_valid(): return
	_timer = 0.0
	var probe: Array = camera_probe.call()
	var target: Vector3 = probe[0]
	var side: float = float(probe[1]) * VIEW_FACTOR / world_size
	var view := Rect2(Vector2(target.x, target.z) / world_size - Vector2(side, side) * 0.5, Vector2(side, side))
	if view.is_equal_approx(_view): return
	_view = view
	_frame.queue_redraw()


func _draw_frame() -> void:
	var area := _frame.size
	var rect := Rect2(_view.position * area, _view.size * area).intersection(Rect2(Vector2.ZERO, area))
	if rect.size.x <= 0.0 or rect.size.y <= 0.0: return
	# 取景框：深色底线 + 浅色细线，亮暗地形上都看得清。
	_frame.draw_rect(rect.grow(0.5), Tokens.color("ink", 0.7), false, 3.0)
	_frame.draw_rect(rect, Tokens.color("on_accent"), false, 1.5)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var local: Vector2 = (event.position - _frame.position) / _frame.size
		focus_requested.emit(local.clamp(Vector2.ZERO, Vector2.ONE) * world_size)
		accept_event()
