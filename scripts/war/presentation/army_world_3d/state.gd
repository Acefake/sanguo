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
const MAX_SOLDIERS := 240
const CAVALRY_MODELS := 80
const CORPS_AGGREGATE_DISTANCE := 135.0
const FORMATION_MARGIN := 0.18
# Contact facing runs in army_pose.gdshader: up to MAX_FRONTS fronts per formation, each soldier turning
# toward the nearest one at SOLDIER_TURN_RATE rad/s of animation_time.
const MAX_FRONTS := 4
const SOLDIER_TURN_RATE := 3.5
# Melee contact in army_pose.gdshader: front ranks within CONTACT_PUSH_BAND m of the hex edge (beyond their lunge
# reach) close on it, every lunge stopping CONTACT_GAP m short. Fallen soldiers stay drawn FALL_SECONDS.
const CONTACT_PUSH_BAND := 2.2
const CONTACT_GAP := 0.2
const FALL_SECONDS := 1.35
# Per-kind visible counts by LOD level (near, mid, far). The near step is the
# baseline density; casualties and LOD thin the whole hex evenly, never grow it.
const DENSITY_LEVELS := {"infantry":[240,150,75], "archers":[240,150,75], "cavalry":[80,50,26]}
# Batch path, model scale and lattice aspect (row / column spacing) per troop kind.
# Model scale includes MODEL_SIZE, the on-map soldier size (about the size the old
# rank block was shrunk to); the layout fills the hex around it.
const MODEL_SIZE := 0.62
const TROOP_KINDS := {
	"infantry": {"batch": "Soldiers", "count": MAX_SOLDIERS, "scale": 1.18 * MODEL_SIZE, "aspect": 1.29},
	"archers": {"batch": "Archers", "count": MAX_SOLDIERS, "scale": 1.2 * MODEL_SIZE, "aspect": 1.29},
	"cavalry": {"batch": "Mounted/Cavalry", "count": CAVALRY_MODELS, "scale": 0.72 * MODEL_SIZE, "aspect": 1.39},
}
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
var troop_pose_bounds: Dictionary = {}
# Standing and marching poses only (combat lunges excluded); sizes the hex layout.
var troop_rest_bounds: Dictionary = {}
# kind -> {"points": ordered base offsets, "a", "b": ellipse semi-axes, "spacing", "radius": farthest point,
# "extent": farthest pose corner at any heading}; shared by all formations.
var troop_layouts: Dictionary = {}

var troop_ground_centers: Dictionary = {}
# Combat reads for _process (animation.gd _refresh_combat_cache): id -> _combat_visual, id -> fronts (filled on
# demand), ids an enemy melee front points at. Valid while the tick, presenting, battle_test and every formation
# position stay the same; refresh() and begin_day() drop them.
var combat_cache: Dictionary = {}
var combat_fronts_cache: Dictionary = {}
var combat_attacked: Dictionary = {}
var combat_cache_tick := -1
var combat_cache_flags := -1
var combat_cache_positions := PackedVector3Array()

func _drop_combat_cache() -> void:
	combat_cache_tick = -1
	combat_cache.clear()
	combat_fronts_cache.clear()
	combat_attacked.clear()

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
	if not group.has_meta(key): group.set_meta(key,_formation_offsets(group,kind,mode))
	var cached: PackedVector3Array = group.get_meta(key)
	return cached[index]

# This formation's offsets: the shared hex layout plus a small per-formation jitter
# (seeded by the node name, so stable across frames and reloads), recentred so the
# full formation stands on the hex center. March narrows the column; combat packs
# each file toward the +Z front. Both stay inside the layout ellipse.
func _formation_offsets(group: Node3D, kind: String, mode: String) -> PackedVector3Array:
	var layout := _troop_layout(kind)
	var a: float = layout["a"]
	var b: float = layout["b"]
	var spacing: Vector2 = layout["spacing"]
	var random := RandomNumberGenerator.new()
	random.seed = hash(str(group.name)+kind)
	var offsets := PackedVector3Array()
	var mean := Vector3.ZERO
	for base in layout["points"]:
		var p := Vector2(base.x+random.randf_range(-0.12,0.12)*spacing.x, base.z+random.randf_range(-0.14,0.14)*spacing.y)
		var reach := sqrt(pow(p.x/a,2.0)+pow(p.y/b,2.0))
		if reach > 1.0: p /= reach
		offsets.append(Vector3(p.x,0,p.y))
		mean += offsets[offsets.size()-1]
	mean /= maxi(offsets.size(),1)
	# Recentring can move a rim soldier out of the ellipse by at most |mean|.
	group.set_meta("layout_slack_"+kind,mean.length())
	for i in range(offsets.size()):
		var p := offsets[i]-mean
		if mode == "march": p.x *= 0.82
		elif mode == "combat":
			var half := b*sqrt(maxf(1.0-pow(p.x/a,2.0),0.0))
			if half > 0.001:
				var t := clampf(p.z/half,-1.0,1.0)
				p.z = half*(t+0.25*(1.0-t*t))
		offsets[i] = p
	return offsets

