@abstract
class_name ArmyWorld3DHud
extends "res://scripts/war/presentation/army_world_3d/state.gd"
## 大地图军队表现层·界面叠层：补给标记、敌情抽屉、战况优势条与控制点、军团徽章合并、单挑演出的接入与查询。

func _create_supply_markers() -> void:
	if not store.war.supply_enabled(): return
	for corps in store.war.state[StateKeys.CORPS].values():
		if int(corps["supply"]["cell"]) < 0: continue
		var marker := Label.new()
		marker.add_theme_font_override("font", preload("res://scripts/ui/city_ui_skin.gd").font())
		marker.add_theme_font_size_override("font_size", 14)
		marker.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var style := StyleBoxFlat.new()
		style.bg_color = Color(0.07, 0.10, 0.06, 0.85)
		style.set_content_margin_all(5)
		marker.add_theme_stylebox_override("normal", style)
		marker.set_meta("anchor", _battle_point(int(corps["supply"]["cell"])) + Vector3(0, 4, 0))
		layer.add_child(marker)
		supply_markers[corps["id"]] = marker
	_refresh_supplies()

func _refresh_supplies() -> void:
	for id in supply_markers:
		var corps: Dictionary = store.war.state[StateKeys.CORPS].get(id, {})
		if corps.is_empty(): supply_markers[id].hide(); continue
		var known: bool = true
		for own in store.war.state[StateKeys.CORPS].values():
			if own["faction"] == store.war.state[StateKeys.PLAYER_FACTION] and own["known_supplies"].has(id): known = true
		supply_markers[id].set_meta("known", known and not corps.get("ended", false))
		supply_markers[id].visible = known and not corps.get("ended", false)
		var blocked: bool = int(corps["supply"]["blocked_until"]) > int(store.war.state[StateKeys.TICK])
		supply_markers[id].text = "%s粮道\n%s" % [corps["name"], "截断" if blocked else "畅通"]
		supply_markers[id].modulate = Color("ed7354") if blocked else Color("f1d888")

func _present_new_duel() -> void:
	if not is_instance_valid(duel_presentation) or store == null or store.war == null: return
	if duel_presentation.visible: return
	var records: Array = store.war.state.get(StateKeys.DUELS, {}).get("records", [])
	for record in records:
		var key := _duel_record_key(record)
		if seen_duel_records.has(key): continue
		seen_duel_records[key] = true
		var player_involved: bool = store.battle_test or store.war.state[StateKeys.PLAYER_FACTION] in record.get("factions", [])
		for army in store.war.state.get(StateKeys.ARMIES, {}).values():
			if army.get("officer_id", "") in [record.get("a", ""), record.get("b", "")] and army.get("faction", "") == store.war.state[StateKeys.PLAYER_FACTION]:
				player_involved = true
		if not player_involved:
			record["presentation_pending"] = false
			record["presentation_confirmed"] = true
			continue
		var officers: Dictionary = store.war.roster.officers
		var left: Dictionary = officers.get(str(record.get("a", "")), {})
		var right: Dictionary = officers.get(str(record.get("b", "")), {})
		if left.is_empty() or right.is_empty():
			# No report can be rendered, so do not retain an unconfirmable pending record.
			record["presentation_pending"] = false
			record["presentation_confirmed"] = true
			continue
		duel_presentation.demo = false
		_bind_duel_positions(record)
		var refused: bool = record.get("result", "") == "refused"
		duel_presentation.present_record(record, left, right, null if refused else _portrait(str(left.get("name", ""))), null if refused else _portrait(str(right.get("name", ""))))
		break

## 单挑演出层当前是否可见。
func duel_showing() -> bool:
	return is_instance_valid(duel_presentation) and duel_presentation.visible

## 是否有需要暂停推进的单挑演出（先接入新的单挑记录；被拒绝的单挑只是提示，不算）。
func duel_active() -> bool:
	# Accepted duels retain their playback pause; refusals are nonblocking notices.
	_present_new_duel()
	return duel_showing() and duel_presentation.active_record.get("result", "") != "refused"

