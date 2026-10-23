@abstract
class_name Rtk14World3DFrame
extends "res://scripts/world/rtk14_world_3d/builder.gd"
## 3D 大地图·每帧更新：镜头缓动、植被远近切换、城池弹窗与悬停跟随。

func _process(delta: float) -> void:
	if officer_page != null and officer_page.visible:
		return
	if camera == null:
		return
	var direction := Vector2.ZERO
	if Input.is_physical_key_pressed(KEY_W) or Input.is_physical_key_pressed(KEY_UP):
		direction.y -= 1
	if Input.is_physical_key_pressed(KEY_S) or Input.is_physical_key_pressed(KEY_DOWN):
		direction.y += 1
	if Input.is_physical_key_pressed(KEY_A) or Input.is_physical_key_pressed(KEY_LEFT):
		direction.x -= 1
	if Input.is_physical_key_pressed(KEY_D) or Input.is_physical_key_pressed(KEY_RIGHT):
		direction.x += 1
	if direction != Vector2.ZERO:
		var rotated := direction.normalized().rotated(-yaw)
		target_goal += Vector3(rotated.x, 0, rotated.y) * distance_goal * delta * 0.48
	if Input.is_physical_key_pressed(KEY_Q):
		yaw += delta * 0.7
	if Input.is_physical_key_pressed(KEY_E):
		yaw -= delta * 0.7
	target_goal.x = clampf(target_goal.x, -50, WORLD_SIZE + 50)
	target_goal.z = clampf(target_goal.z, -50, WORLD_SIZE + 50)
	target_goal.y = maxf(height_at(target_goal.x, target_goal.z), WATER_LEVEL)
	var smoothing := 1.0 - exp(-delta * 9.0)
	camera_target = camera_target.lerp(target_goal, smoothing)
	distance = lerpf(distance, distance_goal, smoothing)
	_update_camera()
	if loaded:
		vegetation_lod_timer -= delta
		if vegetation_lod_timer <= 0.0:
			vegetation_lod_timer = 0.35
			_update_vegetation_lod()
		var badge_screen_bounds := Rect2(Vector2(-140, -100), get_viewport().get_visible_rect().size + Vector2(280, 200))
		for city_id in city_badges:
			var badge: Control = city_badges[city_id]
			var anchor: Vector3 = city_nodes[city_id].global_position + Vector3(0, 12, 0)
			badge.visible = labels_enabled and cities_root.visible and not camera.is_position_behind(anchor)
			if not badge.visible:
				continue
			var screen := camera.unproject_position(anchor)
			if not badge_screen_bounds.has_point(screen):
				badge.visible = false
				continue
			var badge_position := screen + Vector2(-20, -78) * CITY_BADGE_SCALE
			if not badge.position.is_equal_approx(badge_position):
				badge.position = badge_position
			var state: Dictionary = GameState.city_state(city_id)
			var faction: Dictionary = GameState.scenario.get("factions", {}).get(str(state.get("faction", "")), {})
			var letter := str(faction.get("short", ""))
			var color := Color(str(faction.get("color", "#c5c0aa")))
			var troops := int(state.get("garrison", 0))
			var selected: bool = selected_city == city_id
			if badge.faction_letter != letter or badge.faction_color != color or badge.troops != troops or badge.selected != selected:
				badge.faction_letter = letter
				badge.faction_color = color
				badge.troops = troops
				badge.selected = selected
				badge.queue_redraw()
		_update_city_popup()

func _update_vegetation_lod() -> void:
	# A regional camera is farther away than the old fixed shadow cutoff. Keep
	# mountain self-shadowing in view, but cap the cascades for national overview.
	if map_sun != null:
		var shadow_range := maxf(110.0 if map_quality_mode == 0 else 180.0,
			minf(ceilf(distance * 1.25 / 25.0) * 25.0, 600.0))
		if not is_equal_approx(map_sun.directional_shadow_max_distance, shadow_range):
			map_sun.directional_shadow_max_distance = shadow_range
	var use_overview := distance > 650.0 and vegetation_overview_root != null
	if vegetation_overview_root != null:
		vegetation_overview_root.visible = use_overview
	for batch in vegetation_batches:
		batch.visible = not use_overview
		var mesh := batch.multimesh
		var separation := camera.global_position.distance_to(batch.get_meta("batch_center", Vector3.ZERO))
		# Preserve every source placement through zoom; vary mesh detail, never density.
		mesh.visible_instance_count = -1
		if bool(batch.get_meta("ground_cover", false)):
			batch.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		else:
			batch.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if separation < (85.0 if map_quality_mode == 0 else 180.0) else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

func _update_city_popup() -> void:
	# 弹出层跟随城池，浮在盾旗上方，避免遮住城名。
	if city_popup == null or not city_popup.visible:
		return
	if selected_city.is_empty() or not city_nodes.has(selected_city):
		return
	var anchor: Vector3 = city_nodes[selected_city].position + Vector3(0, 20, 0)
	if camera.is_position_behind(anchor):
		return
	var point := camera.unproject_position(anchor)
	var popup_size := city_popup.size * city_popup.scale
	var viewport_size := get_viewport().get_visible_rect().size
	var target := camera.unproject_position(city_nodes[selected_city].global_position + Vector3(0, 12, 0)) + Vector2(24, -36) * CITY_BADGE_SCALE
	target.x = clampf(target.x, 10.0, maxf(10.0, viewport_size.x - popup_size.x - 10.0))
	target.y = clampf(target.y, 70.0, maxf(70.0, viewport_size.y - popup_size.y - 10.0))
	city_popup.position = target
