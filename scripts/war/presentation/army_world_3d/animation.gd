@abstract
class_name ArmyWorld3DAnimation
extends "res://scripts/war/presentation/army_world_3d/input.gd"
## 大地图军队表现层·每帧动画：_process 的行军插值、接敌朝向与姿态、交战特效、城头箭雨、伤亡飘字、军中喊话，
## 以及 begin_day() 为一日演出准备的运动起止。热路径都在本层，调用下层函数仍是对 self 的直接调用。

func _speech_event(id: String) -> String:
	var army: Dictionary = store.war.state[StateKeys.ARMIES].get(id,{})
	if army.is_empty() or army.get("commander_unavailable",false): return ""
	if army.get("returning",false): return "retreat"
	if army.get("action",{}).get("type","") == "evade": return "evade"
	if float(army.get("morale",100)) < 35: return "rally"
	if int(army.get("combat_tick",-1)) == int(store.war.state[StateKeys.TICK]):
		var front: Dictionary = _combat_visual(id)
		if front.get("siege",false): return "siege"
		return "ranged" if front.get("ranged",false) else "attack"
	if str(army.get("location",{}).get("edge","")) != "" or (presenting and motion_start.has(id) and motion_start[id].distance_squared_to(destinations.get(id,motion_start[id])) > 0.01): return "march"
	return "hold"

func _update_chatter(force: bool = false) -> void:
	var speaking: Array = []
	for id in badges:
		var badge: Control = badges[id]
		if not badge.speech.is_empty() and chatter_time >= badge.speech_until: badge.set_speech("",0)
		if not badge.speech.is_empty(): speaking.append(id)
	if speaking.size() >= 2 or (not force and chatter_time < next_chatter_at): return
	var candidates: Array = []
	for id in formations:
		var badge: Control = badges[id]
		if not formations[id].visible or not badge.visible or not badge.speech_visible: continue
		if not get_viewport().get_visible_rect().intersects(Rect2(badge.position,badge.size*badge.scale)): continue
		if speaking.has(id) or float(chatter_cooldowns.get(id,-100.0)) > chatter_time: continue
		if speaking.any(func(other): return badges[other].position.distance_to(badge.position) < 155): continue
		var event := _speech_event(id)
		if not event.is_empty(): candidates.append({"id":id,"event":event,"priority":0 if event not in ["hold","march"] else 1,"order":absi(hash(str(id)+str(store.war.state[StateKeys.TICK])+str(floori(chatter_time/3.2))))})
	candidates.sort_custom(func(a,b): return a["priority"] < b["priority"] if a["priority"] != b["priority"] else a["order"] < b["order"])
	next_chatter_at = chatter_time + (3.2 if not candidates.is_empty() else 0.8)
	if candidates.is_empty(): return
	var choice: Dictionary = candidates[0]
	var badge: Control = badges[choice["id"]]
	badge.set_speech(Chatter.line_for(badge.officer_id,choice["event"],choice["order"]),chatter_time+4.5)
	chatter_cooldowns[choice["id"]] = chatter_time+12.0

func _march_position(id: String, progress: float) -> Vector3:
	if march_routes.has(id):
		var route: Dictionary = march_routes[id]
		var lengths: PackedFloat32Array = route["lengths"]
		var points: PackedVector3Array = route["points"]
		var distance := clampf(progress,0,1)*lengths[lengths.size()-1]
		for i in range(1,lengths.size()):
			if distance <= lengths[i]:
				return points[i-1].lerp(points[i],(distance-lengths[i-1])/maxf(lengths[i]-lengths[i-1],0.0001))
		return points[points.size()-1]
	var before: Dictionary = motion_locations.get(id, {})
	var army: Dictionary = store.war.state[StateKeys.ARMIES].get(id, {})
	var sight: Dictionary = {}
	var tactical: bool = int(sight.get("tactical_cell", -1)) >= 0 if not sight.is_empty() else army.has("tactical")
	if tactical and sight.is_empty():
		var path: Array = army.get("tactical",{}).get("move_path",[])
		if path.size() > 2:
			var cursor := clampf(progress,0,1)*float(path.size()-1)
			var leg := mini(floori(cursor),path.size()-2)
			var a: Vector3 = motion_start[id] if leg == 0 else _battle_point(int(path[leg]))
			var b: Vector3 = destinations[id] if leg == path.size()-2 else _battle_point(int(path[leg+1]))
			return a.lerp(b,cursor-float(leg))
	if tactical or before.is_empty(): return motion_start[id].lerp(destinations[id], progress)
	var after: Dictionary = sight.get("location", {}) if not sight.is_empty() else army.get("location", {})
	var old_edge := str(before.get("edge", ""))
	var new_edge := str(after.get("edge", ""))
	var location: Dictionary = after.duplicate(true)
	if new_edge != "" and (old_edge == "" or old_edge == new_edge):
		var start := float(before.get("progress", 0.0)) if old_edge != "" else 0.0
		if old_edge != "" and before.get("from", "") != after.get("from", ""): start = 1.0 - start
		location["progress"] = lerpf(start, float(after["progress"]), progress)
		return world_position(location)
	if old_edge != "" and new_edge == "" and after.get("node", "") == before.get("to", ""):
		location = before.duplicate(true)
		location["progress"] = lerpf(float(before["progress"]), 1.0, progress)
		return world_position(location)
	return motion_start[id].lerp(destinations[id], progress)

