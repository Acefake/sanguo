extends Node

signal city_changed(city_id: String)
signal month_changed
signal campaign_changed
signal campaign_progress

const WarCampaign = preload("res://scripts/war/campaign_state.gd")
const AgentAdapter = preload("res://scripts/agents/agent_adapter.gd")

const DEMO_PATH := "res://data/scenario_world_demo.json"
const SAVE_PATH := "user://city_campaign.json"
const ACTIONS := {
	"govern": {"title": "安民治政", "category": "政务", "description": "金 -200  民心 +8", "money": 200, "grain": 0},
	"develop": {"title": "开垦田土", "category": "政务", "description": "金 -300  经济 +4  粮草 +800", "money": 300, "grain": 0},
	"tax": {"title": "征收赋税", "category": "政务", "description": "民心 -6  金 +600", "money": 0, "grain": 0},
	"recruit": {"title": "征募兵员", "category": "军事", "description": "金 -250  粮草 -1500  兵力 +1000", "money": 250, "grain": 1500},
	"train": {"title": "操练兵马", "category": "军事", "description": "金 -180  粮草 -800  训练 +7", "money": 180, "grain": 800},
	"fortify": {"title": "修筑城防", "category": "军事", "description": "金 -350  城防 +5", "money": 350, "grain": 0},
	"buy_grain": {"title": "购入粮草", "category": "市场", "description": "金 -300  粮草 +3000", "money": 300, "grain": 0},
	"sell_grain": {"title": "出售余粮", "category": "市场", "description": "粮草 -3000  金 +240", "money": 0, "grain": 3000},
	"forge": {"title": "锻造兵装", "category": "工坊", "description": "金 -400  军备 +6", "money": 400, "grain": 0},
	"visit": {"title": "访察民情", "category": "酒肆", "description": "金 -120  民心 +5", "money": 120, "grain": 0}
}

var scenario: Dictionary = {}
var year := 191
var month := 9
var action_points := 3
var persist_enabled := true
var save_path := SAVE_PATH
var chronicles: Array = []
var day := 1
var busy := false
var war = WarCampaign.new()
var agent: Node
var pending_map_origin := ""
var war_presentation: Node
var time_scale := 1.0
var time_paused := false
var time_phase := "strategy"
var turn_days_done := 0
var turn_days_total := 0
var settings_menu: CanvasLayer
var battle_test := false
var battle_offsets: Dictionary = {}
var battle_snapshot: Dictionary = {}
var battle_picker: CanvasLayer
var city_aliases: Dictionary = {}

func start_battle_test(scenario_id: String = "plains_clash", seed: int = 1910901) -> void:
	if busy: return
	if preload("res://scripts/war/battle_scenarios.gd").definition(scenario_id).is_empty(): return
	prepare_battle_test(true, scenario_id, seed)
	if agent.enabled: war.Corps.plan_background(war, agent)
	if is_instance_valid(settings_menu): settings_menu.window.hide()
	get_tree().change_scene_to_file("res://scenes/rtk14_world_3d.tscn")

func prepare_battle_test(preformed: bool = false, scenario_id: String = "plains_clash", seed: int = 1910901) -> void:
	if preload("res://scripts/war/battle_scenarios.gd").definition(scenario_id).is_empty(): return
	if not battle_test:
		_save()
		battle_snapshot = {"scenario": scenario.duplicate(true), "war": war.export_state(), "year": year, "month": month, "day": day, "action_points": action_points, "chronicles": chronicles.duplicate(true), "persist": persist_enabled}
	battle_test = true
	if not battle_snapshot.has("time_phase"):
		battle_snapshot["time_phase"] = time_phase
		battle_snapshot["urgent"] = war.urgent_event
	persist_enabled = false
	battle_offsets.clear()
	preload("res://scripts/war/battle_scenarios.gd").setup(self, scenario_id, seed, preformed)
	time_phase = "strategy"
	turn_days_done = 0
	turn_days_total = 0

