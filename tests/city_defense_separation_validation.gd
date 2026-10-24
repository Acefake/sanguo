extends SceneTree

# 城防设施 / 城内驻军分离验证：
# ① 未破城：攻方强攻只磨损城墙/城门，驻军不受任何外部攻击；
# ② 骑兵不能破墙门（也不出器械伤害）；
# ③ 城门或城墙至少一处破口后通道才开放，骑兵可经破口入城；
# ④ wall<=0 不直接占领、不瞬间击杀；只有部队真正入城才发生巷战与占领；
# ⑤ 守军出城即野战目标，可以受伤；
# ⑥ 城内目标不会被外部近战/远射打到（tactical 射击路径封死）；
# ⑦ 旧存档缺字段可迁移，破口状态与占领条件跨读档连续；
# ⑧ 全流程兵员账本守恒。

const Fort = preload("res://scripts/war/battle/city_fortifications.gd")
const Defense = preload("res://scripts/war/battle/city_defense.gd")
const Combat = preload("res://scripts/war/battle/combat_system.gd")
const T = preload("res://scripts/war/battle/tactical_battlefield.gd")
const Roles = preload("res://scripts/war/battle/troop_roles.gd")
const Fields = preload("res://scripts/war/campaign/campaign_battlefields.gd")
var failures: Array[String] = []

func _initialize() -> void: call_deferred("run")
func check(value: bool, message: String) -> void:
	if not value: failures.append(message); push_error(message)

func total_troops(store) -> int:
	var total := 0
	for city in store.scenario["places"].values():
		total += int(city.get("garrison", 0)) + int(city.get("wounded", 0)) + int(city.get("war_dead", 0)) + int(city.get("prisoners", 0))
	for army in store.war.state["armies"].values():
		total += int(army.get("dead", 0)) + int(army.get("captured", 0))
		if army["status"] != "ended": total += Combat.strength(army) + int(army.get("wounded", 0))
	return total

func attacker_corps(war) -> Dictionary:
	for corps in war.state["corps"].values():
		if corps["faction"] == "yuan_shao": return corps
	return {}

func siege_of(war, node: String) -> Dictionary:
	return war.state.get("sieges", {}).get(node, {})

func legal_cells(war, board: Dictionary, faction: String, ring_min: int, ring_max: int, node: String) -> Array:
	var legal := Fort.movement_board(war, board, faction)
	var options: Array = []
	for q in range(int(board["min_column"]), int(board["max_column"]) + 1):
		for r in range(int(board["min_row"]), int(board["max_row"]) + 1):
			var cell := T.cell_at(q, r)
			var gap := Fort.distance_to_wall(board, node, cell)
			if gap < ring_min or gap > ring_max: continue
			if T.in_battlefield(legal, cell): options.append(cell)
	var center := int(Fort.for_city(war.store, node)["center"])
	options.sort_custom(func(a, b): return T.cell_distance(a, center) < T.cell_distance(b, center) if T.cell_distance(a, center) != T.cell_distance(b, center) else a < b)
	return options

func place_siege(war, board: Dictionary, node: String) -> void:
	var ring1 := legal_cells(war, board, "yuan_shao", 1, 1, node)
	var ring2 := legal_cells(war, board, "yuan_shao", 2, 2, node)
	var used := {}
	for army in war.active_armies("yuan_shao"):
		var pool: Array = ring2 if Roles.kind(army) == "archers" else ring1
		var cell := -1
		for option in pool:
			if not used.has(int(option)): cell = int(option); break
		if cell < 0:
			for option in ring2:
				if not used.has(int(option)): cell = int(option); break
		if cell < 0: continue
		used[cell] = true
		army["tactical"]["cell"] = cell
		army["tactical"]["lane"] = T.column_of(cell)
		army["action"] = {"type": "continue"}
	check(not war.active_armies("yuan_shao").is_empty(), "attackers missing from scenario")

