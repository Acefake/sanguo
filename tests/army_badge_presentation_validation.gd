extends SceneTree

const Badge = preload("res://scripts/war/army_badge.gd")
var output := "res://docs/validation/army-badge-update-2026-10-06/"
func _initialize() -> void: call_deferred("run")

func run() -> void:
	root.size = Vector2i(1600,900)
	var store = root.get_node("GameState")
	store.persist_enabled = false
	store.agent.enabled = false
	store.prepare_battle_test(true,"plains_clash",42)
	var war = store.war
	war.rules["duel"]["enabled"] = false
	var own: Array = war.active_armies("liu_bei")
	var chosen: Array = own.slice(0,3)
	var kinds := ["archers","infantry","cavalry"]
	for army in war.active_armies():
		if army.id not in [chosen[0].id,chosen[1].id,chosen[2].id]: army.status = "ended"
	for i in range(3):
		chosen[i].units = {"infantry":0,"archers":0,"cavalry":0}
		chosen[i].units[kinds[i]] = 4000
		chosen[i].tactical.cell = war.Tactical.offset_cell(war.state.battlefield,(i-1)*3,0)
	var scene = load("res://scenes/rtk14_world_3d.tscn").instantiate()
	root.add_child(scene)
	while not scene.loaded: await process_frame
	for frame in range(4): await process_frame
	scene.set_process(false)
	var world = scene.army_world
	world.set_process(false)
	store.time_paused = true
	var middle: Node3D = world.formations[chosen[1].id]
	scene.camera_target = middle.position
	scene.target_goal = middle.position
	scene.pitch = deg_to_rad(35)
	scene.yaw = 0
	for canvas in scene.find_children("*","CanvasLayer",true,false): canvas.visible = false
	world.layer.visible = true
	world.advantage_panel.visible = false
	for army in chosen:
		var formation: Node3D = world.formations[army.id]
		formation.basis = Basis.IDENTITY
		assert(formation.get_node_or_null("BannerLetter") == null)
		assert(formation.get_node("Banner").get_surface_override_material(0) is ShaderMaterial)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output))
	assert(Badge.camera_scale(35) > Badge.camera_scale(100) and Badge.camera_scale(100) > Badge.camera_scale(220))
	for distance in [35,100,220]:
		scene.distance = distance
		scene.distance_goal = distance
		scene._update_camera()
		world._process(0)
		for frame in range(3): await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(output+"zoom-%d.png"%distance)
	scene.distance = 55
	scene.distance_goal = 55
	scene._update_camera()
	world._process(0)
	for i in range(3): assert(world.badges[chosen[i].id].troop_kind == kinds[i])
	var state_before: String = JSON.stringify(war.state)
	world._update_chatter(true)
	world._update_chatter(true)
	assert(JSON.stringify(war.state) == state_before)
	var speakers: Array = []
	for id in world.badges:
		if not world.badges[id].speech.is_empty(): speakers.append(id)
	assert(speakers.size() > 0 and speakers.size() <= 2)
	var clock_before: float = world.chatter_time
	world._process(0.5)
	assert(world.chatter_time == clock_before)
	chosen[0].commander_unavailable = true
	assert(world._speech_event(chosen[0].id).is_empty())
	chosen[0].commander_unavailable = false
	for frame in range(3): await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(output+"dialogue.png")
	world.chatter_time += 5
	world.next_chatter_at = 999
	world._update_chatter()
	for id in speakers: assert(world.badges[id].speech.is_empty())
	print("ARMY_BADGE_PRESENTATION_OK: zoom scaling, 3 native icons, cloth glyphs, bounded dialogue, pause, expiry, commander availability, unchanged simulation state")
	quit()
