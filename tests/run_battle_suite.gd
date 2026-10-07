extends SceneTree

# 战斗回归套件的统一入口。原先 23 项验证只能手工逐个启动，文档里“回归全部通过”
# 的结论无法一键复现，因此这里只做一件事：逐个执行并汇总退出码。
#
#   godot --headless --script res://tests/run_battle_suite.gd
#   godot --headless --script res://tests/run_battle_suite.gd -- --only=duel
#   godot --headless --script res://tests/run_battle_suite.gd -- --include-model

const SUITE := [
	# 结算与将领
	"officer_battle_validation",
	"officer_command_validation",
	"officer_edges_validation",
	"officer_fate_validation",
	"personal_kills_validation",
	"duel_validation",
	"combat_effects_validation",
	# 战场、接敌与旧存档迁移
	"tactical_battlefield_validation",
	"global_battle_grid_validation",
	"formation_validation",
	"battle_ai_flow_validation",
	"battle_discipline_validation",
	"battle_feedback_validation",
	"encirclement_validation",
	"siege_corps_validation",
	"battle_balance_validation",
	"corps_validation",
	# 决策与授权
	"forecast_validation",
	"policy_scoring_validation",
	"commander_policy_validation",
	"model_gate_validation",
	"orders_dissent_validation",
	"decision_scheduler_validation",
	# 战略与调度
	"strategic_ai_validation",
	"experience_validation",
	"war_validation",
	"retreat_route_replay_validation",
	"war_month_performance_validation",
	"agent_settings_validation",
	# 场景与界面
	"battle_scenarios_validation",
	"battle_scenarios_model_validation",
	"battle_start_validation",
	"battle_extension_ui_validation",
	"battle_extension_campaign_validation",
	"xiaopei_battle_validation",
]

# 需要模型服务或长时间运行，默认跳过。
const NEEDS_MODEL := ["battle_scenarios_model_validation"]
const NEEDS_GPU := ["battle_extension_ui_validation"]


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
