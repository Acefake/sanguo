extends SceneTree

const Presentation = preload("res://scripts/war/presentation/duel_presentation.gd")
const ArmyRenderer = preload("res://scripts/war/presentation/army_world_3d.gd")
const Duel = preload("res://scripts/war/duel/duel_system.gd")
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("run")

func check(value: bool, message: String) -> void:
	if not value: failures.append(message); push_error(message)

func run() -> void:
	var store: Node = root.get_node("GameState")
	store.persist_enabled = false
	store.prepare_battle_test(true)
	var war = store.war
	var a: Dictionary = war.active_armies("liu_bei")[1]
	var b: Dictionary = war.active_armies("yuan_shao")[1]
	a["tactical"]["cell"] = war.Tactical.offset_cell(war.state["battlefield"],0,0)
	b["tactical"]["cell"] = war.Tactical.neighbors(a["tactical"]["cell"])[0]
	a["action"] = {"type":"engage"}
	b["action"] = {"type":"engage"}
	war.rules["duel"]["acceptance"] = 100.0
	var outcome: Dictionary = Duel.challenge(war,a,b,true)
	check(not outcome.is_empty() and outcome.get("result", "refused") != "refused", "Real accepted duel required")
	var overlay := Presentation.new()
	root.add_child(overlay)
	var renderer := ArmyRenderer.new()
	renderer.store = store
	renderer.duel_presentation = overlay
	renderer.portraits = JSON.parse_string(FileAccess.get_file_as_string("res://data/officer_portraits.json"))
	renderer._present_new_duel()
	check(overlay.visible, "Real duel did not open modal")
	check(overlay.left_face.texture != null and overlay.right_face.texture != null, "Both participant portraits required")
	check(overlay.stage.own_world_3d, "Duel viewport must isolate the world map")
	var actor: Node3D = overlay.fighter_left
	check(not actor.horse_rig.is_empty() and not actor.rider_rig.is_empty(), "Both native weighted rigs required")
	var skeleton: Skeleton3D = actor.rider_rig["skeleton"]
	var leg := skeleton.find_bone("bone_7")
	var wrist := skeleton.find_bone("bone_21")
	actor.pose(0.0, 0.0, 0.0)
	skeleton.force_update_all_bone_transforms()
	check(not skeleton.get_bone_global_pose(leg).is_equal_approx(skeleton.get_bone_global_rest(leg)), "Rider thighs must sit around saddle")
	var hip: Vector3 = skeleton.get_bone_global_pose(leg).origin + actor.rider.position
	var knee: Vector3 = skeleton.get_bone_global_pose(skeleton.find_bone("bone_9")).origin + actor.rider.position
	var ankle: Vector3 = skeleton.get_bone_global_pose(skeleton.find_bone("bone_11")).origin + actor.rider.position
	var seat: Vector3 = skeleton.get_bone_global_pose(skeleton.find_bone("bone_2")).origin + actor.rider.position
	var horse_skeleton: Skeleton3D = actor.horse_rig["skeleton"]
	var horse_seat: Vector3 = horse_skeleton.get_bone_global_pose(horse_skeleton.find_bone("bone_1")).origin + actor.horse.position
	check(absf(seat.y - horse_seat.y - 0.08) < 0.05, "Rider pelvis must rest on the horse saddle anchor")
	check(absf(knee.y - hip.y) < 0.15 and knee.x > 0.35, "Thigh must cross the saddle rather than stand beside it")
	check(ankle.y > 0.85 and ankle.y < knee.y - 0.3, "Boot must hang at riding height")
	check(load("res://assets/duel/rtk14/models/26f8ff97.glb") != null, "Native long saber model must be loaded")
	check(actor.weapon.scene_file_path.ends_with("26f8ff97.glb"), "Rider must wield the native long saber")
	check(overlay.backdrop.material.shader == load("res://shaders/officer_background_blur.gdshader"), "Duel must reuse officer background blur")
	var before: Transform3D = skeleton.get_bone_global_pose(wrist)
	actor.pose(0.4, 1.0, 1.0)
	skeleton.force_update_all_bone_transforms()
	check(not before.is_equal_approx(skeleton.get_bone_global_pose(wrist)), "Strike must animate the hand")
	check(outcome["rounds"].size() <= 30, "A duel cannot exceed 30 passes")
	actor.knock_down()
	check(actor.rider.position.y < 0.1 and not actor.weapon.visible, "Loser must be thrown from the saddle after a knockout")
	await process_frame
	check(root.get_visible_rect().encloses(overlay.root_panel.get_global_rect()), "Duel popup is outside the viewport")
	overlay.elapsed = overlay.ROUND_SECONDS * maxi(overlay.round_data.size(),1) + 2.1
	overlay._update_stage()
	check(not overlay.visible, "Duel modal must close after the result")
	renderer._present_new_duel()
	check(not overlay.visible, "Same duel replayed")
	var next: Dictionary = outcome.duplicate(true)
	next["tick"] = int(outcome["tick"]) + 1
	war.state["duels"]["records"] = [next]
	renderer._present_new_duel()
	check(overlay.visible, "New duel with equal log length was lost")
	overlay.close()
	renderer.free()
	overlay.queue_free()
	await process_frame
	print("MOUNTED_DUEL_VALIDATION_OK" if failures.is_empty() else "MOUNTED_DUEL_VALIDATION_FAILED: " + str(failures))
	quit(0 if failures.is_empty() else 1)