func _bind_duel_positions(record: Dictionary) -> void:
	var anchors: Array[Vector3] = []
	for officer_id in [record.get("a", ""), record.get("b", "")]:
		for army in store.war.state.get(StateKeys.ARMIES, {}).values():
			if army.get("officer_id", "") == officer_id:
				anchors.append(formations[army["id"]].global_position if formations.has(army["id"]) else world_position(army["location"]))
				break
	if anchors.size() < 2:
		anchors.clear()
		for formation in formations.values():
			anchors.append(formation.global_position)
			if anchors.size() == 2: break
	if anchors.is_empty(): anchors.append(Vector3.ZERO)
	duel_presentation.source = anchors[0]
	duel_presentation.target = anchors[1] if anchors.size() > 1 else anchors[0] + Vector3(3, 0, 0)

## 在军情抽屉里显示一支已观测敌军的情报。
func show_enemy(id: String) -> void:
	var observed: Dictionary = observed_enemies.get(id, {})
	if observed.is_empty(): return
	selected_enemy = id
	ui.open_body("敌军信息")
	ui.page = "enemy"
	if store.battle_test:
		var army: Dictionary = store.war.state[StateKeys.ARMIES].get(id, {})
		ui.heading.text = str(army.get("name", "敌军")) + "队  测试观察"
		var operation: Dictionary = army.get("operation", {})
		var roles := preload("res://scripts/war/battle/tactical_battlefield.gd").ROLES
		ui.body.add_child(ui._label("职责：%s  阶段：%s\n协同对象：%s  攻击目标：%s" % [roles.get(operation.get("role", ""), "自主行动"), army.get("tactical", {}).get("phase", ""), store.war.state[StateKeys.ARMIES].get(operation.get("support_id", ""), {}).get("name", "无"), store.war.state[StateKeys.ARMIES].get(army.get("tactical", {}).get("attack_target", ""), {}).get("name", "未接敌")], 13))
		ui.body.add_child(ui._label("主将判断：" + str(army.get("last_reason", "")), 14))
		for record in army.get("decision_history", []).slice(-5):
			ui.body.add_child(ui._label("第%d日  %s  %s" % [record["tick"], record["source"], record["candidate_id"]], 12))
	ui.body.add_child(ui._label("兵力：%d\n位置：%s\n状态：%s" % [int(observed["strength_estimate"]), store.war.graph.name_of(str(observed["location"]["node"])), "撤退中" if observed["routing"] else "行动中"], 14))

func _refresh_enemy_panel() -> void:
	# Refresh live enemy information after each campaign update.
	if selected_enemy == "" or not is_instance_valid(ui) or ui.page != "enemy" or not ui.drawer.visible: return
	if observed_enemies.get(selected_enemy, {}).is_empty():
		ui.open_body("敌军信息")
		ui.body.add_child(ui._label("该部队已结束行动。", 14))
		return
	show_enemy(selected_enemy)

## 战况细条：顶栏下方居中一条「我军 ▬▬ 敌军」，独立战场时下面一行目标进度。
func _build_battle_feedback() -> void:
	var Widgets := preload("res://scripts/ui/theme/ui_widgets.gd")
	var Tokens := preload("res://scripts/ui/theme/ui_tokens.gd")
	advantage_panel = PanelContainer.new()
	advantage_panel.name = "BattleAdvantage"
	Widgets.adopt_theme(advantage_panel)
	advantage_panel.theme_type_variation = "BarPanel"
	advantage_panel.anchor_left = 0.5
	advantage_panel.anchor_right = 0.5
	advantage_panel.offset_left = -220
	advantage_panel.offset_right = 220
	advantage_panel.offset_top = 72
	advantage_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var box := Widgets.vbox(0)
	advantage_panel.add_child(box)
	var row := Widgets.hbox(1)
	box.add_child(row)
	row.add_child(Widgets.label("我军", "NoteLabel"))
	advantage_bar = ProgressBar.new()
	advantage_bar.custom_minimum_size = Vector2(0, 6)
	advantage_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	advantage_bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	advantage_bar.show_percentage = false
	var enemy_side := StyleBoxFlat.new()
	enemy_side.bg_color = Tokens.color("accent")
	enemy_side.set_corner_radius_all(Tokens.radius("pill"))
	advantage_bar.add_theme_stylebox_override("background", enemy_side)
	row.add_child(advantage_bar)
	row.add_child(Widgets.label("敌军", "NoteLabel"))
	advantage_label = Widgets.muted("")
	advantage_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(advantage_label)
	var objective_label := Widgets.muted("", true)
	objective_label.name = "BattleObjectiveLabel"
	objective_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(objective_label)
	layer.add_child(advantage_panel)
	_refresh_battle_feedback()