func _set_pose(batch: MultiMeshInstance3D, start: int, count: int, rate: float, immediate: bool = false) -> void:
	var old: int = batch.get_meta("pose_start", 0)
	if old == start: return
	if not immediate and animation_time - float(batch.get_meta("transition_at", -1.0)) < 0.18: return
	var material: ShaderMaterial = batch.material_override
	material.set_shader_parameter("previous_start", old)
	material.set_shader_parameter("previous_count", int(batch.get_meta("pose_count", 1)))
	material.set_shader_parameter("previous_rate", float(batch.get_meta("pose_rate", 0.0)))
	material.set_shader_parameter("transition_at", animation_time)
	material.set_shader_parameter("pose_start", start)
	material.set_shader_parameter("pose_count", count)
	material.set_shader_parameter("pose_rate", rate)
	batch.set_meta("pose_start", start)
	batch.set_meta("pose_count", count)
	batch.set_meta("pose_rate", rate)
	batch.set_meta("transition_at", animation_time)

func _process(delta: float) -> void:
	_present_new_duel()
	var duel_shown: bool = duel_showing() and duel_presentation.active_record.get("result", "") != "refused"
	if duel_shown: return
	if map == null or map.camera == null: return
	ground_timer += delta
	if not store.time_paused:
		animation_time += delta * store.time_scale
		if not duel_shown: chatter_time += delta
		if presenting: presentation_elapsed += delta * store.time_scale
	var update_ground: bool = ground_timer >= 0.15
	if update_ground: ground_timer = 0.0
	combat_effects.begin_frame()
	# Place both sides before checking contact; a target must not be a frame behind.
	for id in formations:
		var group: Node3D = formations[id]
		if presenting and motion_start.has(id):
			group.position = melee_positions[id] if melee_positions.has(id) else _march_position(id,clampf(presentation_elapsed/_march_seconds(id),0,1))
		group.position.y = map.height_at(group.position.x,group.position.z)+0.2
	var combat_visuals := {}
	for id in formations:
		var visual := _combat_visual(id)
		combat_visuals[id] = visual
		if not presenting or store.time_paused or visual.is_empty() or visual["siege"] or visual["ranged"]: continue
		var opponent: Dictionary = store.war.state[StateKeys.ARMIES].get(visual.get("target_id",""),{})
		if opponent.get("returning",false): continue
		# A unit that stepped into a broken tile must walk in on the map; freezing
		# it here would leave it rendered on the defender's old cell.
		var mover: Dictionary = store.war.state[StateKeys.ARMIES].get(id,{})
		if int(mover.get("tactical",{}).get("breakthrough_marker",-1)) == int(store.war.state[StateKeys.TICK]): continue
		melee_positions[id] = formations[id].position
	var hidden_members: Dictionary = _update_corps_badges()
	for id in formations:
		var group: Node3D = formations[id]
		var unit: Dictionary = store.war.state[StateKeys.ARMIES].get(id, {})
		var engaged: Dictionary = combat_visuals[id]
		var detail_changed := _apply_troop_detail(group)
		group.visible = map.camera.global_position.distance_to(group.global_position) < 550
		var on_screen: bool = _formation_on_screen(group.global_position)
		if detail_changed: _fit_formation_to_hex(group,_formation_moving(group))
		if not store.time_paused and not engaged.is_empty():
			group.rotation.y = lerp_angle(group.rotation.y,_yaw_between(group.global_position,engaged["target"]),minf(delta*store.time_scale*8.0,1.0))
		elif not store.time_paused and _formation_moving(group):
			var progress := clampf(presentation_elapsed / _march_seconds(id),0,1)
			var tangent := (_march_position(id,minf(1,progress+0.01))-_march_position(id,maxf(0,progress-0.01)))*Vector3(1,0,1)
			if tangent.length_squared() > 0.01: group.set_meta("march_heading",atan2(tangent.x,tangent.z))
			var facing := float(group.get_meta("march_heading",group.rotation.y))
			group.rotation.y = lerp_angle(group.rotation.y,facing,minf(delta*store.time_scale*8.0,1.0))
		var cell: int = store.war.Tactical.grid().pick(Vector2(group.position.x, group.position.z))
		var afloat: bool = not unit.has("tactical") and store.war.Tactical.grid().terrain(cell) in Fortifications.WATER_CODES
		var boats: Node3D = group.get_node_or_null("RiverTransport")
		if boats != null: boats.visible = afloat
		if afloat: group.position.y = maxf(group.position.y, map.WATER_LEVEL + 0.45)
		var pose_batch: MultiMeshInstance3D = group.get_node_or_null("Soldiers")
		if pose_batch != null: pose_batch.visible = not afloat
		if pose_batch != null: pose_batch.material_override.set_shader_parameter("animation_clock", animation_time)
		var bow_batch: MultiMeshInstance3D = group.get_node_or_null("Archers")
		if bow_batch != null: bow_batch.visible = not afloat
		var cavalry: Node3D = group.get_node_or_null("Mounted")
		if cavalry != null: cavalry.visible = not afloat
		var cavalry_batch: MultiMeshInstance3D = group.get_node_or_null("Mounted/Cavalry")
		if cavalry_batch != null: cavalry_batch.material_override.set_shader_parameter("animation_clock", animation_time)
		if bow_batch != null: bow_batch.material_override.set_shader_parameter("animation_clock", animation_time)
		var fighting: bool = not engaged.is_empty()
		var contact_changed: bool = fighting != bool(group.get_meta("combat_pose",false))
		if (update_ground or contact_changed) and not store.time_paused:
			group.set_meta("combat_pose",fighting)
			var batch: MultiMeshInstance3D = group.get_node_or_null("Soldiers")
			if batch != null:
				var army: Dictionary = store.war.state[StateKeys.ARMIES].get(id, {})
				var marching: bool = str(army.get("location", {}).get("edge", "")) != "" and str(army.get("action", {}).get("type", "")) in ["march", "continue", "withdraw"]
				if army.has("tactical") and motion_start.has(id):
					marching = _formation_moving(group)
				if fighting and not combat_meshes.is_empty():
					_set_pose(batch, 9, combat_meshes.size(), 6.5, true)
				elif presenting and marching and not march_meshes.is_empty():
					_set_pose(batch, 1, march_meshes.size(), 4.5)
				elif not idle_meshes.is_empty():
					# Standing armies breathe and shift instead of freezing on one pose.
					_set_pose(batch, 1 + march_meshes.size() + combat_meshes.size(), idle_meshes.size(), 2.2)
				else:
					_set_pose(batch, 0, 1, 0.0)
				# Turn the whole formation onto its engagement or march heading so
				# the soldiers' +Z front matches what the army is actually doing.
				var facing := INF
				if not engaged.is_empty(): facing = _yaw_between(group.global_position, engaged["target"])
				if is_inf(facing) and marching: facing = float(group.get_meta("march_heading", INF))
				if bow_batch != null:
					_set_pose(bow_batch,9,12,6.5,true) if fighting else _set_pose(bow_batch,1,8,4.5) if presenting and marching else _set_pose(bow_batch,21,8,2.2)
				if cavalry_batch != null:
					_set_pose(cavalry_batch,9,12,6.0,true) if fighting else _set_pose(cavalry_batch,1,8,3.2) if presenting and marching else _set_pose(cavalry_batch,21,8,4.0)
				if not engaged.is_empty(): SiegeVisual.aim(group.get_node_or_null("SiegeEngines"),engaged["target"])
				if group.visible: _fit_formation_to_hex(group,_formation_moving(group))

		if group.visible and (presenting or fighting):
			var visual: Dictionary = engaged
			var moving: bool = _formation_moving(group)
			SiegeVisual.animate(group.get_node_or_null("SiegeEngines"), animation_time, not visual.is_empty(), moving)
			# Per-soldier facing and contact effects only near the viewport; the
			# formation clock keeps advancing so re-entering the view is seamless.
			if not on_screen:
				pass
			elif not visual.is_empty():
				var fronts: Array = _combat_fronts(id)
				for front in fronts:
					var target_cell: int = front.get("target_cell",HexPresentation.cell_at(front["target"]))
					if front["ranged"] and group.get_node("Archers").multimesh.visible_instance_count > 0:
						combat_effects.show_archer_volley(front["key"],group,front["target"],animation_time,target_cell)
					else:
						combat_effects.show_contact(front["key"], group.global_position, front["target"], animation_time, front["siege"], front["ranged"], _formation_radius(group), front.get("duel",false),1.55,target_cell)
					if group.get_node_or_null("SiegeEngines") != null:
						combat_effects.show_siege_projectiles(front["key"],group.get_node_or_null("SiegeEngines"),front["target"],animation_time,target_cell)
				if not store.time_paused: _face_contact_sectors(group, fronts, delta * minf(store.time_scale, 2.0))
			elif not store.time_paused and _formation_moving(group):
				_face_contact_sectors(group, [{"target": group.global_position + Vector3(sin(float(group.get_meta("march_heading",0.0))),0,cos(float(group.get_meta("march_heading",0.0)))) * 100}], delta * minf(store.time_scale, 2.0))
		if update_ground: OfficerVisual.ground(self, group)
		var toward_camera: Vector3 = ((map.camera.global_position-group.global_position)*Vector3(1,0,1)).normalized()
		var anchor: Vector3 = group.global_position + toward_camera * 2.7 + Vector3.UP * 0.3
		var badge: Control = badges[id]
		var cam_dist: float = map.camera.global_position.distance_to(anchor)
		badge.scale = Vector2.ONE * Badge.camera_scale(cam_dist, badge.corps_aggregated)
		var speech_detail: bool = badge.scale.x >= 0.34
		if badge.speech_visible != speech_detail:
			badge.speech_visible = speech_detail
			badge.queue_redraw()
		var subordinated: bool = hidden_members.has(id)
		badge.visible = not subordinated and not map.camera.is_position_behind(anchor)
		if badge.visible: badge.position = map.camera.unproject_position(anchor) - Vector2(59, 55) * badge.scale
		# Keep individual models hidden at overview distances; badges stay readable.
		group.visible = map.camera.global_position.distance_to(group.global_position) < 550
	if not store.time_paused and not duel_shown: _update_chatter()
	_show_city_volleys()
	combat_effects.end_frame()
	for marker in supply_markers.values():
		var anchor: Vector3 = marker.get_meta("anchor")
		marker.visible = marker.get_meta("known", false) and not map.camera.is_position_behind(anchor)
		if marker.visible:
			var projected: Vector2 = map.camera.unproject_position(anchor)
			# Briefly suppress overlapping supply captions while a duel is shown.
			for duel in combat_effects.duels.values():
				var label_point: Vector2 = map.camera.unproject_position(duel["title"].global_position)
				if absf(projected.x - label_point.x) < 160 and absf(projected.y - label_point.y) < 65: marker.visible = false
			var viewport: Vector2 = get_viewport().get_visible_rect().size
			marker.position = Vector2(clampf(projected.x - marker.size.x / 2, 12, viewport.x - marker.size.x - 12), clampf(projected.y - marker.size.y / 2, 205, viewport.y - 110))
	if presenting: _spawn_loss_floaters()
	_update_display_stats()
	_update_loss_floaters(delta)
	if presenting and presentation_elapsed >= presentation_duration:
		presenting = false
		motion_start.clear()
		refresh()

