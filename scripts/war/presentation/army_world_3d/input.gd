@abstract
class_name ArmyWorld3DInput
extends "res://scripts/war/presentation/army_world_3d/builder.gd"
## 大地图军队表现层·输入：镜头聚焦、点选地图格、快捷键（F8 单挑预览）、从城池出征的界面命令。

func _focus_battle() -> void:
	var center := Vector3.ZERO
	for position in destinations.values(): center += position
	center /= maxf(destinations.size(), 1)
	map.camera_target = center
	map.target_goal = center
	map.distance = float(store.war.state.get(StateKeys.BATTLEFIELD, {}).get("camera_distance", 180))
	map.distance_goal = map.distance
	map.pitch = deg_to_rad(58)
	map._update_camera()

func _select_global_cell(cell: int, preview: bool) -> void:
	if preview: return
	for id in formations:
		var army: Dictionary = store.war.state[StateKeys.ARMIES].get(id, {})
		if not army.has("tactical") or int(army["tactical"]["cell"]) != cell: continue
		if army["faction"] == store.war.state[StateKeys.PLAYER_FACTION]: ui.show_army(id)
		elif observed_enemies.has(id): show_enemy(id)
		return

func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F8:
		preview_duel()
		get_viewport().set_input_as_handled()

## F8：用演示数据预览一场单挑演出。
func preview_duel() -> void:
	if duel_active(): return
	var match_data: Dictionary = preload("res://scripts/war/duel/duel_preview_data.gd").build(store.war)
	duel_presentation.demo = true
	_bind_duel_positions(match_data["record"])
	duel_presentation.present_record(match_data["record"], match_data["left"], match_data["right"], _portrait(match_data["left"]["name"]), _portrait(match_data["right"]["name"]))

## 镜头移到该军，打开其军队面板并显示作战意图。
func focus_army(id: String) -> void:
	if not formations.has(id): return
	map._clear_selection()
	map.target_goal = destinations[id]
	map.distance_goal = 70
	ui.show_army(id)
	selected_plan_army = id
	if not is_instance_valid(intent_overlay):
		intent_overlay = preload("res://scripts/war/presentation/tactical_intent_overlay.gd").new()
		intent_overlay.map = map
		add_child(intent_overlay)
	intent_overlay.show_plan(store.war,store.war.state[StateKeys.ARMIES][id])
	for item in badges:
		badges[item].highlighted = item == id
		badges[item].queue_redraw()

## 从 3D 城池发起出征：本方城打开从该城出征的面板，其它城打开以它为目标的出征面板，未接入路网的城在军情抽屉里提示。
func deploy_city(city: String) -> void:
	var target: String = str(city_aliases.get(city, ""))
	if target != "":
		if store.city_state(target).get("faction", "") == store.war.state[StateKeys.PLAYER_FACTION]:
			ui.show_dispatch_from(target)
		else:
			ui.dispatch_home = ""
			ui.show_dispatch(target)
	else:
		# 未接入路网的城：3D 下军情抽屉默认是关的，提示写进去等于没有任何反馈。
		# 先把抽屉打开再写，并让玩家明确看到是哪一个城不可出征。
		ui.show_reports()
		ui.drawer.show()
		ui.heading.text = "此城暂未接入战役路网"
		ui.body.add_child(ui._label("%s 尚未接入战役路网，无法从此城出征。\n请在军情面板中选择已接入路网的城池出征。" % city, 16))