func open_battle_scenarios(from_startup: bool = false) -> void:
	if not is_instance_valid(battle_picker):
		battle_picker = preload("res://scripts/war/battle_scenario_picker.gd").new()
		add_child(battle_picker)
	battle_picker.open(from_startup)

func leave_battle_test() -> void:
	if busy or not battle_test: return
	restore_battle_test()
	if is_instance_valid(settings_menu): settings_menu.window.hide()
	get_tree().change_scene_to_file("res://scenes/rtk14_world_3d.tscn")

func restore_battle_test() -> void:
	if not battle_test: return
	_load_demo()
	scenario = battle_snapshot["scenario"]
	war.setup(self, battle_snapshot["war"])
	year = battle_snapshot["year"]
	month = battle_snapshot["month"]
	day = battle_snapshot["day"]
	action_points = battle_snapshot["action_points"]
	chronicles = battle_snapshot["chronicles"]
	persist_enabled = battle_snapshot["persist"]
	time_phase = battle_snapshot["time_phase"]
	war.urgent_event = battle_snapshot["urgent"]
	battle_test = false
	battle_offsets.clear()
	battle_snapshot.clear()

func open_settings() -> void:
	if not is_instance_valid(settings_menu):
		settings_menu = preload("res://scripts/game_settings.gd").new()
		add_child(settings_menu)
	settings_menu.open()

func toggle_time_pause() -> void:
	if not busy: return
	time_paused = not time_paused
	campaign_progress.emit()

func advance_turn() -> String:
	if busy: return "当前正在推进。"
	turn_days_done = 0
	turn_days_total = 10
	_begin_advance()
	var result := ""
	for index in range(turn_days_total):
		while time_paused:
			await get_tree().process_frame
		result = await _advance_one_day()
		turn_days_done += 1
		campaign_progress.emit()
		if war.urgent_event: break
	time_phase = "report"
	_finish_advance()
	return result


# Publishes the shared interface theme on the scene tree root. Every panel used
# to build its own Theme.new(), and native controls inherited nothing, so
# CheckButton / HSlider / AcceptDialog and friends rendered with Godot defaults.
func _install_theme() -> void:
	# get_tree() raises rather than returning null when the node is detached,
	# which happens in the headless validation scripts.
	if not is_inside_tree():
		return
	var root := get_tree().root
	if root.theme == null or not root.theme.has_stylebox("panel", "AcceptDialog"):
		root.theme = preload("res://scripts/city_ui_skin.gd").build_theme()


func _ready() -> void:
	_install_theme()
	_load_demo()
	_load_save()
	agent = AgentAdapter.new()
	add_child(agent)
	agent.load_settings()
	if "--xiaopei-battle" in OS.get_cmdline_user_args(): prepare_battle_test()
	var battle_seed := 1910901
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--battle-seed="): battle_seed = arg.trim_prefix("--battle-seed=").to_int()
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--battle-scenario="): prepare_battle_test(false, arg.trim_prefix("--battle-scenario="), battle_seed)


func _load_demo() -> void:
	var file := FileAccess.open(DEMO_PATH, FileAccess.READ)
	if file == null:
		push_error("无法读取演示剧本：" + DEMO_PATH)
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if parsed is Dictionary:
		scenario = parsed
		var positions: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://data/war/world_3d_positions.json"))
		city_aliases = positions.get("city_aliases", {}) if positions is Dictionary else {}
		for state in scenario.get("places", {}).values():
			if state is Dictionary and state.has("population") and not state.has("equipment"):
				state["equipment"] = 50
		war.setup(self)
	else:
		push_error("演示剧本不是有效的 JSON 对象")