func _on_presented_route(id: String) -> bool:
	if not formations.has(id): return false
	var army: Dictionary = store.war.state[StateKeys.ARMIES].get(id,{})
	if not army.has("tactical"): return _at_display_destination(id)
	var cell := HexPresentation.cell_at(formations[id].global_position)
	if cell == int(army["tactical"]["cell"]) or army["tactical"].get("move_path",[]).has(cell): return true
	return presenting and motion_start.has(id) and cell == HexPresentation.cell_at(motion_start[id])

func _melee_contact_ready(id: String, enemy: String) -> bool:
	if not _on_presented_route(id) or not _on_presented_route(enemy): return false
	var a: Vector3 = formations[id].global_position
	var b: Vector3 = formations[enemy].global_position
	var grid = store.war.Tactical.grid()
	var source_cell := HexPresentation.cell_at(a)
	var target_cell := HexPresentation.cell_at(b)
	if grid.distance(source_cell,target_cell) != 1: return false
	var spacing: float = grid.center(source_cell).distance_to(grid.center(target_cell))
	var reach := maxf(spacing*1.15,_formation_radius(formations[id])+_formation_radius(formations[enemy])+0.8)
	return ((a-b)*Vector3(1,0,1)).length_squared() <= reach*reach

func _melee_visual(id: String, enemy: String) -> Dictionary:
	if not formations.has(enemy): return {}
	var army: Dictionary = store.war.state[StateKeys.ARMIES].get(id,{})
	var other: Dictionary = store.war.state[StateKeys.ARMIES].get(enemy,{})
	if other.is_empty() or not army.has("tactical") or not other.has("tactical"): return {}
	# A destroyed formation cannot trade blows. Its empty tile may already have
	# been entered by the breakthrough step; no melee pose may freeze that walk.
	if str(army.get("status","")) == "ended" or str(other.get("status","")) == "ended": return {}
	if int(store.war.Combat.strength(other)) <= 0: return {}
	if army["tactical"].get("phase","") == "远射": return {}
	if not store.war.hostile(str(army["faction"]),str(other["faction"])) or store.war.Tactical.distance(army,other) != 1: return {}
	if not store.battle_test and other["faction"] != store.war.state[StateKeys.PLAYER_FACTION]:
		var sight: Dictionary = observed_enemies.get(enemy,{})
		if int(sight.get("observed_at",-1)) != int(store.war.state[StateKeys.TICK]) or not sight.get("fighting",false): return {}
	if not _melee_contact_ready(id,enemy): return {}
	return {"target":formations[enemy].global_position,"target_id":enemy,"target_cell":HexPresentation.cell_at(formations[enemy].global_position),"siege":false,"ranged":false,"duel":int(army.get("duel_tick",-1)) == int(store.war.state[StateKeys.TICK]) and army.get("duel_opponent","") == enemy}

