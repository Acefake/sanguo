extends SceneTree
var failures: Array[String] = []
class NonblockingDuel extends Node:
	var presenting := false
	func begin_day(_before: Dictionary) -> void: presenting = false
	func duel_active() -> bool: return true
func _initialize() -> void: call_deferred("run")
func check(ok: bool, message: String) -> void:
	if not ok and not failures.has(message): failures.append(message); push_error(message)
func run() -> void:
	root.size = Vector2i(1400,800)
	var store = root.get_node("GameState")
	store.persist_enabled = false
	store.agent.enabled = false
	store.prepare_battle_test(true,"plains_clash",42)
	for day in range(4): await store.war.step(null)
	store.time_paused = true
	var scene = load("res://scenes/rtk14_world_3d.tscn").instantiate()
	root.add_child(scene)
	while not scene.loaded: await process_frame
	for frame in range(4): await process_frame
	scene.set_process(false)
	var world = scene.army_world
	world.set_process(false)
	for canvas in scene.find_children("*","CanvasLayer",true,false): canvas.visible = false
	world.layer.visible = true
	world.presenting = false
	world.refresh()
	var center := Vector3.ZERO
	for id in world.formations:
		world.formations[id].position = world.destinations[id]
		center += world.destinations[id]
	center /= world.formations.size()
	scene.camera_target = center
	scene.target_goal = center
	scene.distance = 70
	scene.distance_goal = 70
	scene._update_camera()
	var own: Dictionary = store.war.active_armies(store.war.state["player_faction"])[0]
	world.ui.show_army_orders(own["id"])
	check(world.ui.body.find_child("ChangeFormation",true,false) == null and world.ui.body.find_child("FormationChoice",true,false) == null,"Retired formation UI remains")
	world.ui.drawer.hide()
	var output := "res://docs/validation/battle-flow-2026-10-07/"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output))
	var capture := 0
	var delayed := 0
	var partial := 0
	var unlabeled_partial := 0
	var original_budget: int = store.war.rules["feedback"]["max_floaters_per_day"]
	for day in range(2):
		if day == 1: store.war.rules["feedback"]["max_floaters_per_day"] = 1
		var before := {}
		for army in store.war.active_armies(): before[army["id"]] = army["location"].duplicate(true)
		await store.war.step(null)
		world.begin_day(before)
		store.time_paused = false
		store.time_scale = 1.0
		if day == 0: world.preview_duel()
		var elapsed: float = world.presentation_elapsed
		world._process(0.05)
		check(world.presentation_elapsed > elapsed,"Duel freezes other armies")
		store.time_paused = true
		elapsed = world.presentation_elapsed
		world._process(0.4)
		check(world.presentation_elapsed == elapsed,"Manual pause fails to freeze battle")
		store.time_paused = false
		for frame in range(96):
			world._process(0.05)
			world.advantage_panel.visible = false
			for id in world.presentation_stats:
				if not world.badges.has(id): continue
				var army: Dictionary = store.war.state["armies"].get(id,{})
				if int(army.get("daily_loss_tick",-1)) != int(store.war.state["tick"]) or int(army.get("daily_loss",0)) <= 0: continue
				var old: int = world.presentation_stats[id]["strength"]
				var current: int = world.badges[id].strength
				var final: int = store.war.Combat.strength(army)
				var delay := 0.70 if world._loss_contact_mode(id) == "ranged" else 0.20
				if not world.loss_contact_since.has(id) or world.presentation_elapsed-float(world.loss_contact_since[id]) < delay:
					check(current == old,"Strength changes before visible contact")
					delayed += 1
				if current > final and current < old:
					partial += 1
					if day == 1 and not world.floated_armies.has(id): unlabeled_partial += 1
			await process_frame
			if frame%2 == 0:
				await RenderingServer.frame_post_draw
				root.get_texture().get_image().save_png(output+"frame-%03d.png"%capture)
				capture += 1
		check(not world.presenting,"Day never finishes its presentation")
		for id in world.formations:
			var army: Dictionary = store.war.state["armies"].get(id,{})
			check(world.badges[id].strength == store.war.Combat.strength(army),"Displayed strength never reaches final result")
	check(delayed > 0 and partial > 0,"Delayed and smooth casualty display not exercised")
	check(unlabeled_partial > 0,"Floater limit prevents other armies' strength from animating")
	store.war.rules["feedback"]["max_floaters_per_day"] = original_budget
	var duel := NonblockingDuel.new()
	root.add_child(duel)
	store.war_presentation = duel
	await store._advance_one_day()
	check(not store.busy,"Duel-only presentation prevents day completion")
	store.war_presentation = world
	duel.queue_free()
	print("BATTLE_PRESENTATION_FLOW ","PASS" if failures.is_empty() else failures," delayed=",delayed," smooth=",partial," captured=",capture)
	quit(0 if failures.is_empty() else 1)
