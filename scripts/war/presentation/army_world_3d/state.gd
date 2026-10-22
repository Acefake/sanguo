@abstract
class_name ArmyWorld3DState
extends Node3D
## 大地图军队表现层·状态：全部常量、成员变量，以及各层共用的只读查询（坐标换算、行军时长、阵形尺寸、兵力密度）。
##
## 链：ArmyWorld3DState → ArmyWorld3DHud → ArmyWorld3DBuilder → ArmyWorld3DInput → ArmyWorld3DAnimation → army_world_3d.gd。
## 分层继承链（每层 extends 上一层），同一实例、同一组成员；下层不能调用上层的函数。
const StateKeys = preload("res://scripts/war/campaign/war_state_keys.gd")

const CampaignUI = preload("res://scripts/war/ui/campaign_ui.gd")
const Badge = preload("res://scripts/war/presentation/army_badge.gd")
const Chatter = preload("res://scripts/war/presentation/battle_chatter.gd")
var chatter_time := 0.0
var next_chatter_at := 0.8
var chatter_cooldowns := {}
var flag_symbols := {}
const MAX_SOLDIERS := 128
const CAVALRY_MODELS := 48
const CORPS_AGGREGATE_DISTANCE := 135.0
const FORMATION_MARGIN := 0.18
# Per-kind visible counts by LOD level (near, mid, far). The near step is the
# baseline density; casualties thin the rank from the back, never grow it.
const DENSITY_LEVELS := {"infantry":[128,80,40], "archers":[128,80,40], "cavalry":[48,30,16]}
const Feedback = preload("res://scripts/war/battle/battle_feedback.gd")
const DuelPresentation = preload("res://scripts/war/presentation/duel_gold_presentation.gd")
var advantage_panel: PanelContainer
var advantage_label: Label
var advantage_bar: ProgressBar
var loss_floaters: Array[Label3D] = []
var floated_tick := -1
var floated_armies: Dictionary = {}
var loss_contact_since: Dictionary = {}
var presentation_stats: Dictionary = {}
var map: Node3D
var store: Node
var ui: CanvasLayer
var layer: CanvasLayer
var formations: Dictionary = {}
var supply_markers: Dictionary = {}
var badges: Dictionary = {}
var destinations: Dictionary = {}
var points: Dictionary = {}
var city_aliases: Dictionary = {}
var mesh: Mesh
var march_meshes: Array[Mesh] = []
var idle_meshes: Array[Mesh] = []
var animation_time := 0.0
var portraits: Dictionary = {}
var textures: Dictionary = {}
var army_choice: OptionButton
var ground_timer := 0.0
var observed_enemies: Dictionary = {}
var combat_meshes: Array[Mesh] = []
var combat_effects: Node3D
var duel_presentation: CanvasLayer
var seen_duel_records: Dictionary = {}
var selected_enemy := ""
var selected_plan_army := ""
var intent_overlay: Node3D
var pose_material: ShaderMaterial
var archer_mesh: Mesh
var archer_material: ShaderMaterial
var cavalry_mesh: Mesh
var cavalry_material: ShaderMaterial
var presenting := false
var presentation_elapsed := 0.0
var motion_start: Dictionary = {}
var motion_durations: Dictionary = {}
var melee_positions: Dictionary = {}
var march_routes: Dictionary = {}
var march_exit_directions: Dictionary = {}
var motion_locations: Dictionary = {}
var city_breaches: Dictionary = {}
const DAY_SECONDS := 3.6
const TACTICAL_MOVE_SECONDS := 3.2
const CONTACT_SECONDS := 1.8
const LOSS_COUNT_SECONDS := 1.0
var presentation_duration := DAY_SECONDS
const Fortifications = preload("res://scripts/war/battle/city_fortifications.gd")
const HexPresentation = preload("res://scripts/war/presentation/hex_presentation.gd")
const SiegeVisual = preload("res://scripts/war/presentation/siege_visual.gd")
const OfficerVisual = preload("res://scripts/war/presentation/army_officer_visual.gd")
var troop_pose_bounds: Dictionary = {}