func _combat_fronts(id: String) -> Array:
	var primary: Dictionary = _combat_visual(id)
	if primary.is_empty(): return []
	var fronts: Array = [primary.duplicate()]
	fronts[0]["key"] = id
	if primary["siege"] or primary["ranged"]: return fronts
	var army: Dictionary = store.war.state[StateKeys.ARMIES].get(id, {})
	if not army.has("tactical"): return fronts
	for enemy_id in formations:
		var enemy: Dictionary = store.war.state[StateKeys.ARMIES].get(enemy_id, {})
		if enemy.is_empty() or enemy["faction"] == army["faction"] or not enemy.has("tactical"): continue
		if str(enemy.get("status","")) == "ended" or int(store.war.Combat.strength(enemy)) <= 0: continue
		if not store.battle_test and enemy["faction"] != store.war.state[StateKeys.PLAYER_FACTION]:
			var seen: Dictionary = observed_enemies.get(enemy_id, {})
			if int(seen.get("observed_at", -1)) != int(store.war.state[StateKeys.TICK]) or not seen.get("fighting", false): continue
		if int(enemy.get("combat_tick", -1)) != int(store.war.state[StateKeys.TICK]): continue
		if enemy["tactical"].get("attack_target", "") != id and not army.get("combat_targets",[]).has(enemy_id) and not enemy.get("combat_targets",[]).has(id): continue
		if not _melee_contact_ready(id,enemy_id): continue
		if store.war.Tactical.distance(army, enemy) > 1: continue
		var target: Vector3 = formations[enemy_id].global_position
		var source: Vector3 = formations[id].global_position
		if store.war.Tactical.grid().distance(store.war.Tactical.grid().pick(Vector2(source.x,source.z)),store.war.Tactical.grid().pick(Vector2(target.x,target.z))) != 1: continue
		if target.distance_squared_to(primary["target"]) < 0.01: continue
		fronts.append({"key": id + ":contact:" + enemy_id, "target": target, "target_id":enemy_id, "siege": false, "ranged": false})
	return fronts