func _load_save() -> void:
	if not FileAccess.file_exists(save_path):
		return
	var file := FileAccess.open(save_path, FileAccess.READ)
	if file == null:
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if not parsed is Dictionary or int(parsed.get("version", 0)) not in [1, 2, 3]:
		return
	var saved_places: Dictionary = parsed.get("places", {})
	var base_places: Dictionary = scenario.get("places", {})
	for city_id in base_places:
		if not saved_places.has(city_id) or not saved_places[city_id] is Dictionary:
			continue
		var merged: Dictionary = base_places[city_id].duplicate(true)
		for key in saved_places[city_id]:
			merged[key] = saved_places[city_id][key]
		base_places[city_id] = merged
	year = int(parsed.get("year", year))
	month = clampi(int(parsed.get("month", month)), 1, 12)
	day = clampi(int(parsed.get("day", 1)), 1, 30)
	action_points = clampi(int(parsed.get("action_points", action_points)), 0, 3)
	var saved_chronicles: Variant = parsed.get("chronicles", [])
	if saved_chronicles is Array:
		chronicles = saved_chronicles.slice(-40)
	war.generation += 1
	if agent != null:
		agent.cancel_pending()
	war = WarCampaign.new()
	war.setup(self, parsed.get("war", {}) if parsed.get("war", {}) is Dictionary else {})


func _save() -> void:
	if not persist_enabled:
		return
	var pending_path: String = save_path + ".pending"
	var file := FileAccess.open(pending_path, FileAccess.WRITE)
	if file == null:
		push_warning("无法保存城池进度")
		return
	var payload := {
		"version": 3,
		"year": year,
		"month": month,
		"day": day,
		"action_points": action_points,
		"places": scenario.get("places", {}),
		"chronicles": chronicles,
		"war": war.export_state()
	}
	file.store_string(JSON.stringify(payload, "\t"))
	file.flush()
	file.close()
	if DirAccess.rename_absolute(ProjectSettings.globalize_path(pending_path), ProjectSettings.globalize_path(save_path)) != OK:
		push_warning("无法替换进度文件，原存档已保留。")


func city_state(city_id: String) -> Dictionary:
	return scenario.get("places", {}).get(canonical_city_id(city_id), {})

func canonical_city_id(city_id: String) -> String:
	if scenario.get("places", {}).has(city_id): return city_id
	var resolved := str(city_aliases.get(city_id, ""))
	return resolved if scenario.get("places", {}).has(resolved) else ""


func faction_for(city_id: String) -> Dictionary:
	var state := city_state(city_id)
	return scenario.get("factions", {}).get(str(state.get("faction", "")), {})


func action_error(city_id: String, action_id: String) -> String:
	if busy:
		return "日期正在推进，请稍候"
	if not war.player_has_city_access(city_id):
		return "无法在敌方城池执行城务命令"
	return faction_action_error(city_id, action_id, str(war.state["player_faction"]))

func faction_action_error(city_id: String, action_id: String, faction: String) -> String:
	if war.campaign_finished(): return "战役已经结束，请开始新的战役"
	if faction == "" or str(city_state(city_id).get("faction", "")) != faction:
		return "只能在本方城池执行城务命令"
	if not ACTIONS.has(action_id):
		return "未知命令"
	var state := city_state(city_id)
	if state.is_empty() or not state.has("population"):
		return "这里不能执行城内命令"
	var siege: Dictionary = war.state.get("sieges", {}).get(canonical_city_id(city_id), {})
	if int(siege.get("active_tick", -100)) >= int(war.state["tick"]) - 1 and siege.get("phase", "") not in ["occupied", "解围"] and action_id in ["recruit", "fortify"]:
		return "围城期间无法征募或修筑城防"
	if faction_action_points(faction) <= 0:
		return "本月行动力已用尽"
	var action: Dictionary = ACTIONS[action_id]
	if int(state.get("treasury", 0)) < int(action["money"]):
		return "金不足"
	if int(state.get("grain", 0)) < int(action["grain"]):
		return "粮草不足"
	if action_id == "govern" and int(state.get("order", 0)) >= 100:
		return "民心已达到上限"
	if action_id == "develop" and int(state.get("economy", 0)) >= 100:
		return "经济已达到上限"
	if action_id == "tax" and int(state.get("order", 0)) < 10:
		return "民心过低，不能征税"
	if action_id == "recruit" and int(state.get("population", 0)) < 3000:
		return "人口不足，无法征募"
	if action_id == "train" and int(state.get("training", 0)) >= 100:
		return "训练已达到上限"
	if action_id == "fortify" and int(state.get("defense", 0)) >= 100:
		return "城防已达到上限"
	if action_id == "forge" and int(state.get("equipment", 50)) >= 100:
		return "军备已达到上限"
	if action_id == "visit" and int(state.get("order", 0)) >= 100:
		return "民心已达到上限"
	return ""

