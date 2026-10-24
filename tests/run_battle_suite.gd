extends SceneTree

# 战斗回归套件的统一入口。原先 23 项验证只能手工逐个启动，文档里“回归全部通过”
# 的结论无法一键复现，因此这里只做一件事：逐个执行并汇总退出码。
#
#   godot --headless --script res://tests/run_battle_suite.gd
#   godot --headless --script res://tests/run_battle_suite.gd -- --only=duel
#   godot --headless --script res://tests/run_battle_suite.gd -- --include-model

const SUITE := [
	# 结算与将领
	"officers/officer_battle_validation",
	"officers/officer_command_validation",
	"war/campaign/officer_edges_validation",
	"war/campaign/officer_fate_validation",
	"war/campaign/leaderless_disperse_validation",
	"war/campaign/personal_kills_validation",
	"war/duel/duel_validation",
	"war/duel/duel_roles_validation",
	"war/duel/duel_v2_validation",
	"war/presentation/combat_effects_validation",
	# 战场、接敌与旧存档迁移
	"war/battle/tactical_battlefield_validation",
	"war/battle/multi_contact_validation",
	"war/battle/continuous_march_validation",
	"war/battle/contact_priority_validation",
	"war/battle/global_battle_grid_validation",
	"war/campaign/formation_validation",
	"war/battle/battle_ai_flow_validation",
	"war/battle/battle_discipline_validation",
	"war/battle/battle_feedback_validation",
	"war/battle/encirclement_validation",
	"war/battle/siege_corps_validation",
	"war/battle/city_defense_separation_validation",
	"war/battle/city_defense_edge_validation",
	"war/battle/battle_balance_validation",
	"war/campaign/corps_validation",
	"war/campaign/six_member_corps_validation",
	"war/campaign/free_corps_structure_validation",
	"agents/officer_autonomy_validation",
	"agents/player_command_autonomy_validation",
	"war/campaign/report_policy_validation",
	# 决策与授权
	"agents/forecast_validation",
	"agents/policy_scoring_validation",
	"agents/commander_policy_validation",
	"agents/model_gate_validation",
	"agents/orders_dissent_validation",
	"agents/decision_scheduler_validation",
	"agents/unit_brain_validation",
	"agents/unit_model_validation",
	"agents/tactical_behavior_validation",
	"agents/officer_agents_validation",
	# 战略与调度
	"war/campaign/strategic_ai_validation",
	"agents/experience_validation",
	"war/campaign/war_validation",
	"war/campaign/retreat_route_replay_validation",
	"war/campaign/war_month_performance_validation",
	"agents/agent_settings_validation",
	# 场景与界面
	"war/battle/battle_scenarios_validation",
	"war/battle/battle_objectives_validation",
	"war/battle/battle_scenarios_model_validation",
	"war/ui/battle_start_validation",
	"war/ui/battle_extension_ui_validation",
	"war/battle/battle_extension_campaign_validation",
	"war/presentation/xiaopei_battle_validation",
]

# 需要模型服务或长时间运行，默认跳过。
const NEEDS_MODEL := ["war/battle/battle_scenarios_model_validation"]
const NEEDS_GPU := ["war/ui/battle_extension_ui_validation"]


func _initialize() -> void:
	call_deferred("run")


func run() -> void:
	var args := OS.get_cmdline_user_args()
	var include_model := false
	var only := ""
	for arg in args:
		if arg == "--include-model": include_model = true
		elif arg.begins_with("--only="): only = arg.substr(7)
	var executable := OS.get_executable_path()
	var failures: Array[String] = []
	var ran := 0
	var skipped := 0
	for name in SUITE:
		if not only.is_empty() and not name.contains(only): continue
		if NEEDS_GPU.has(name) and DisplayServer.get_name() == "headless":
			skipped += 1
			print("SKIP  %s（须单独使用实际GPU执行）" % name)
			continue
		if NEEDS_MODEL.has(name) and not include_model:
			skipped += 1
			print("SKIP  %s（需要模型服务，加 --include-model 运行）" % name)
			continue
		ran += 1
		var output: Array = []
		var code := OS.execute(executable, ["--headless", "--path", ProjectSettings.globalize_path("res://"), "--quit-after", "10000", "--script", "res://tests/%s.gd" % name], output, true)
		var result := "\n".join(output)
		print(result)
		if result.contains("SCRIPT ERROR") or result.contains("ERROR:") or not (result.contains("OK") or result.contains("PASS") or result.contains("VALIDATION")): code = 1
		if code == 0:
			print("PASS  %s" % name)
		else:
			failures.append("%s（退出码 %d）" % [name, code])
			print("FAIL  %s（退出码 %d）" % [name, code])
	print("----")
	if failures.is_empty():
		print("BATTLE_SUITE: PASS（%d 项，跳过 %d 项）" % [ran, skipped])
	else:
		for failure in failures: push_error("BATTLE_SUITE 失败：" + failure)
		print("BATTLE_SUITE: FAIL（%d/%d 项失败）" % [failures.size(), ran])
	quit(0 if failures.is_empty() else 1)