func _face_contact_sectors(group: Node3D, fronts: Array, delta: float = 1.0 / 60.0) -> void:
	var batch: MultiMeshInstance3D = group.get_node_or_null("Soldiers")
	if batch == null: return
	var elapsed := float(group.get_meta("facing_elapsed",0.0))+delta
	if elapsed < 0.05:
		group.set_meta("facing_elapsed",elapsed)
		return
	group.set_meta("facing_elapsed",0.0)
	delta = elapsed
	var changed := false
	for i in range(batch.multimesh.visible_instance_count):
		var transform := batch.multimesh.get_instance_transform(i)
		var offset := Vector3(transform.origin.x, 0, transform.origin.z)
		var best := -INF
		var heading := Vector3.BACK
		for front in fronts:
			var toward: Vector3 = group.basis.inverse() * (front["target"] - group.global_position)
			toward.y = 0
			toward = toward.normalized()
			var score := offset.normalized().dot(toward)
			if score > best: best = score; heading = toward
		var current := atan2(transform.basis.z.x, transform.basis.z.z)
		var goal := atan2(heading.x, heading.z)
		var turn := clampf(wrapf(goal - current, -PI, PI), -3.5 * delta, 3.5 * delta)
		if absf(turn) >= 0.001:
			changed = true
			transform.basis = Basis(Vector3.UP, current + turn).scaled(transform.basis.get_scale())
			batch.multimesh.set_instance_transform(i, transform)
		var data := batch.multimesh.get_instance_custom_data(i)
		var weight := clampf(best, 0.0, 1.0)
		if not is_equal_approx(data.b,weight):
			data.b = weight
			batch.multimesh.set_instance_custom_data(i, data)
	if changed: group.set_meta("facing_revision",int(group.get_meta("facing_revision",0))+1)

