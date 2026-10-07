extends Control

const UISkin = preload("res://scripts/war/war_ui_skin.gd")
var faction_choice: OptionButton

func _ready() -> void:
	var store := get_node("/root/GameState")
	# Explicit battle CLI arguments still support captures and automated validation.
	if store.battle_test:
		get_tree().change_scene_to_file.call_deferred("res://scenes/rtk14_world_3d.tscn")
		return
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var background := ColorRect.new()
	background.color = Color("17272a")
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(background)
	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	panel.position = Vector2(-270, -210)
	panel.custom_minimum_size = Vector2(540, 420)
	panel.add_theme_stylebox_override("panel", UISkin.paper(12))
	add_child(panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 16)
	panel.add_child(column)
	column.add_child(UISkin.label("三国 · 城市与战争", 28))
	column.add_child(UISkin.label("主公派遣军团，将领自主行军、作战与攻城。", 16))
	column.add_child(UISkin.button("继续当前战役", func():
		store.war.start_campaign()
		store._save()
		get_tree().change_scene_to_file("res://scenes/rtk14_world_3d.tscn")
	, true))
	faction_choice = OptionButton.new()
	for faction in store.scenario["factions"]:
		faction_choice.add_item(str(store.scenario["factions"][faction]["name"]))
		faction_choice.set_item_metadata(faction_choice.item_count - 1, faction)
		if faction == store.war.state["player_faction"]: faction_choice.select(faction_choice.item_count - 1)
	column.add_child(faction_choice)
	column.add_child(UISkin.button("以所选势力开始新战役", func():
		if store.agent != null: store.agent.cancel_pending()
		store.war.generation += 1
		store._load_demo()
		store.year = 191
		store.month = 9
		store.day = 1
		store.action_points = 3
		store.chronicles.clear()
		store.war.set_player_faction(str(faction_choice.get_item_metadata(faction_choice.selected)))
		store.war.start_campaign()
		store._save()
		get_tree().change_scene_to_file("res://scenes/rtk14_world_3d.tscn")
	))
	column.add_child(UISkin.button("进入独立战场验证", func(): store.open_battle_scenarios(false)))
