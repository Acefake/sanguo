extends SceneTree
const D = preload("res://scripts/war/duel/duel_system.gd")
const N = preload("res://scripts/war/duel/duel_rules_v2.gd")
const Role = preload("res://scripts/war/duel/officer_role.gd")
var failures: Array[String] = []
var evidence: Array = []
var output := "res://docs/validation/duel-v2-2026-10-09"

func _initialize() -> void: call_deferred("run")
func check(ok: bool, message: String) -> void:
	if not ok: failures.append(message); push_error(message)

func run() -> void:
	root.size = Vector2i(1260,710)
	var store = root.get_node("GameState")
	store.persist_enabled = false
	store.agent.enabled = false
	store.prepare_battle_test(true,"plains_clash",42)
	store.time_paused = true
	var war = store.war
	var own: Array = war.active_armies("liu_bei").filter(func(a): return Role.can_duel(war,a))
	var enemies: Array = war.active_armies("yuan_shao").filter(func(a): return Role.can_duel(war,a))
	var a: Dictionary = own[0]
	var b: Dictionary = enemies[0]
	a["tactical"]["cell"] = war.Tactical.offset_cell(war.state["battlefield"],0,0)
	b["tactical"]["cell"] = war.Tactical.neighbors(a["tactical"]["cell"])[0]
	var scene = load("res://scenes/rtk14_world_3d.tscn").instantiate()
	root.add_child(scene)
	while not scene.loaded: await process_frame
	scene.set_process(false)
	var world = scene.army_world
	world.set_process(false)
	scene.camera_target = world.destinations[a["id"]]
	scene.target_goal = scene.camera_target
	scene.distance = 65
	scene.pitch = deg_to_rad(48)
	scene._update_camera()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output))
	var overlay = world.duel_presentation
	for kind in ["knockout","exchange","draw","captured","dead"]:
		# Fixtures change numeric inputs/seed/fate probabilities, then use the real
		# contact -> challenge -> settlement -> map queue path. No preview record.
		war.state["duels"] = {"pairs":{},"counts":{},"records":[]}
		war.state["officer_fates"] = {}
		war.state["officer_states"][a["officer_id"]] = {"status":"deployed"}
		war.state["officer_states"][b["officer_id"]] = {"status":"deployed"}
		world.seen_duel_records.clear()
		for army in [a,b]:
			army["duel_wounded"] = false
			army["commander_unavailable"] = false
			army["returning"] = false
			army["status"] = "active"
			army["action"] = {"type":"engage"}
			army["tactical"]["phase"] = "近战"
			army["units"] = {"infantry":6000,"cavalry":0,"archers":0}
			army.erase("first_contact_effect_tick")
		var ids := [str(a["officer_id"]),str(b["officer_id"])]
		var names: Array = [war.roster.officers[ids[0]]["name"],war.roster.officers[ids[1]]["name"]]
		for index in range(2):
			var info: Dictionary = war.roster.officers[ids[index]]
			info["positions"] = "核心位置：前锋"
			var value := 90.0 if kind in ["exchange","draw"] else 110.0 if index == 0 else 50.0
			info["stats"][2] = value
			for name in ["武艺","膂力","体魄","骑术","箭术"]: info["skills"][name] = value
			info["battle_traits"] = []
			[a,b][index]["skills"] = info["skills"].duplicate(true)
		war.rules["duel"]["acceptance"] = 100.0
		war.rules["duel"]["numeric"]["max_rounds"] = 1 if kind == "draw" else 40
		war.rules["duel"]["allow_death"] = true
		war.rules["officer_fate"]["duel_death"] = 1.0 if kind == "dead" else 0.0
		war.rules["officer_fate"]["duel_capture"] = 1.0 if kind == "captured" else 0.0
		# Avoid succession to preserve the fixture participants between cases.
		var corps_id := str(b.get("corps_id",""))
		var members: Array = war.state["corps"].get(corps_id,{}).get("members",[]).duplicate()
		if not corps_id.is_empty(): war.state["corps"][corps_id]["members"] = [ids[1]]
		war.rng.seed = 1009
		var record := D.challenge(war,a,b,true)
		check(not record.is_empty(),kind+": real challenge did not trigger")
		if record.is_empty(): continue
		check(record["settled"] and record["presentation_pending"],kind+": record was not settled/pending")
		if kind in ["captured","dead"]:
			check(record["fate"]["status"] == kind,kind+": fate does not match display")
			check(war.state["officer_states"][ids[1]]["status"] == kind,kind+": roster state does not match fate")
		if kind == "dead": check(int(war.state["officer_personal_kills"].get(ids[0],0)) > 0,"Kill credit missing")
		var manpower := int(war.state["officer_personal_kills"].get(ids[0],0))
		var state_before: Dictionary = war.state.duplicate(true)
		D.apply_result(war,a,b,record)
		check(war.state == state_before,kind+": replay settlement changed fate/credit")
		world._present_new_duel()
		check(overlay.visible and overlay.active_record["duel_id"] == record["duel_id"],kind+": map queue omitted result")
		if kind == "knockout":
			var speed_before: float = store.time_scale
			store.time_scale = 100.0
			var elapsed_before: float = overlay.elapsed
			await create_timer(.12).timeout
			check(overlay.elapsed > elapsed_before and overlay.elapsed < elapsed_before+1.0,"Duel clock followed pause or game speed")
			store.time_scale = speed_before
		overlay.set_process(false)
		var before_tick := int(war.state["tick"])
		var before_date: String = store.date_text()
		var before_time := float(world.animation_time)
		world._process(2.0)
		check(war.state["tick"] == before_tick and store.date_text() == before_date and world.animation_time == before_time,kind+": battle advanced while showing duel")
		overlay.elapsed = .5
		overlay._update_stage()
		await capture(kind+"-entry")

		check(overlay.card.elapsed < overlay.card.result_at,kind+": round playback was skipped")
		check(not overlay.continue_button.visible,kind+": result button appeared before playback ended")
		for index in range(overlay.card.timeline.size()):
			var row: Dictionary = overlay.card.timeline[index]
			var event: Dictionary = row["event"]
			if index == 0 or not event["hit"] or event["blocked"] or event["type"] == "counter":
				overlay.elapsed = float(row["at"])+.21
				overlay._update_stage()
				await capture(kind+"-event-%02d" % index)
				if index > 8: break
		if kind == "dead":
			overlay.elapsed = overlay.combat_end_at+.04
			overlay._update_stage()
			await capture("dead-kill-slash")
			var winner := int(record["winner"])
			check(overlay.card.cuts[winner].visible and overlay.card.cuts[winner].texture.resource_path.ends_with("duel-kill-slash.png"),"Selected kill slash not used for confirmed death")
		overlay.elapsed = overlay.combat_end_at+.4
		overlay._update_stage()
		await capture(kind+"-result")
		check(overlay.visible and not overlay.continue_button.disabled,kind+": result must remain reviewable without a countdown")
		# Inspect both wide and compact windows using the actual viewport resize.
		if kind == "exchange":
			root.size = Vector2i(800,600)
			await process_frame
			overlay._update_stage()
			overlay._resize()
			await capture("exchange-compact")
			root.size = Vector2i(1600,900)
			await process_frame
			overlay._update_stage()
			overlay._resize()
			await capture("exchange-wide")
			root.size = Vector2i(1260,710)
			await process_frame
			overlay._resize()
		evidence.append({"case":kind,"duel_id":record["duel_id"],"participants":names,"rounds":record["rounds"].size(),"events":overlay.card.timeline.size(),"combat_end_at":overlay.combat_end_at,"result_ready_at":overlay.result_ready_at,"fate":record.get("fate",{}),"personal_kills":manpower,"seed":record["seed"]})
		overlay.elapsed = overlay.result_ready_at+.01
		overlay._update_stage()
		check(not overlay.continue_button.disabled,kind+": continue remained disabled")
		overlay.continue_button.pressed.emit()
		check(not overlay.visible and record["presentation_confirmed"] and not record["presentation_pending"],kind+": confirmation not persisted")
		check(store.time_paused,kind+": user pause state changed")
		if not corps_id.is_empty(): war.state["corps"][corps_id]["members"] = members
	# Pending saved record is picked up during fresh map initialization.
	var pending: Dictionary = war.state["duels"]["records"][0]
	pending["presentation_pending"] = true
	pending["presentation_confirmed"] = false
	scene.queue_free()
	await process_frame
	var loaded_scene = load("res://scenes/rtk14_world_3d.tscn").instantiate()
	root.add_child(loaded_scene)
	while not loaded_scene.loaded: await process_frame
	check(loaded_scene.army_world.duel_active(),"Re-entering map lost pending presentation")
	var paused_date: String = store.date_text()
	var paused_tick := int(war.state["tick"])
	advance_and_wait(store)
	await process_frame
	await process_frame
	check(store.date_text() == paused_date and war.state["tick"] == paused_tick,"Campaign day advanced before duel confirmation")
	var loaded_overlay = loaded_scene.army_world.duel_presentation
	loaded_overlay.set_process(false)
	loaded_overlay.elapsed = loaded_overlay.result_ready_at+.01
	loaded_overlay._update_stage()
	loaded_overlay.continue_button.pressed.emit()
	await process_frame
	check(store.date_text() != paused_date,"Campaign progression did not resume after confirmation")
	var file := FileAccess.open(output+"/map-results.json",FileAccess.WRITE)
	file.store_string(JSON.stringify({"cases":evidence,"failures":failures},"  "))
	print("DUEL_V2_MAP_OK cases=%d failures=%d" % [evidence.size(),failures.size()])
	quit(0 if failures.is_empty() else 1)

func advance_and_wait(store) -> void:
	await store._advance_one_day()

func capture(name: String) -> void:
	await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(output+"/"+name+".png")