func _combat_visual(id: String) -> Dictionary:
	var army: Dictionary = store.war.state[StateKeys.ARMIES].get(id, {})
	if army.is_empty() or not formations.has(id) or army.get("returning",false) or army.get("tactical",{}).get("placement_invalid",false): return {}
	var observed: bool = observed_enemies.has(id) and not store.battle_test
	if observed:
		var sight: Dictionary = observed_enemies[id]
		if not sight.get("fighting", false) or int(sight.get("observed_at", -1)) != int(store.war.state[StateKeys.TICK]): return {}
	elif int(army.get("combat_tick", -1)) != int(store.war.state[StateKeys.TICK]): return {}
	if store.war.Terrain.entry_factor(army,store.war.rules) <= 0: return {}
	var candidates: Array = army.get("combat_targets",[]).duplicate()
	var preferred: String = army.get("tactical",{}).get("attack_target",army.get("action",{}).get("enemy",""))
	if preferred != "": candidates.erase(preferred); candidates.push_front(preferred)
	for enemy in candidates:
		var melee := _melee_visual(id,str(enemy))
		if not melee.is_empty(): return melee
	# A resolved ranged attack may fire while either formation is interpolating.
	# The displayed range below remains authoritative for the visible shot.
	if army.get("tactical", {}).get("phase", "") != "远射" and presenting and motion_start.has(id) and not _at_display_destination(id): return {}
	if int(army.get("duel_tick",-1)) == int(store.war.state[StateKeys.TICK]) and formations.has(army.get("duel_opponent","")):
		var opponent: String = army["duel_opponent"]
		var source: Vector3 = formations[id].global_position
		var destination: Vector3 = formations[opponent].global_position
		var shown_gap: int = store.war.Tactical.grid().distance(store.war.Tactical.grid().pick(Vector2(source.x,source.z)),store.war.Tactical.grid().pick(Vector2(destination.x,destination.z)))
		if shown_gap != 1: return {}
		return {"target":formations[army["duel_opponent"]].global_position,"siege":false,"ranged":false,"duel":true}
	var siege: Dictionary = store.war.state.get(StateKeys.SIEGES, {}).get(army["target"], {})
	if siege.get("phase", "") == "强攻" and int(siege.get("active_tick", -1)) == int(store.war.state[StateKeys.TICK]) and siege.get("participants", []).has(id):
		var board: Dictionary = store.war.Tactical.board_for(store.war,army)
		var visible_cell: int = store.war.Tactical.grid().pick(Vector2(formations[id].position.x,formations[id].position.z))
		if Fortifications.distance_to_wall(board,str(army["target"]),visible_cell) > store.war.Tactical.attack_range(army): return {}
		# 骑兵不能直接攻城，不显示撞墙动作；已入城部队转入巷战，不再对墙出手。
		if preload("res://scripts/war/battle/troop_roles.gd").kind(army) == "cavalry" or Fortifications.inside_city(board, visible_cell) != "": return {}
		var cell: int = store.war.Tactical.board_for(store.war, army).get("objectives", {}).get(army["target"], -1)
		var target := _battle_point(cell) if cell >= 0 else world_position({"node": army["target"], "edge": ""})
		var site := Fortifications.for_city(store,str(army["target"]))
		var outline := Fortifications.footprint(site)
		if not outline.is_empty():
			var origin := Vector2(formations[id].global_position.x,formations[id].global_position.z)
			var closest := Vector2(target.x,target.z)
			for index in range(outline.size()):
				var point := Geometry2D.get_closest_point_to_segment(origin,outline[index],outline[(index+1)%outline.size()])
				if point.distance_squared_to(origin) < closest.distance_squared_to(origin): closest = point
			# Attack the wall immediately in front, not the city center behind it.
			closest += (Vector2(target.x,target.z)-closest).normalized()*0.30
			target = Vector3(closest.x,map.height_at(closest.x,closest.y),closest.y)
		return {"target": target,"target_cell":HexPresentation.cell_at(target), "siege": true, "ranged": preload("res://scripts/war/battle/troop_roles.gd").kind(army) == "archers"}
	var enemy: String = army.get("tactical", {}).get("attack_target", army.get("action", {}).get("enemy", ""))
	if formations.has(enemy):
		var target_army: Dictionary = store.war.state[StateKeys.ARMIES][enemy]
		# Received damage is not proof that this unit fired.
		if not army.get("combat_targets",[]).has(enemy) or not store.war.Tactical.can_engage(store.war,army): return {}
		if target_army.get("status", "") == "ended" or store.war.Combat.strength(target_army) <= 0: return {}
		var reach := 1
		if army.has("tactical") and target_army.has("tactical"):
			reach = store.war.Tactical.attack_range(army)
			if store.war.Tactical.distance(army,target_army) > reach: return {}
		elif army.has("tactical") or target_army.has("tactical"): return {}
		var visible_gap: int = store.war.Tactical.cell_distance(store.war.Tactical.grid().pick(Vector2(formations[id].position.x,formations[id].position.z)),store.war.Tactical.grid().pick(Vector2(formations[enemy].position.x,formations[enemy].position.z)))
		if visible_gap < 1 or visible_gap > reach: return {}
		var target_cell := HexPresentation.cell_at(formations[enemy].global_position)
		var source_cell := HexPresentation.cell_at(formations[id].global_position)
		if not Fortifications.line_of_sight(store.war.Tactical.board_for(store.war,army),source_cell,target_cell): return {}
		return {"target": formations[enemy].global_position,"target_cell":target_cell, "siege": false, "ranged": army.get("tactical", {}).get("phase", "") == "远射"}
	return {}

