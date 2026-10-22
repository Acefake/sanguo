extends "res://scripts/war/presentation/army_world_3d/animation.gd"
## 大地图上的军队表现（rtk14_world_3d 的子节点，GameState.war_presentation 指向它）。
##
## 本文件只留节点生命周期与协调：_ready 装配各部件并接信号、_exit_tree 解除登记、单挑结束后的确认。
## 实现分在 army_world_3d/ 下五层（state → hud → builder → input → animation），本脚本继承最上层，
## 所以对外成员、信号连接、场景与子类（测试里的 WorldProbe）的用法都不变。

func _ready() -> void:
	store = get_node("/root/GameState")
	store.war_presentation = self
	portraits = JSON.parse_string(FileAccess.get_file_as_string("res://data/officer_portraits.json"))
	var positions: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/war/world_3d_positions.json"))
	for id in positions["positions"]:
		var entry: Dictionary = positions["positions"][id]
		points[id] = Vector2(entry["x"], entry["z"])
	city_aliases = positions["city_aliases"]
	for site in Fortifications.sites(store).values():
		if site["id"] != "": points[site["id"]] = site["point"]
	_load_mesh()
	combat_effects = preload("res://scripts/war/presentation/combat_effects_3d.gd").new()
	combat_effects.height_at = map.height_at
	combat_effects.camera = map.camera
	add_child(combat_effects)
	layer = CanvasLayer.new()
	layer.layer = 3
	add_child(layer)
	duel_presentation = DuelPresentation.new()
	for record in store.war.state.get(StateKeys.DUELS, {}).get("records", []):
		if not record.get("presentation_pending", false): seen_duel_records[_duel_record_key(record)] = true
	layer.add_child(duel_presentation)
	duel_presentation.finished.connect(_confirm_duel)
	duel_presentation.effects = combat_effects
	ui = CampaignUI.new()
	ui.store = store
	ui.toolbar_offset = Vector2(16, 72)
	add_child(ui)
	ui.drawer.offset_top = 112
	ui.army_dispatched.connect(focus_army)
	army_choice = OptionButton.new()
	army_choice.position = Vector2(16, 208)
	army_choice.custom_minimum_size = Vector2(200, 32)
	army_choice.add_theme_font_override("font", preload("res://scripts/ui/city_ui_skin.gd").font())
	army_choice.item_selected.connect(func(index):
		if index > 0: focus_army(str(army_choice.get_item_metadata(index)))
	)
	layer.add_child(army_choice)
	army_choice.hide()
	_build_battle_feedback()
	store.campaign_changed.connect(refresh)
	store.campaign_changed.connect(_refresh_enemy_panel)
	store.city_changed.connect(func(_id):
		if not store.busy: refresh()
	)
	refresh()
	if is_instance_valid(map.hex_world): map.hex_world.cell_selected.connect(_select_global_cell)
	if store.war.state.has(StateKeys.BATTLEFIELD): _create_supply_markers()
	if store.battle_test: call_deferred("_focus_battle")

func _exit_tree() -> void:
	if is_instance_valid(store) and store.war_presentation == self:
		store.war_presentation = null
		store.time_paused = false

func _confirm_duel() -> void:
	if duel_presentation.demo: return
	var key := _duel_record_key(duel_presentation.active_record)
	for record in store.war.state.get(StateKeys.DUELS, {}).get("records", []):
		if _duel_record_key(record) == key:
			record["presentation_pending"] = false
			record["presentation_confirmed"] = true
	# Persist at the normal campaign boundary; closing a notice must not serialize the world.