var troop_ground_centers: Dictionary = {}

func _formation_moving(group: Node3D) -> bool:
	var id := str(group.get_meta("army_id",""))
	if melee_positions.has(id): return false
	return presenting and presentation_elapsed < _march_seconds(id) and motion_start.has(id) and motion_start[id].distance_squared_to(destinations.get(id,motion_start[id])) > 0.01

func _march_seconds(id: String) -> float:
	return float(motion_durations.get(id,_base_march_seconds(id)))

func _base_march_seconds(id: String) -> float:
	var army: Dictionary = store.war.state[StateKeys.ARMIES].get(id,{})
	return TACTICAL_MOVE_SECONDS if army.has("tactical") else DAY_SECONDS

## 战役位置（节点或道路上的进度）对应的地表坐标，抬高 0.2。
func world_position(location: Dictionary) -> Vector3:
	var node: String = str(location.get("node", ""))
	var point: Vector2 = points.get(node, Vector2(1024, 1024))
	if str(location.get("edge", "")) != "":
		point = Fortifications.road_point(store, str(location.get("from", node)), str(location.get("to", node)), float(location.get("progress", 0)))
	else:
		var path := Fortifications.road_path(store, node, node)
		if not path.is_empty(): point = store.war.Tactical.grid().center(path[0])
	return Vector3(point.x, map.height_at(point.x, point.y) + 0.2, point.y)

func _battle_point(cell: int) -> Vector3:
	var point: Vector2 = map.hex_world.grid.center(cell)
	return Vector3(point.x, map.height_at(point.x, point.y) + 0.2, point.y)

func _troop_offset(group: Node3D, index: int, kind: String, mode: String) -> Vector3:
	var key := "offsets_"+kind+"_"+mode
	if not group.has_meta(key):
		var widths: Array = [6,8,10,10,8,6] if kind == "cavalry" else [12,16,18,18,18,18,16,12]
		var spacing := Vector2(0.84,1.17) if kind == "cavalry" else Vector2(0.48,0.62)
		var random := RandomNumberGenerator.new()
		random.seed = hash(str(group.name)+kind)
		var offsets := PackedVector3Array()
		var row_spans: Array = []
		for row in range(widths.size()):
			var start := offsets.size()
			for column in range(int(widths[row])):
				var x := (float(column)-(int(widths[row])-1)*0.5)*spacing.x
				var z := (float(row)-(widths.size()-1)*0.5)*spacing.y
				x += (0.12 if row%2 else -0.12)*spacing.x+random.randf_range(-0.09,0.09)*spacing.x
				z += random.randf_range(-0.14,0.14)*spacing.y
				if mode == "march": x *= 0.82; z *= 1.18
				elif mode == "combat": z += maxf(z,0.0)*0.2*(1.0-pow(x/2.5,2.0))
				offsets.append(Vector3(x,0,z))
			row_spans.append([start,offsets.size()])
		var mean := Vector3.ZERO
		for offset in offsets: mean += offset
		mean /= offsets.size()
		for i in range(offsets.size()): offsets[i] -= mean
		# Fill from the front rank backwards, center-out per rank: a thinned unit
		# keeps its contact line and leaves the gaps behind it (rear ranks fill in
		# as fresh models return). The +Z side is the formation's facing edge.
		var distributed := PackedVector3Array()
		for row in range(row_spans.size()-1,-1,-1):
			var span: Array = row_spans[row]
			var order: Array = []
			for i in range(int(span[0]),int(span[1])): order.append(i)
			order.sort_custom(func(a,b): return absf(offsets[a].x) < absf(offsets[b].x) if not is_equal_approx(absf(offsets[a].x),absf(offsets[b].x)) else a < b)
			for i in order: distributed.append(offsets[i])
		group.set_meta(key,distributed)
	var cached: PackedVector3Array = group.get_meta(key)
	return cached[index]

