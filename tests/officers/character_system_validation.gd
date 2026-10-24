extends SceneTree

const Model = preload("res://scripts/officers/character_model.gd")
const System = preload("res://scripts/officers/character_system.gd")
const Talent = preload("res://scripts/officers/talent_service.gd")
var failures: Array = []

func _initialize() -> void: call_deferred("run")

func check(ok: bool, message: String) -> void:
	if not ok: failures.append(message); push_error(message)

func run() -> void:
	var store: Node = root.get_node("GameState")
	store.persist_enabled = false
	store.agent.enabled = false
	store.battle_test = false
	store._load_demo()
	var war = store.war
	war.start_campaign()
	var system = war.characters
	var historical := str(system.states.keys()[0])
	check(system.view(historical)["attributes"]["攻坚"] == null, "布阵不能静默迁移成攻坚")
	check(system.view(historical)["dimensions"][0] == null, "缺失子属性不能生成完整五维")
	check(Model.keys().size() == 25, "新属性合同必须固定25项")
	check(System.normalize_terrain("marsh") == "wetland" and System.normalize_terrain("ford") == "river", "实际战术地形缺少专业经历映射")
	check(absf(Model.effective(120.0) - 104.3233236) < 0.00001, "超过100的能力换算不符合递减规则")
	check(system.relation(historical, "unknown").is_empty(), "未知关系不能由性格伪造")
	var before: Dictionary = war.export_state()
	var roundtrip: Dictionary = JSON.parse_string(JSON.stringify(before))
	war.setup(store, roundtrip)
	system = war.characters
	check(system.migration_audit.size() == before["characters"]["migration_audit"].size(), "读档重复迁移人物")
	check(war.state["rng_state"] == before["rng_state"], "人物迁移不能消耗战斗随机流")
	var faction := str(war.state["player_faction"])
	var cities: Array = war.Operations.cities(war, faction)
	check(not cities.is_empty(), "缺少测试城池")
	var city := str(cities[0])
	var actor := ""
	for officer in war.available_officers(faction):
		if str(war.state["officer_states"].get(officer["id"], {}).get("city", "")) == city:
			actor = str(officer["id"])
			break
	check(actor != "", "测试城池需要寻访者")
	if actor == "": quit(1); return
	store.action_points = 3
	var actor_state: Dictionary = war.state["officer_states"][actor].duplicate(true)
	store.city_state(city)["governor_id"] = actor
	var started: Dictionary = Talent.investigate(war, actor, city)
	check(started["ok"], "寻访任务未启动")
	check(store.action_points == 2, "寻访行动力扣除错误")
	check(store.city_state(city).get("governor_id", "") != actor, "寻访没有解除冲突岗位")
	check(not war.available_officers(faction).any(func(person): return person["id"] == actor), "寻访人员仍能重复出征")
	check(not Talent.investigate(war, actor, city)["ok"], "同一人物可重复寻访")
	check(not Talent.known(war, faction, "talent:" + city), "寻访完成前提前发现人物")
	war.state["tick"] += 3
	Talent.advance(war)
	var candidate := "talent:" + city
	check(Talent.known(war, faction, candidate), "完成寻访没有发现人才")
	check(war.state["officer_states"][actor] == actor_state, "寻访完成后没有恢复原状态")
	var candidate_id := Talent._local_candidate(war, city)
	check(candidate_id == candidate, "重复寻访生成重复人才")
	check(Model.validate(system.definitions[candidate]).is_empty(), "生成角色缺少严格属性配置")
	check(system.relation(candidate, actor).get("respect", 0.0) > 50.0, "实际接触没有产生关系事件")
	var candidate_view: Dictionary = system.view(candidate)
	var avg := 0.0
	for attribute in Model.GROUPS[0]: avg += float(candidate_view["attributes"][attribute]) / 5.0
	check(absf(float(candidate_view["dimensions"][0]) - avg) < 0.00001, "五维不是当前属性均值")
	check(not Talent.offer(war, candidate, city, "invented", actor)["ok"], "非法岗位被接受")
	var offer: Dictionary = Talent.offer(war, candidate, city, "", actor)
	check(offer["ok"], "待任条件未被接受")
	check(system.states[candidate]["service_status"] == "serving", "接受条件没有入仕")
	check(war.available_officers(faction).any(func(person): return person["id"] == candidate), "到任人才没有进入可任命名单")
	check(not Talent.offer(war, candidate, city, "", actor)["ok"], "已入仕人才能重复招募")
	var skill_before := float(system.view(candidate)["attributes"]["治军"])
	check(system.learn(candidate, "study1", 10, 6.0, {"治军":1.0}), "有效学习被拒绝")
	check(not system.learn(candidate, "study1", 10, 6.0, {"治军":1.0}), "重复事件能刷成长")
	check(system.learn(candidate, "study2", 10, 6.0, {"治军":1.0}), "剩余学习时间未被利用")
	check(float(system.states[candidate]["daily_hours"]["10"]) == 8.0, "每日学习超过8小时")
	check(not system.learn(candidate, "study3", 10, 1.0, {"治军":1.0}), "时间耗尽后仍可学习")
	check(not system.learn(candidate, "bad_weight", 11, 1.0, {"治军":2.0}), "非法属性分配被接受")
	system.settle_month(war, "test-period")
	var skill_after := float(system.view(candidate)["attributes"]["治军"])
	check(skill_after > skill_before, "配置完整角色没有月度成长")
	system.settle_month(war, "test-period")
	check(float(system.view(candidate)["attributes"]["治军"]) == skill_after, "同一月份重复成长")
	var revision: Dictionary = system.definitions[candidate].duplicate(true)
	revision["design_revision"] = 2
	revision["base_attributes"]["治军"] = null
	check(not system.apply_definition_revision(candidate, revision, 11)["ok"], "缺字段配置静默导入")
	var bad_type: Dictionary = system.definitions[candidate].duplicate(true)
	bad_type["base_attributes"] = []
	check(not Model.validate(bad_type).is_empty(), "非法字段类型未被拒绝")
	var extra_attribute: Dictionary = system.definitions[candidate].duplicate(true)
	extra_attribute["base_attributes"]["额外能力"] = 50
	check(not Model.validate(extra_attribute).is_empty(), "第26属性未被拒绝")
	check(system.relation(actor, candidate).is_empty(), "有向关系被自动反向复制")
	check(system.relation_event(actor, candidate, "rescue", {"gratitude":10.0,"trust":3.0}, 11), "救援关系未写入")
	var edge: Dictionary = system.relation(actor, candidate)
	check(not system.relation_event(actor, candidate, "rescue", {"gratitude":10.0,"trust":3.0}, 11), "同事件重复改变关系")
	check(system.relation(actor, candidate) == edge, "重复关系事件改变数值")
	check(system.injury(candidate, "wound", 12, "upper", 0.8), "伤病未记录")
	check(not system.injury(candidate, "wound", 12, "upper", 0.8), "伤病事件重复施加")
	check(not system.can_personally_act(candidate, "shoot"), "严重上肢伤未禁止本人射击")
	check(system.can_personally_act(candidate, "ride"), "上肢伤错误禁止骑乘")
	check(not system.service_review(candidate)["automatic_betrayal"], "满意度产生每日随机背叛")
	check(system.recover_injuries(candidate, "rest:week", 19, 1.0, 1.0), "有效休养未生效")
	check(not system.recover_injuries(candidate, "rest:week", 19, 1.0, 1.0), "同一休养事件重复恢复")
	for index in range(40):
		check(system.professional_duty(candidate, "professional-test:%d" % index, 100 + index, 2.0, "infantry", "plains", "mission:%d" % (index % 3), "route:%d" % (index % 2)), "有效专业履职未记录")
	check(system.view(candidate)["troop_aptitudes"]["infantry"] == "C", "兵种适性缺少经验晋级")
	check(system.view(candidate)["terrain_experience"]["plains"] == "familiar", "地形经历没有达到熟悉")
	check(not system.professional_duty(candidate, "professional-test:0", 100, 2.0, "infantry", "plains", "mission:0", "route:0"), "重复专业事件刷经验")
	var snapshot: Dictionary = JSON.parse_string(JSON.stringify(war.export_state(), "", true, true))
	var saved_view: Dictionary = system.view(candidate)
	war.setup(store, snapshot)
	check(war.characters.view(candidate) == saved_view, "成长伤病或入仕状态读档后丢失")
	var restored_edge: Dictionary = war.characters.relation(actor, candidate)
	for axis in System.RELATION_AXES:
		check(is_equal_approx(float(restored_edge.get(axis, -1)), float(edge[axis])), "关系读档后丢失:" + str(axis))
	check(war.Talent.known(war, faction, candidate), "发现记录读档后丢失")
	check(war.roster.officers[candidate]["faction"] == faction, "动态所属势力读档后丢失")
	if failures.is_empty(): print("CHARACTER_SYSTEM_OK")
	quit(0 if failures.is_empty() else 1)