func prepare(store, seed: int = 42) -> void:
	store.persist_enabled = false
	store.agent.enabled = false
	store.prepare_battle_test(false, "siege_assault", seed)
	var war = store.war
	attacker_corps(war)["siege_approach"] = true
	attacker_corps(war)["siege_mode"] = "assault"
	attacker_corps(war)["autonomous_deployment"] = false
	store.city_state("xiaopei")["grain"] = 18000
	place_siege(war, store.war.state["battlefield"], "xiaopei")

func resolve_day(war) -> void:
	war.state["tick"] = int(war.state["tick"]) + 1
	war._resolve_sieges()

func make_sortie(war, board: Dictionary) -> Dictionary:
	# 出城守军：优先走真实动员流程；动员条件不满足时用同构部队代替。
	var officer_id := ""
	var available: Array = war.available_officers("liu_bei")
	if not available.is_empty(): officer_id = str(available[0]["id"])
	var preview: Dictionary = {}
	if officer_id != "": preview = war.preview_dispatch("xiaopei", "xiaopei", officer_id, true)
	if not preview.get("ok", false):
		officer_id = war.roster.militia("liu_bei", "xiaopei:sortie")
		preview = war.preview_dispatch("xiaopei", "xiaopei", officer_id, true)
	var sortie: Dictionary
	if preview.get("ok", false):
		sortie = war._mobilize(preview)
		Fields.join(war, board, sortie)
	else:
		sortie = war.active_armies("yuan_shao")[0].duplicate(true)
		sortie["id"] = "sortie-fixture"
		sortie["officer_id"] = officer_id
		sortie["name"] = "出城守军"
		sortie["faction"] = "liu_bei"
		sortie["home"] = "xiaopei"
		sortie["target"] = "xiaopei"
		sortie["mission_type"] = "defend"
		sortie["status"] = "active"
		sortie["returning"] = false
		sortie["units"] = {"infantry": 800, "archers": 200, "cavalry": 0}
		sortie["initial_strength"] = 1000
		sortie["dead"] = 0
		sortie["wounded"] = 0
		sortie["captured"] = 0
		sortie["deposited"] = 0
		sortie["location"] = {"node": "xiaopei", "edge": "", "progress": 0.0}
		sortie.erase("corps_id")
		sortie.erase("corps_task")
		sortie.erase("battle_ai")
		sortie["intel"] = {"cities": {}, "enemies": {}}
		sortie["battlefield_id"] = board["battle_id"]
		sortie["tactical"] = {"cell": -1, "role": "main_attack", "commander": "sortie-fixture", "support_id": "", "attack_target": "", "phase": "出城", "plan_until": 0, "blocked": false, "blocked_days": 0, "lane": 0, "withdraw_preparation": 0}
		sortie["action"] = {"type": "engage"}
		war.state["armies"][sortie["id"]] = sortie
	return sortie