# The shared layout for a troop kind, built once: a staggered lattice clipped to the
# largest ellipse whose soldiers (standing and marching poses) stay inside the hex's
# inscribed circle at any heading, minus FORMATION_MARGIN. Ordered by farthest-point
# sampling, so the first n points cover the whole ellipse evenly: casualties and LOD
# thin the formation everywhere instead of emptying the rear.
func _troop_layout(kind: String) -> Dictionary:
	if troop_layouts.has(kind): return troop_layouts[kind]
	var spec: Dictionary = TROOP_KINDS[kind]
	var count: int = spec["count"]
	var limit := HexPresentation.inset_radius(0)-FORMATION_MARGIN
	var bounds: AABB = troop_rest_bounds.get(kind, AABB(Vector3(-0.35,0,-0.6),Vector3(0.7,2,1.9)))
	var middle: Vector3 = troop_ground_centers.get(kind,Vector3.ZERO)
	var corners: Array[Vector2] = []
	for i in range(8):
		var corner := (bounds.get_endpoint(i)-middle)*float(spec["scale"])
		corners.append(Vector2(corner.x,corner.z))
	var side := 0.0
	var front := 0.0
	for corner in corners:
		side = maxf(side,absf(corner.x))
		front = maxf(front,absf(corner.y))
	# Shrink the axis-fitted ellipse until every rim point plus every pose corner fits.
	var a := limit-side
	var b := limit-front
	var worst := 0.0
	for attempt in range(40):
		worst = 0.0
		for step in range(72):
			var angle := TAU*step/72.0
			var rim := Vector2(cos(angle)*a,sin(angle)*b)
			for corner in corners: worst = maxf(worst,(rim+corner).length())
		if worst <= limit: break
		a *= 0.98
		b *= 0.98
	var aspect: float = spec["aspect"]
	var column := sqrt(PI*a*b/(count*aspect))
	var lattice := PackedVector2Array()
	while true:
		lattice.clear()
		var row_step := column*aspect
		var rows := ceili(b/row_step)
		var columns := ceili(a/column)+1
		for row in range(-rows,rows+1):
			for col in range(-columns,columns+1):
				var p := Vector2((col+(0.5 if absi(row)%2 else 0.0))*column,row*row_step)
				if pow(p.x/a,2.0)+pow(p.y/b,2.0) <= 1.0: lattice.append(p)
		if lattice.size() >= count: break
		column *= 0.98
	# Drop the outermost extras so the rim stays even.
	var by_reach: Array = range(lattice.size())
	by_reach.sort_custom(func(i,j): return pow(lattice[i].x/a,2.0)+pow(lattice[i].y/b,2.0) < pow(lattice[j].x/a,2.0)+pow(lattice[j].y/b,2.0))
	var kept := PackedVector2Array()
	for i in range(count): kept.append(lattice[by_reach[i]])
	var points := PackedVector3Array()
	var nearest := PackedFloat32Array()
	nearest.resize(count)
	nearest.fill(INF)
	var current := 0
	var radius := 0.0
	for picked in range(count):
		var p := kept[current]
		points.append(Vector3(p.x,0,p.y))
		radius = maxf(radius,p.length())
		nearest[current] = -1.0
		var farthest := -1
		for i in range(count):
			if nearest[i] < 0.0: continue
			nearest[i] = minf(nearest[i],kept[i].distance_squared_to(p))
			if farthest < 0 or nearest[i] > nearest[farthest]: farthest = i
		current = farthest
	var layout := {"points":points,"a":a,"b":b,"radius":radius,"spacing":Vector2(column,column*aspect),"extent":worst}
	troop_layouts[kind] = layout
	return layout

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
	var radius: float = _troop_layout(str(group.get_meta("troop_kind","infantry")))["radius"]
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