func faction_action_points(faction: String) -> int:
	return action_points if faction == str(war.state["player_faction"]) else int(war.state.get("faction_action_points", {}).get(faction, 3))

# AI and player use the same costs, limits and effects. AI execution stays internal
# so the public city command never grants authority over another faction.
func apply_faction_action(city_id: String, action_id: String, faction: String) -> Dictionary:
	var error := faction_action_error(city_id, action_id, faction)
	if error != "": return {"ok": false, "message": error}
	_apply_effects(city_state(city_id), action_id)
	if action_id == "fortify":
		var siege: Dictionary = war.state["sieges"].get(canonical_city_id(city_id), {})
		if not siege.is_empty():
			siege["wall"] = minf(float(siege["wall_max"]), float(siege["wall"]) + 20.0)
			if int(city_state(city_id)["defense"]) >= 30: siege.erase("breach_cell")
	if faction == str(war.state["player_faction"]): action_points -= 1
	else: war.state["faction_action_points"][faction] = faction_action_points(faction) - 1
	_record(canonical_city_id(city_id), str(ACTIONS[action_id]["title"]))
	city_changed.emit(canonical_city_id(city_id))
	return {"ok": true, "message": "%s已执行。" % str(ACTIONS[action_id]["title"])}


func apply_action(city_id: String, action_id: String) -> Dictionary:
	var error := action_error(city_id, action_id)
	if error != "":
		return {"ok": false, "message": error}
	var result := apply_faction_action(city_id, action_id, str(war.state["player_faction"]))
	_save()
	return result


func preview_action(city_id: String, action_id: String) -> Dictionary:
	var before := city_state(city_id).duplicate(true)
	var after := before.duplicate(true)
	var error := action_error(city_id, action_id)
	if error == "":
		_apply_effects(after, action_id)
	return {"ok": error == "", "message": error, "before": before, "after": after,
		"action_points_before": action_points, "action_points_after": action_points - 1 if error == "" else action_points}


func _apply_effects(state: Dictionary, action_id: String) -> void:
	var action: Dictionary = ACTIONS[action_id]
	state["treasury"] = int(state["treasury"]) - int(action["money"])
	state["grain"] = int(state["grain"]) - int(action["grain"])
	match action_id:
		"govern":
			state["order"] = mini(100, int(state["order"]) + 8)
		"develop":
			state["economy"] = mini(100, int(state["economy"]) + 4)
			state["grain"] = int(state["grain"]) + 800
		"tax":
			state["order"] = maxi(0, int(state["order"]) - 6)
			state["treasury"] = int(state["treasury"]) + 600
		"recruit":
			state["population"] = int(state["population"]) - 1000
			state["garrison"] = int(state["garrison"]) + 1000
			war.recruit_units(state, 1000)
			state["order"] = maxi(0, int(state["order"]) - 2)
		"train":
			state["training"] = mini(100, int(state["training"]) + 7)
		"fortify":
			state["defense"] = mini(100, int(state["defense"]) + 5)
		"buy_grain":
			state["grain"] = int(state["grain"]) + 3000
		"sell_grain":
			state["treasury"] = int(state["treasury"]) + 240
		"forge":
			state["equipment"] = mini(100, int(state.get("equipment", 50)) + 6)
		"visit":
			state["order"] = mini(100, int(state["order"]) + 5)


func advance_month() -> String:
	return await advance_to_month()


func _advance_idle_month() -> String:
	var initial_month := month
	var result := ""
	for index in range(30):
		result = await _advance_one_day()
		if month != initial_month or war.urgent_event: break
	return result