func run() -> void:
	var store = root.get_node("GameState")

	# ---------- ① 未破城驻军无伤、设施独立耐久 ----------
	prepare(store)
	var war = store.war
	var board: Dictionary = war.state["battlefield"]
	var city: Dictionary = store.city_state("xiaopei")
	var initial := total_troops(store)
	var garrison_before := int(city["garrison"])
	var units_before: Dictionary = city["units"].duplicate(true)
	resolve_day(war)
	var siege: Dictionary = war.state["sieges"]["xiaopei"]
	check(siege["phase"] == "准备", "siege should start in preparation")
	check(float(siege["wall"]) == float(siege["wall_max"]) and float(siege["gate"]) == float(siege["gate_max"]), "facilities damaged during preparation")
	check(float(siege["gate_max"]) > 0.0 and float(siege["gate_max"]) < float(siege["wall_max"]), "gate durability is not an independent smaller segment")
	check(int(city["garrison"]) == garrison_before and city["units"] == units_before, "garrison changed during preparation")
	var saw_assault := false
	for day in range(20):
		resolve_day(war)
		if siege["phase"] == "强攻": saw_assault = true; break
	check(saw_assault, "assault phase never started with infantry and engines at the wall")
	check(float(siege["wall"]) < float(siege["wall_max"]) or float(siege["gate"]) < float(siege["gate_max"]), "facilities took no damage during assault")
	var breached_first := Defense.breach_open(war, "xiaopei")
	if not breached_first:
		for day in range(40):
			resolve_day(war)
			check(int(city["garrison"]) == garrison_before, "garrison damaged by wall assault before breach")
			if Defense.breach_open(war, "xiaopei"): breached_first = true; break
	check(breached_first, "wall or gate never broke")
	check(float(siege["wall"]) <= 0.0 or float(siege["gate"]) <= 0.0, "breach opened without a broken facility")
	check(int(city["garrison"]) == garrison_before, "garrison took damage merely from the breach")
	var breach := Defense.breach_cell(war, "xiaopei")
	var site := Fort.for_city(store, "xiaopei")
	check(breach >= 0, "breach cell not defined")
	check(breach == int(site["gate"]) or site["cells"].has(breach), "breach cell is not part of the existing site geometry")
	var blocked := Fort.blocked_for(war, board, "yuan_shao")
	check(not blocked.has(breach), "breach cell still blocks movement")
	var footprint_blocked := 0
	for value in site["cells"]:
		if blocked.has(int(value)): footprint_blocked += 1
	check(footprint_blocked > 0, "the rest of the wall footprint no longer blocks movement")
	check(T.can_enter(war, war.active_armies("yuan_shao")[0], breach), "attackers cannot enter through the open breach")
	var cavalry_units: Array = war.active_armies("yuan_shao").filter(func(unit): return Roles.kind(unit) == "cavalry")
	for troop in cavalry_units: check(T.can_enter(war, troop, breach), "cavalry cannot enter through the breach")
	# 破口已开但无人入城：wall<=0 不能直接占领，也不能瞬间击杀
	for day in range(6): resolve_day(war)
	check(city["faction"] == "liu_bei", "city captured without any attacker entering")
	check(siege["phase"] != "occupied" and str(siege.get("capture_reason", "")) == "", "siege marked occupied without entry")
	check(int(city["garrison"]) == garrison_before, "garrison damaged with breach open but nobody inside")
	check(total_troops(store) == initial, "ledger broke during the pre-breach phase")

	# ---------- ② 骑兵不能破墙门（设施判定 + 纯骑兵围城） ----------
	var synthetic: Dictionary = Defense.create(war, "xiaopei", war.active_armies("yuan_shao")[0])
	synthetic["wall"] = 100.0
	synthetic["gate"] = 50.0
	var army_shape := {"training": 70, "equipment": 70, "morale": 100.0, "organization": 100.0, "fatigue": 0.0, "skills": {}, "status": "active"}
	var foot := army_shape.duplicate(true)
	foot["units"] = {"infantry": 8000, "archers": 0, "cavalry": 0}
	foot["siege_engines"] = 0
	var foot_result := Defense.damage_facilities(war, "xiaopei", synthetic, [foot])
	check(float(foot_result["wall_damage"]) > 0.0 and float(foot_result["gate_damage"]) == 0.0, "infantry should only damage the wall")
	check(float(synthetic["gate"]) == 50.0, "infantry damaged the gate")
	var riders := army_shape.duplicate(true)
	riders["units"] = {"infantry": 0, "archers": 0, "cavalry": 8000}
	riders["siege_engines"] = 4
	check(float(Defense.facility_power(war, [riders])["total"]) == 0.0, "cavalry damaged facilities")
	check(not Roles.can_breach(riders), "cavalry reported as able to breach")
	check(Roles.breach_multiplier([riders]) == 1.0, "cavalry engines counted into breach power")
	store.prepare_battle_test(false, "siege_assault", 42)
	war = store.war
	board = war.state["battlefield"]
	city = store.city_state("xiaopei")
	garrison_before = int(city["garrison"])
	for army in war.active_armies("yuan_shao"):
		var total: int = Combat.strength(army)
		army["units"] = {"infantry": 0, "archers": 0, "cavalry": total}
		army["siege_engines"] = 0
	place_siege(war, board, "xiaopei")
	attacker_corps(war)["siege_approach"] = true
	attacker_corps(war)["siege_mode"] = "assault"
	var initial_riders := total_troops(store)
	for day in range(4): resolve_day(war)
	siege = war.state["sieges"]["xiaopei"]
	siege["preparation"] = 100.0
	for day in range(6): resolve_day(war)
	check(float(siege["wall"]) == float(siege["wall_max"]) and float(siege["gate"]) == float(siege["gate_max"]), "cavalry damaged the wall or gate")
	check(not Defense.breach_open(war, "xiaopei"), "cavalry opened a breach")
	check(int(city["garrison"]) == garrison_before, "cavalry hurt the garrison before any breach")
	check(total_troops(store) == initial_riders, "ledger broke during the cavalry probe")

	# ---------- ③④ 破口入城后战斗与占领 ----------
	store.prepare_battle_test(false, "siege_assault", 42)
	war = store.war
	board = war.state["battlefield"]
	city = store.city_state("xiaopei")
	place_siege(war, board, "xiaopei")
	attacker_corps(war)["siege_approach"] = true
	attacker_corps(war)["siege_mode"] = "assault"
	# 直接按既有 site.gate 破门（不使用虚构几何）
	war.state["sieges"]["xiaopei"] = Defense.create(war, "xiaopei", war.active_armies("yuan_shao")[0])
	Fort.breach(war, "xiaopei", [])
	check(Defense.breach_open(war, "xiaopei"), "forced gate breach did not open the passage")
	var breach2 := Defense.breach_cell(war, "xiaopei")
	check(breach2 == int(Fort.for_city(store, "xiaopei")["gate"]), "gate breach did not use site.gate")
	var mover: Dictionary = war.active_armies("yuan_shao").filter(func(unit): return int(unit["units"].get("infantry", 0)) > 0)[0]
	var spot := -1
	for cell in legal_cells(war, board, "yuan_shao", 1, 1, "xiaopei"):
		if T.cell_distance(int(cell), breach2) == 1: spot = int(cell); break
	check(spot >= 0, "no legal approach cell next to the breach")
	mover["tactical"]["cell"] = spot
	mover["action"] = {"type": "continue"}
	T.move(war)
	check(int(mover["tactical"]["cell"]) == breach2, "infantry could not march into the breach through real movement")
	check(Fort.inside_city(board, int(mover["tactical"]["cell"])) == "xiaopei", "entered unit is not inside the city footprint")
	check(Defense.inside_attackers(war, "xiaopei", board).size() == 1, "entered unit not registered as inside")
	var garrison_mid := int(city["garrison"])
	resolve_day(war)
	check(Defense.breach_open(war, "xiaopei"), "breach state lost after the first street fight")
	check(int(city["garrison"]) < garrison_mid, "interior combat did not damage the garrison")
	check(bool(siege_of(war, "xiaopei").get("interior_combat", false)), "interior combat not recorded on the siege")
	# 压缩守军规模，保证狭窄破口的巷战在预算内完成占领（fixture 调整）
	city["garrison"] = 600
	city["units"] = {"infantry": 420, "archers": 180, "cavalry": 0}
	var ledger_entry := total_troops(store)
	var captured := false
	var inside_at_capture := false
	var capture_reason := ""
	for day in range(80):
		T.move(war)
		inside_at_capture = Defense.inside_attackers(war, "xiaopei", board).size() > 0
		resolve_day(war)
		if city["faction"] == "yuan_shao":
			captured = true
			capture_reason = str(siege_of(war, "xiaopei").get("capture_reason", ""))
			break
	check(captured, "breach entry never led to capture within the budget")
	check(inside_at_capture, "city captured without any attacker inside")
	check(capture_reason in ["破城攻取", "守军崩溃投降"], "capture without an interior fight: " + capture_reason)
	check(str(siege_of(war, "xiaopei").get("phase", "")) == "occupied", "capture did not mark the siege occupied")
	check(total_troops(store) == ledger_entry, "ledger broke during capture")

	# ---------- ⑤ 守军出城可伤 + ⑥ 城内目标射击路径封死 ----------
	store.prepare_battle_test(false, "siege_assault", 42)
	war = store.war
	board = war.state["battlefield"]
	city = store.city_state("xiaopei")
	var wall_guard: Dictionary = war.active_armies("yuan_shao")[0]
	for army in war.active_armies("yuan_shao"):
		if army["id"] != wall_guard["id"]: army["status"] = "ended"
	var sortie: Dictionary = make_sortie(war, board)
	var outside: Array = legal_cells(war, board, "liu_bei", 1, 3, "xiaopei")
	var pair_a := -1
	var pair_b := -1
	for candidate in outside:
		for neighbor in T.neighbors(int(candidate)):
			if not T.in_battlefield(Fort.movement_board(war, board, "yuan_shao"), int(neighbor)): continue
			if Fort.distance_to_wall(board, "xiaopei", int(neighbor)) < 1: continue
			if T.cell_distance(int(candidate), int(neighbor)) != 1: continue
			pair_a = int(candidate); pair_b = int(neighbor); break
		if pair_a >= 0: break
	check(pair_a >= 0 and pair_b >= 0, "no adjacent outside pair for the sortie probe")
	wall_guard["tactical"]["cell"] = pair_b
	wall_guard["action"] = {"type": "engage", "enemy": sortie["id"]}
	sortie["tactical"]["cell"] = pair_a
	sortie["action"] = {"type": "engage", "enemy": wall_guard["id"]}
	T._fresh_sightings(war)
	check(not T.shield_between(war, sortie, wall_guard), "two outside units should not be shielded")
	var sortie_before := Combat.strength(sortie)
	T.resolve(war)
	check(Combat.strength(sortie) < sortie_before, "sortie outside the walls took no damage")
	var ledger_sortie := total_troops(store)
	# 把一支部队放进破口：城内外互相打不到
	war.state["sieges"]["xiaopei"] = Defense.create(war, "xiaopei", wall_guard)
	Fort.breach(war, "xiaopei", [])
	var breach3 := Defense.breach_cell(war, "xiaopei")
	check(breach3 >= 0, "forced breach has no cell")
	wall_guard["tactical"]["cell"] = breach3
	sortie["tactical"]["cell"] = pair_a
	sortie["action"] = {"type": "engage", "enemy": wall_guard["id"]}
	wall_guard["action"] = {"type": "engage", "enemy": sortie["id"]}
	check(T.shield_between(war, sortie, wall_guard), "inside/outside pair is not shielded")
	T._fresh_sightings(war)
	check(not T.targets(war, sortie).has(wall_guard), "outside unit still targets an inside unit")
	var inside_before := Combat.strength(wall_guard)
	var outside_before := Combat.strength(sortie)
	T.resolve(war)
	check(Combat.strength(wall_guard) == inside_before and Combat.strength(sortie) == outside_before, "attack crossed the city boundary")
	# 守军进城（走破口）后同处城内即可交战
	var pocket := -1
	for value in Fort.for_city(store, "xiaopei")["cells"]:
		var cell := int(value)
		if cell != breach3 and T.can_enter(war, sortie, cell): pocket = cell; break
	check(pocket >= 0, "no second inside cell available for the street fight probe")
	if pocket >= 0:
		sortie["tactical"]["cell"] = pocket
		check(not T.shield_between(war, sortie, wall_guard), "two inside units should not be shielded")
		T._fresh_sightings(war)
		var joined_before := Combat.strength(wall_guard) + Combat.strength(sortie)
		T.resolve(war)
		check(Combat.strength(wall_guard) + Combat.strength(sortie) < joined_before, "street fight inside the city deals no damage")
	check(total_troops(store) == ledger_sortie, "ledger broke during the shield probes")

	# ---------- ⑦ 旧存档兼容 + 破口状态/占领条件读档连续 ----------
	store.prepare_battle_test(false, "siege_assault", 42)
	war = store.war
	board = war.state["battlefield"]
	place_siege(war, board, "xiaopei")
	attacker_corps(war)["siege_approach"] = true
	attacker_corps(war)["siege_mode"] = "assault"
	attacker_corps(war)["autonomous_deployment"] = false
	var legacy := Defense.create(war, "xiaopei", war.active_armies("yuan_shao")[0])
	legacy["wall"] = 0.0
	legacy.erase("gate")
	legacy.erase("gate_max")
	legacy.erase("breach_open")
	legacy.erase("breach_cell")
	legacy.erase("wall_breached")
	legacy.erase("gate_breached")
	war.state["sieges"]["xiaopei"] = legacy
	var saved_legacy: Dictionary = JSON.parse_string(JSON.stringify(war.export_state()))
	war.setup(store, saved_legacy)
	war.state["tick"] = int(war.state["tick"]) + 1
	war._resolve_sieges()
	var migrated: Dictionary = war.state["sieges"]["xiaopei"]
	check(bool(migrated.get("breach_open", false)), "legacy save did not reopen the breach")
	check(int(migrated.get("breach_cell", -1)) == int(Fort.for_city(store, "xiaopei")["gate"]), "legacy breach did not use the existing gate cell")
	check(float(migrated.get("gate_max", 0.0)) > 0.0, "legacy save lost independent gate durability")
	check(not Fort.blocked_for(war, war.state["battlefield"], "yuan_shao").has(int(migrated["breach_cell"])), "legacy breach still blocks movement")
	# 进行中的破口 + 入城状态读档连续，占领仍然要求真正入城
	store.prepare_battle_test(false, "siege_assault", 42)
	war = store.war
	board = war.state["battlefield"]
	city = store.city_state("xiaopei")
	place_siege(war, board, "xiaopei")
	attacker_corps(war)["siege_approach"] = true
	attacker_corps(war)["siege_mode"] = "assault"
	war.state["sieges"]["xiaopei"] = Defense.create(war, "xiaopei", war.active_armies("yuan_shao")[0])
	Fort.breach(war, "xiaopei", [])
	city["garrison"] = 600
	city["units"] = {"infantry": 420, "archers": 180, "cavalry": 0}
	var mover2: Dictionary = war.active_armies("yuan_shao").filter(func(unit): return int(unit["units"].get("infantry", 0)) > 0)[0]
	mover2["tactical"]["cell"] = Defense.breach_cell(war, "xiaopei")
	resolve_day(war)
	var inside_reload := Defense.inside_attackers(war, "xiaopei", board).size()
	check(inside_reload > 0, "no inside unit before the reload")
	var saved_live: Dictionary = JSON.parse_string(JSON.stringify(war.export_state()))
	war.setup(store, saved_live)
	var reloaded: Dictionary = war.state["sieges"]["xiaopei"]
	check(bool(reloaded.get("breach_open", false)) and int(reloaded.get("breach_cell", -1)) >= 0, "reload lost the breach state")
	check(int(reloaded.get("wall_max", 0)) > 0 and reloaded.has("gate") and reloaded.has("gate_max"), "reload lost facility durability")
	check(Defense.inside_attackers(war, "xiaopei", war.state["battlefield"]).size() == inside_reload, "reload lost entered units")
	var reload_capture := false
	for day in range(80):
		T.move(war)
		resolve_day(war)
		if store.city_state("xiaopei")["faction"] == "yuan_shao": reload_capture = true; break
	check(reload_capture, "capture did not continue after reload")

	print("CITY_DEFENSE_SEPARATION_OK" if failures.is_empty() else "CITY_DEFENSE_SEPARATION_FAILED: " + str(failures))
	quit(0 if failures.is_empty() else 1)