func _show_city_volleys() -> void:
	if not presenting: return
	for event in store.war.state.get(StateKeys.CITY_VOLLEYS, []):
		if int(event["tick"]) != int(store.war.state[StateKeys.TICK]) or not formations.has(event["target"]): continue
		var target: Node3D = formations[event["target"]]
		if not target.visible: continue
		var city: Dictionary = store.city_state(str(event["city"]))
		if str(city.get("faction", "")) != str(event["faction"]): continue
		var site := Fortifications.for_city(store, str(event["city"]))
		if site.is_empty(): continue
		var source := _city_wall(site, target.global_position) + Vector3.UP * 0.65
		var target_cell := HexPresentation.cell_at(target.global_position)
		var target_army: Dictionary = store.war.state[StateKeys.ARMIES].get(event["target"],{})
		if target_army.has("tactical") and target_cell != int(target_army["tactical"]["cell"]): continue
		combat_effects.show_city_volley(str(event["id"]), source, target.global_position, presentation_elapsed,target_cell)

## 开始演出一日：before 是推进前各军的位置。记下起点、刷新节点，按行军与接敌定每军演出时长和路线，并接入新单挑。
func begin_day(before: Dictionary) -> void:
	for text in loss_floaters: if is_instance_valid(text): text.queue_free()
	loss_floaters.clear()
	loss_contact_since.clear()
	presentation_stats.clear()
	for id in badges:
		presentation_stats[id] = {"strength": badges[id].base_strength, "morale": badges[id].base_morale}
	presenting = true
	presentation_elapsed = 0.0
	presentation_duration = TACTICAL_MOVE_SECONDS
	motion_start.clear()
	motion_durations.clear()
	melee_positions.clear()
	march_routes.clear()
	motion_locations = before.duplicate(true)
	for id in formations:
		motion_start[id] = formations[id].position
		formations[id].set_meta("march_layout_scale",formations[id].get_meta("formation_scale",1.0))
	refresh()
	for id in formations:
		if not motion_start.has(id):
			motion_start[id] = world_position(before[id]) if before.has(id) else formations[id].position
		if not destinations.has(id): destinations[id] = formations[id].position
		var moving: bool = motion_start[id].distance_squared_to(destinations[id]) > 0.01
		var duration := _base_march_seconds(id) if moving else 0.0
		var army: Dictionary = store.war.state[StateKeys.ARMIES].get(id,{})
		if int(army.get("daily_loss_tick",-1)) == int(store.war.state[StateKeys.TICK]) and int(army.get("daily_loss",0)) > 0: duration += CONTACT_SECONDS
		presentation_duration = maxf(presentation_duration,duration)
	for id in formations:
		var army: Dictionary = store.war.state[StateKeys.ARMIES].get(id,{})
		var fighting: bool = int(army.get("combat_tick",-1)) == int(store.war.state[StateKeys.TICK]) or (int(army.get("daily_loss_tick",-1)) == int(store.war.state[StateKeys.TICK]) and int(army.get("daily_loss",0)) > 0)
		motion_durations[id] = _base_march_seconds(id) if fighting else presentation_duration
		_build_march_route(id)
	# Existing contact survives a calendar boundary without one more walking step.
	if not store.time_paused:
		for id in formations:
			var mover: Dictionary = store.war.state[StateKeys.ARMIES].get(id,{})
			if int(mover.get("tactical",{}).get("breakthrough_marker",-1)) == int(store.war.state[StateKeys.TICK]): continue
			var visual := _combat_visual(id)
			if visual.is_empty() or visual["siege"] or visual["ranged"]: continue
			var opponent: Dictionary = store.war.state[StateKeys.ARMIES].get(visual.get("target_id",""),{})
			if not opponent.is_empty() and not opponent.get("returning",false): melee_positions[id] = formations[id].position
	_present_new_duel()
	_update_display_stats()

func _update_display_stats() -> void:
	if not presenting: return
	for id in presentation_stats:
		if not badges.has(id): continue
		var army: Dictionary = store.war.state[StateKeys.ARMIES].get(id,{})
		if army.is_empty() or not army.has("tactical") or int(army.get("daily_loss_tick",-1)) != int(store.war.state[StateKeys.TICK]) or int(army.get("daily_loss",0)) <= 0: continue
		var blend := _loss_display_blend(id)
		var initial_strength := int(presentation_stats[id]["strength"])
		var strength := initial_strength - roundi((initial_strength - store.war.Combat.strength(army)) * blend)
		var morale := lerpf(float(presentation_stats[id]["morale"]), float(army.get("morale", 100)), blend)
		badges[id].base_strength = strength
		badges[id].base_morale = morale
		if not badges[id].corps_aggregated:
			if badges[id].strength != strength or not is_equal_approx(badges[id].morale, morale):
				badges[id].strength = strength
				badges[id].morale = morale
				badges[id].queue_redraw()