func _monthly_settlement() -> void:
	month += 1
	if month > 12:
		month = 1
		year += 1
	action_points = 3
	war.state["faction_action_points"].clear()
	var states: Dictionary = scenario.get("places", {})
	for city_id in states:
		var state: Dictionary = states[city_id]
		if not state.has("population"):
			continue
		var population := int(state["population"])
		var economy := int(state["economy"])
		var order := int(state["order"])
		state["treasury"] = int(state["treasury"]) + int(population * economy / 30000.0)
		state["grain"] = maxi(0, int(state["grain"]) + int(population * economy / 4000.0))
		state["population"] = population + int(population * order / 100.0 * 0.0015)
		var recovery: int = int(ceil(int(state.get("wounded", 0)) * 0.2))
		if recovery > 0:
			war._sync_inventory(state)
			var left := recovery
			for type in war.Combat.TYPES:
				var count: int = mini(left, int(state["wounded_units"][type]))
				state["wounded_units"][type] -= count
				state["units"][type] += count
				left -= count
			state["wounded"] -= recovery - left
			state["garrison"] += recovery - left
		city_changed.emit(str(city_id))
	_record("", "诸城完成月度结算，行动力恢复")
	month_changed.emit()


func date_text() -> String:
	return "%d年%d月%d日" % [year, month, day]


func advance_day() -> String:
	if busy:
		return "日期正在推进。"
	turn_days_total = 0
	_begin_advance()
	if is_inside_tree():
		await get_tree().process_frame
	var result: String = await _advance_one_day()
	_finish_advance()
	return result


func _begin_advance() -> void:
	busy = true
	time_paused = false
	time_phase = "execution"
	campaign_progress.emit()


func _finish_advance() -> void:
	_save()
	busy = false
	time_paused = false
	if time_phase != "report": time_phase = "strategy"
	campaign_progress.emit()
	campaign_changed.emit()


func _advance_one_day() -> String:
	while is_instance_valid(war_presentation) and war_presentation.duel_active():
		await get_tree().process_frame
	if not war.state.get("campaign_result", {}).is_empty(): return str(war.state["campaign_result"]["message"])
	var before: Dictionary = {}
	if is_instance_valid(war_presentation):
		for army in war.active_armies(): before[army["id"]] = army["location"].duplicate(true)
	day += 1
	if day > 30:
		day = 1
		_monthly_settlement()
	_consume_city_food()
	campaign_progress.emit()
	await war.step(agent)
	if is_instance_valid(war_presentation):
		war_presentation.begin_day(before)
		# Finish each queued duel and its result before resuming the battle.
		while is_instance_valid(war_presentation) and (war_presentation.presenting or war_presentation.duel_active()):
			await get_tree().process_frame
	return date_text() + ("：收到重要军情。" if war.urgent_event else "：将领继续自主行动。")


func _consume_city_food() -> void:
	if not war.supply_enabled(): return
	for city in scenario.get("places", {}).values():
		if not city.has("garrison"): continue
		var consumption: float = (int(city["garrison"]) + int(city.get("wounded", 0))) * float(war.rules["grain_per_soldier_day"]) + float(city.get("grain_remainder", 0))
		city["grain"] = maxi(0, int(city.get("grain", 0)) - int(floor(consumption)))
		city["grain_remainder"] = consumption - floor(consumption)


func advance_to_month() -> String:
	if busy:
		return "日期正在推进。"
	turn_days_total = 0
	# Keep the operation locked until its single save completes. Offline policies
	# return synchronously, so explicitly yield instead of relying on their await.
	_begin_advance()
	if is_inside_tree():
		await get_tree().process_frame
	var initial_month: int = month
	var result: String = ""
	for step_index in range(30):
		result = await _advance_one_day()
		if month != initial_month or war.urgent_event:
			break
		if is_inside_tree():
			await get_tree().process_frame
	_finish_advance()
	return result


func _record(place_id: String, message: String) -> void:
	chronicles.append({"year": year, "month": month, "city_id": place_id, "message": message})
	if chronicles.size() > 40:
		chronicles.pop_front()

