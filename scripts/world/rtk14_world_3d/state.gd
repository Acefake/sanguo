@abstract
class_name Rtk14World3DState
extends Node3D
## 3D 大地图·状态：全部常量、成员变量，以及各层共用的查询（地形高度与法线、读 JSON、镜头摆位）。
##
## 链：Rtk14World3DState → Rtk14World3DInput → Rtk14World3DBuilder → Rtk14World3DFrame → rtk14_world_3d.gd。
## 分层继承链（每层 extends 上一层），同一实例、同一组成员；下层不能调用上层的函数。

const CitySkin = preload("res://scripts/ui/city_ui_skin.gd")
const ASSET_DIR := "res://assets/rtk14/"
const HEIGHT_SIZE := 2049
const WORLD_SIZE := 2048.0
const HEIGHT_SCALE := 0.01
const TERRAIN_STEP := 1
const CHUNK_CELLS := 256
const STATIC_PLACEMENT_CHUNK_SIZE := 256.0
const WATER_LEVEL := 0.3
const SOURCE_SCENE := "KIDSSystemResource_6dbf662e.kidsobjdb"
const CITY_BADGE_SCALE := 0.44

var heights := PackedFloat32Array()
var source_heights := PackedFloat32Array()
var grid_transform: Array = []
var landscape_ground_adjusted_count := 0
var map_quality_mode := 0
var map_cells := PackedInt32Array()
var model_library: Dictionary = {}
var mesh_library: Dictionary = {}
var foliage_mesh_library: Dictionary = {}
var vegetation_model_ids: Array = ["c0008e34", "5d3d3f89", "6c07a9c7", "e0e163df", "c765c353", "d6302d91", "32779e6d", "5d20da2c", "4108f1af"]
var vegetation_ground_ids: Array = ["32779e6d", "5d20da2c", "4108f1af"]
var gate_nodes: Dictionary = {}
var city_data: Array = []
var city_nodes: Dictionary = {}
var labels: Array[Label3D] = []
var city_badges: Dictionary = {}
var badge_layer: CanvasLayer
var city_interior: CanvasLayer
var city_hidden_layers: Array[CanvasLayer] = []
var terrain_root: Node3D
var landscape_root: Node3D
var cities_root: Node3D
var vegetation_root: Node3D
var vegetation_overview_root: Node3D
var overview_vegetation_batches: Array[MultiMeshInstance3D] = []
var camera: Camera3D
var last_camera_target := Vector3(INF, INF, INF)
var last_camera_distance := -1.0
var last_camera_yaw := INF
var last_camera_pitch := INF
var camera_target := Vector3(1070, 7, 1100)
var target_goal := Vector3(1070, 7, 1100)
var distance := 1150.0
var distance_goal := 1150.0
var yaw := 0.0
var pitch := deg_to_rad(58.0)
var dragging_button := 0
var drag_distance := 0.0
var selected_city := ""
var hover_city := ""
var status: Label
var city_popup: PanelContainer
var selected_ring: MeshInstance3D
var loaded := false
var vegetation_count := 0
var ground_cover_count := 0
var vegetation_batches: Array[MultiMeshInstance3D] = []
var vegetation_lod_timer := 0.0
var static_instance_count := 0
var static_source_count := 0
var static_filtered_count := 0
var chunk_count := 0
var vegetation_button: Button
var labels_button: Button
var city_button: Button
var labels_enabled := true
var city_pick_positions: Dictionary = {}
var city_foundations: Dictionary = {}
var screenshot_path := ""
var world_splat: Image
var map_environment: Environment
var map_sun: DirectionalLight3D
var officer_page: CanvasLayer
var army_world: Node3D
var hex_world: Node3D

func _read_json(path: String, fallback: Variant) -> Variant:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return fallback
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	return parsed if parsed != null else fallback

## 世界坐标 (x, z) 处的地形高度（双线性插值）。
func height_at(x: float, z: float) -> float:
	if heights.is_empty():
		return 0.0
	var px := clampf(x, 0.0, WORLD_SIZE)
	var pz := clampf(z, 0.0, WORLD_SIZE)
	var ix := mini(int(px), HEIGHT_SIZE - 2)
	var iz := mini(int(pz), HEIGHT_SIZE - 2)
	var fx := px - float(ix)
	var fz := pz - float(iz)
	var a := lerpf(heights[iz * HEIGHT_SIZE + ix], heights[iz * HEIGHT_SIZE + ix + 1], fx)
	var b := lerpf(heights[(iz + 1) * HEIGHT_SIZE + ix], heights[(iz + 1) * HEIGHT_SIZE + ix + 1], fx)
	return lerpf(a, b, fz) * HEIGHT_SCALE

func _normal_at(x: float, z: float) -> Vector3:
	return Vector3(height_at(x - 1, z) - height_at(x + 1, z), 2.0,
		height_at(x, z - 1) - height_at(x, z + 1)).normalized()

func _source_height_at(x: float, z: float) -> float:
	var px := clampf(x, 0.0, WORLD_SIZE)
	var pz := clampf(z, 0.0, WORLD_SIZE)
	var ix := mini(int(px), HEIGHT_SIZE - 2)
	var iz := mini(int(pz), HEIGHT_SIZE - 2)
	var a := lerpf(source_heights[iz * HEIGHT_SIZE + ix], source_heights[iz * HEIGHT_SIZE + ix + 1], px - ix)
	var b := lerpf(source_heights[(iz + 1) * HEIGHT_SIZE + ix], source_heights[(iz + 1) * HEIGHT_SIZE + ix + 1], px - ix)
	return lerpf(a, b, pz - iz) * HEIGHT_SCALE

func _update_camera() -> void:
	if camera_target.is_equal_approx(last_camera_target) and is_equal_approx(distance, last_camera_distance) and is_equal_approx(yaw, last_camera_yaw) and is_equal_approx(pitch, last_camera_pitch):
		return
	last_camera_target = camera_target
	last_camera_distance = distance
	last_camera_yaw = yaw
	last_camera_pitch = pitch
	if map_environment != null:
		map_environment.fog_density = 0.025 / maxf(80.0, distance)
	camera.near = clampf(distance * 0.01, 0.3, 20.0)
	var horizontal := cos(pitch) * distance
	camera.position = camera_target + Vector3(sin(yaw) * horizontal, sin(pitch) * distance, cos(yaw) * horizontal)
	camera.look_at(camera_target, Vector3.UP)