func _loss_contact_mode(id: String) -> String:
	if not presenting or not formations.has(id): return ""
	var tick: int = store.war.state[StateKeys.TICK]
	# A defender can take ranged damage without having a legal attack of its own.
	for source in formations:
		if source == id: continue
		var army: Dictionary = store.war.state[StateKeys.ARMIES].get(source,{})
		if int(army.get("combat_tick",-1)) != tick: continue
		if str(army.get("tactical",{}).get("attack_target",army.get("action",{}).get("enemy",""))) != id and not army.get("combat_targets",[]).has(id): continue
		var visual := _combat_visual(source)
		if visual.is_empty() or visual.get("siege",false): continue
		if not visual["ranged"] and not _melee_contact_ready(source,id): continue
		if not army.get("combat_targets",[]).has(id) and visual["target"].distance_squared_to(formations[id].global_position) > 0.01: continue
		return "ranged" if visual["ranged"] else "melee"
	for event in store.war.state.get(StateKeys.CITY_VOLLEYS,[]):
		if not _at_display_destination(id): continue
		if int(event["tick"]) != tick or str(event["target"]) != id: continue
		var army: Dictionary = store.war.state[StateKeys.ARMIES].get(id,{})
		var board: Dictionary = store.war.Tactical.board_for(store.war,army)
		if Fortifications.distance_to_wall(board,str(event["city"]),HexPresentation.cell_at(formations[id].global_position)) <= 2: return "ranged"
	var visual := _combat_visual(id)
	if visual.is_empty(): return ""
	if visual["siege"]: return "melee"
	var target: String = store.war.state[StateKeys.ARMIES].get(id,{}).get("tactical",{}).get("attack_target","")
	return "ranged" if visual["ranged"] else "melee"

func _loss_display_blend(id: String) -> float:
	if not loss_contact_since.has(id): return 0.0
	var delay := 0.70 if _loss_contact_mode(id) == "ranged" else 0.20
	return clampf((presentation_elapsed-float(loss_contact_since[id])-delay)/LOSS_COUNT_SECONDS,0.0,1.0)

func _spawn_loss_floaters() -> void:
	var tick: int = store.war.state[StateKeys.TICK]
	if floated_tick != tick:
		floated_tick = tick
		floated_armies.clear()
		loss_contact_since.clear()
	var maximum := int(store.war.rules.get("feedback",{}).get("max_floaters_per_day",6))
	for id in formations:
		if floated_armies.has(id): continue
		var army: Dictionary = store.war.state[StateKeys.ARMIES].get(id,{})
		if int(army.get("daily_loss_tick",-1)) != tick or int(army.get("daily_loss",0)) <= 0: continue
		if army["faction"] != store.war.state[StateKeys.PLAYER_FACTION] and not store.battle_test:
			var sight: Dictionary = observed_enemies.get(id,{})
			if int(sight.get("observed_at",-1)) != tick or not sight.get("fighting",false): continue
		var mode := _loss_contact_mode(id)
		if mode == "":
			loss_contact_since.erase(id)
			continue
		if not loss_contact_since.has(id): loss_contact_since[id] = presentation_elapsed
		if presentation_elapsed-float(loss_contact_since[id]) < (0.70 if mode == "ranged" else 0.20): continue
		# The label budget controls visual clutter, not strength-bar timing.
		# Every valid contact still records its hit time and blends its own stats.
		if floated_armies.size() >= maximum: continue
		var text := Label3D.new()
		text.set_meta("loss_total",int(army["daily_loss"]))
		text.text = "−%d" % roundi(int(army["daily_loss"])*_loss_display_blend(id))
		text.font = preload("res://scripts/ui/city_ui_skin.gd").font()
		text.font_size = 36
		text.modulate = Color("ffb49c")
		text.outline_modulate = Color(0.12,0.08,0.05)
		text.outline_size = 8
		text.pixel_size = 0.022
		text.no_depth_test = true
		text.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		text.set_meta("army",id)
		text.set_meta("age",0.0)
		add_child(text)
		loss_floaters.append(text)
		floated_armies[id] = true
		_position_loss_floater(text,id,0.0)

func _position_loss_floater(text: Label3D, id: String, age: float) -> void:
	var side: Vector3 = map.camera.global_basis.x*(_formation_radius(formations[id])+0.8)
	text.global_position = formations[id].global_position+side+Vector3(0,2.4+age,0)

func _update_loss_floaters(delta: float) -> void:
	for text in loss_floaters.duplicate():
		if not is_instance_valid(text): loss_floaters.erase(text); continue
		var id: String = text.get_meta("army")
		var age: float = float(text.get_meta("age")) + (0.0 if store.time_paused else delta * store.time_scale)
		text.set_meta("age",age)
		if age >= DAY_SECONDS or not formations.has(id):
			text.queue_free()
			loss_floaters.erase(text)
			continue
		text.visible = formations[id].visible
		text.text = "−%d" % roundi(int(text.get_meta("loss_total"))*_loss_display_blend(id))
		_position_loss_floater(text,id,age)
		text.modulate.a = minf(1,(DAY_SECONDS-age)*2)