# Pure mapping helpers so headless probes can verify density without a viewport.
static func density_counts(kind: String) -> Array:
	return DENSITY_LEVELS.get(kind,DENSITY_LEVELS["infantry"])

static func density_for_strength(base: int, ratio: float) -> int:
	var scaled := float(base) * (0.22 + 0.78 * clampf(ratio,0.0,1.0))
	return clampi(roundi(scaled),maxi(4,base/8),base)

func _density_ratio(id: String) -> float:
	var army: Dictionary = store.war.state[StateKeys.ARMIES].get(id,{})
	if army.is_empty(): return 1.0
	# The campaign publishes live enemy state board-wide (live_state), so casualty
	# thinning is no longer a faction-private read.
	var initial := float(army.get("initial_strength",0.0))
	if initial <= 0.0: return 1.0
	return clampf(float(store.war.Combat.strength(army)) / initial,0.0,1.0)

# Cheap viewport test used to pause per-soldier CPU work off camera while the
# formation itself keeps advancing in time and space (no pop-in on return).
func _formation_on_screen(position: Vector3, margin: float = 96.0) -> bool:
	if map == null or map.camera == null or not map.camera.is_inside_tree(): return true
	if map.camera.is_position_behind(position): return false
	var viewport: Vector2 = get_viewport().get_visible_rect().size
	var projected: Vector2 = map.camera.unproject_position(position)
	return projected.x >= -margin and projected.x <= viewport.x + margin and projected.y >= -margin and projected.y <= viewport.y + margin

func _portrait(name: String) -> Texture2D:
	if textures.has(name): return textures[name]
	var path: String = str(portraits.get(name, {}).get("unit_portrait", portraits.get(name, {}).get("portrait", "")))
	var texture: Texture2D = null
	if FileAccess.file_exists(path): texture = load(path)
	textures[name] = texture
	return texture

func _duel_record_key(record: Dictionary) -> String:
	return str(record["duel_id"]) if record.has("duel_id") else "%s:%s:%s" % [record.get("tick", -1), record.get("a", ""), record.get("b", "")]

func _yaw_between(from: Vector3, to: Vector3) -> float:
	var direction: Vector3 = to - from
	return INF if direction.length_squared() < 0.01 else atan2(direction.x, direction.z)

func _formation_radius(group: Node3D) -> float:
	var radius := 3.3 if str(group.get_meta("troop_kind","infantry")) == "cavalry" else 2.7
	return radius*float(group.get_meta("formation_scale",1.0))

func _city_wall(site: Dictionary, target: Vector3) -> Vector3:
	var point: Vector2 = site["point"]
	var render_id := str(site["render_id"]) if site["native"] else str(site["id"])
	var city_root: Node3D = map.city_nodes.get(render_id)
	var origin := Vector3(point.x, map.height_at(point.x, point.y), point.y) if city_root == null else city_root.global_position
	var direction := target - origin
	var local := direction if city_root == null else city_root.global_basis.inverse() * direction
	var side := ("east" if local.x > 0 else "west") if absf(local.x) > absf(local.z) else ("south" if local.z > 0 else "north")
	var anchor: Dictionary = site.get("wall_anchors", {}).get(side, {})
	var offset := Vector3(float(anchor.get("x", 2.65 if side == "east" else -2.65 if side == "west" else 0.0)), float(anchor.get("y", 3.8)), float(anchor.get("z", 2.65 if side == "south" else -2.65 if side == "north" else 0.0)))
	return origin + offset if city_root == null else city_root.to_global(offset)

func _at_display_destination(id: String) -> bool:
	if not formations.has(id): return false
	var army: Dictionary = store.war.state[StateKeys.ARMIES].get(id,{})
	if army.has("tactical") and HexPresentation.cell_at(formations[id].global_position) != int(army["tactical"]["cell"]): return false
	if not destinations.has(id): return true
	var delta: Vector3 = (formations[id].position-destinations[id])*Vector3(1,0,1)
	return delta.length_squared() <= 0.64