func _refresh_battle_feedback() -> void:
	if not is_instance_valid(advantage_panel): return
	advantage_panel.visible = not store.war.active_armies().is_empty()
	var balance := Feedback.visible_advantage(store.war)
	advantage_bar.value = balance["percent"]
	advantage_label.text = "战况  %.0f%% : %.0f%%" % [balance["percent"], 100 - balance["percent"]]
	var objective_label: Label = advantage_panel.find_child("BattleObjectiveLabel", true, false)
	objective_label.text = preload("res://scripts/war/battle/battle_objectives.gd").status_text(store.war)
	objective_label.visible = store.battle_test
	_refresh_control_marker()

func _refresh_control_marker() -> void:
	var point: Dictionary = store.war.state.get(StateKeys.BATTLEFIELD, {}).get("control_point", {})
	var marker: Node3D = get_node_or_null("ControlPointMarker")
	if point.is_empty():
		if is_instance_valid(marker): marker.hide()
		return
	if marker == null:
		marker = Node3D.new()
		marker.name = "ControlPointMarker"
		add_child(marker)
		var ring := MeshInstance3D.new()
		var mesh := CylinderMesh.new()
		mesh.top_radius = 3.0
		mesh.bottom_radius = 3.0
		mesh.height = 0.12
		var material := StandardMaterial3D.new()
		material.albedo_color = Color(0.95, 0.72, 0.2, 0.4)
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mesh.material = material
		ring.mesh = mesh
		marker.add_child(ring)
		var label := Label3D.new()
		label.name = "ControlPointName"
		label.font = preload("res://scripts/ui/city_ui_skin.gd").font()
		label.font_size = 48
		label.pixel_size = 0.07
		label.position.y = 5.0
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.no_depth_test = true
		marker.add_child(label)
	var location: Vector2 = store.war.Tactical.world_cell(int(point["cell"]))
	marker.position = Vector3(location.x, map.height_at(location.x, location.y) + 0.3, location.y)
	marker.show()
	var label: Label3D = marker.get_node("ControlPointName")
	label.text = "%s\n%d/%d日" % [point["name"], point["progress"], point["hold_days"]]
	label.modulate = Color("f4d183") if point["owner"] == "" else Color("9ac676") if point["owner"] == store.war.state[StateKeys.PLAYER_FACTION] else Color("e98570")

func _update_corps_badges() -> Dictionary:
	var hidden_members: Dictionary = {}
	if store == null or store.war == null or not is_instance_valid(map) or not is_instance_valid(map.camera): return hidden_members
	var corps_map: Dictionary = store.war.state.get(StateKeys.CORPS, {})
	if corps_map.is_empty(): return hidden_members
	for corps_id in corps_map:
		_sync_corps_badge_aggregation(corps_map[corps_id], hidden_members)
	return hidden_members

func _sync_corps_badge_aggregation(corps: Dictionary, hidden_members: Dictionary) -> void:
	var root_id: String = _find_corps_leader_id(corps)
	if root_id.is_empty() or not formations.has(root_id): return
	var root_dist: float = map.camera.global_position.distance_to(formations[root_id].global_position)
	var active_members: Array = _collect_corps_active_members(corps)
	# 远景且存在多支分队时触发军团徽标聚合，隐藏从属队并由主帅展示帅印与全军总兵力
	var should_aggregate: bool = (root_dist >= CORPS_AGGREGATE_DISTANCE) and (active_members.size() > 1)
	var total_strength: int = 0
	var total_morale: float = 0.0
	for uid in active_members:
		total_strength += int(badges[uid].base_strength)
		total_morale += float(badges[uid].base_morale)
	var avg_morale: float = (total_morale / float(active_members.size())) if not active_members.is_empty() else 100.0
	badges[root_id].set_corps_aggregated(should_aggregate, total_strength, avg_morale)
	for uid in active_members:
		if uid == root_id: continue
		badges[uid].set_corps_aggregated(false)
		if should_aggregate: hidden_members[uid] = true

func _find_corps_leader_id(corps: Dictionary) -> String:
	var root_id: String = corps.get("root_id", "")
	if badges.has(root_id): return root_id
	for uid in corps.get("units", []):
		if badges.has(uid): return str(uid)
	return ""

func _collect_corps_active_members(corps: Dictionary) -> Array:
	var active: Array = []
	for uid in corps.get("units", []):
		if not badges.has(uid): continue
		var army: Dictionary = store.war.state.get(StateKeys.ARMIES, {}).get(uid, {})
		if army.get("status", "") == "ended": continue
		active.append(uid)
	return active
