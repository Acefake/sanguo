# campaign_state.gd 拆分说明（2026-10-21）

`scripts/war/campaign/campaign_state.gd` 原来 1722 行、77 个函数，现在按职责拆成 8 个协作模块，CampaignState 只留状态、存档读写、几条基础查询和 `step()` 调度。行为不变：搬走的函数体除了把 `self`、成员变量、互相调用改成经 `war` 访问以外逐字未动。

## 模块

| 文件 | class_name | 行数 | 职责 |
|---|---|---|---|
| `campaign_state.gd` | （无，沿用 preload） | 540 | 状态变量、`setup`/`export_state`、关系与通路查询、`step()` 调度、全部转发 |
| `campaign_logistics.gd` | CampaignLogistics | 110 | 补给开关、耗粮、兵员账本、每日给养结算、城内兵种库存、征兵 |
| `campaign_reports.gd` | CampaignReports | 139 | 军报生成与延迟送达、可见军报、本方位置标记、会战与战役总结 |
| `campaign_orders.gd` | CampaignOrders | 215 | 军令默认值与候选过滤、玩家下令、批复请示、违令判定 |
| `campaign_dispatch.gd` | CampaignDispatch | 160 | 可用武将、出征预览与派遣、抽兵组军、守城方自动出兵 |
| `campaign_context.gd` | CampaignContext | 346 | 情报刷新、战线职责分配、决策观察快照与候选、决策校验与重判门槛 |
| `campaign_contact_resolver.gd` | CampaignContactResolver | 193 | 道路行军、接触判定、道路交战结算、首次接敌特效、地形查询 |
| `campaign_outcomes.gd` | CampaignOutcomes | 206 | 围城破口与攻占、溃败、主帅失位、胜负记入经验 |
| `campaign_actions.gd` | CampaignActions | 149 | 执行行动、规划撤退、任务结束时兵员粮草归城 |

约定：

- 模块全是静态函数，第一个参数 `war` 是 CampaignState 实例。不标类型：标成 CampaignState 会让模块和 campaign_state.gd 互相引用。
- 同一模块内直接调用；跨模块一律走 `war.xxx()`（即下面的转发），所以模块之间没有 preload 环。
- 经无类型的 `war` 访问后，`var x := ...` 若依赖 CampaignState 成员的类型会推断失败，这类地方改成显式类型（目前只有 `_support_context` 的 `available: bool`），值不变。
- CampaignState 原有的 33 个 preload 常量全部保留：外部脚本会以 `war.Combat`、`war.Tactical`、`war.Feedback` 等形式访问。
- 留在 CampaignState 的函数：`setup`、`_json`、`export_state`、`active_armies`、`ready`、`is_besieged`、`hostile`、`can_cross`、`route`、`campaign_finished`、`start_campaign`、`set_player_faction`、`step`、`uses_unit_brain`、`set_battle_ai_mode`。`setup` 和 `step` 的函数体逐字未改，仍调用转发。

## 保留的转发

62 个搬走的函数在 CampaignState 末尾都保留同签名的一行转发（`return 模块.f(self, ...)`），按模块分节。原因：

1. 仓库里大量脚本和测试直接调用 `war._report`、`war._execute`、`war._finish`、`war._check_rout` 等下划线函数，下划线在这里不代表私有。
2. 只在你本地的 15 个脚本（见《缺失脚本新位置对照表》）和 18 个测试拿不到，可能调用任何一个成员，所以一个都不删。
3. 跨模块调用本身也走转发。

下面 10 个转发在仓库里没有任何调用者（外部、跨模块、setup/step 都没有），只为本地脚本可能用到而保留；确认本地也没用后可以删：
`has_pending_urgent_report`、`_casualty_summary`、`_record_approved`、`_append_dissent`、`_near_battle`、`_support_context`、`_add_candidate`、`_fate_enemy`、`_remember_win`、`_nearest_enemy_id`。（它们的实现仍被同模块内部直接调用。）

| 转发函数 | 实现模块 | 仓库内外部调用（文件数） | 其它协作模块经 war. 调用 | CampaignState 自身（setup/step 等）调用 |
|---|---|---|---|---|
| `supply_enabled` | CampaignLogistics | 7 (army_corps.gd, army_inspector.gd, army_world_3d.gd…) | orders, dispatch, context, outcomes, actions | 是 |
| `daily_food` | CampaignLogistics | 2 (army_corps.gd, army_inspector.gd) | outcomes, actions | — |
| `food_days` | CampaignLogistics | 1 (army_corps.gd) | reports, context | — |
| `ledger` | CampaignLogistics | 5 (battle_extension_campaign_validation.gd, campaign_closure_validation.gd, campaign_operations_validation.gd…) | — | — |
| `_upkeep` | CampaignLogistics | 1 (no_starvation_validation.gd) | — | 是 |
| `_sync_inventory` | CampaignLogistics | 3 (city_fortifications.gd, game_state.gd, siege_system.gd) | dispatch, actions | 是 |
| `recruit_units` | CampaignLogistics | 1 (game_state.gd) | — | — |
| `_report` | CampaignReports | 10 (army_corps.gd, city_fortifications.gd, duel_system.gd…) | logistics, orders, dispatch, contact_resolver, outcomes, actions | — |
| `_deliver_reports` | CampaignReports | 2 (duel_validation.gd, officer_fate_validation.gd) | — | 是 |
| `visible_reports` | CampaignReports | 1 (military_reports.gd) | — | — |
| `has_pending_urgent_report` | CampaignReports | 0 | — | — |
| `player_markers` | CampaignReports | 2 (map_slice.gd, rtk14_world_2d.gd) | — | — |
| `request_battle_summary` | CampaignReports | 1 (military_reports.gd) | — | — |
| `_summarize_finished_battles` | CampaignReports | 0 | — | 是 |
| `_casualty_summary` | CampaignReports | 0 | — | — |
| `orders_for` | CampaignOrders | 8 (army_corps.gd, campaign_ui.gd, corps_validation.gd…) | logistics, context, contact_resolver, outcomes | 是 |
| `filter_candidates` | CampaignOrders | 1 (orders_dissent_validation.gd) | context | — |
| `filter_commander_candidates` | CampaignOrders | 2 (army_corps.gd, orders_dissent_validation.gd) | — | — |
| `command_army` | CampaignOrders | 4 (campaign_ui.gd, capture_army_world_3d.gd, corps_validation.gd…) | — | — |
| `resolve_request` | CampaignOrders | 2 (campaign_ui.gd, orders_dissent_validation.gd) | — | — |
| `_record_approved` | CampaignOrders | 0 | — | — |
| `_expire_requests` | CampaignOrders | 1 (orders_dissent_validation.gd) | — | 是 |
| `_evaluate_dissent` | CampaignOrders | 1 (orders_dissent_validation.gd) | — | 是 |
| `_append_dissent` | CampaignOrders | 0 | — | — |
| `_has_independent_action` | CampaignOrders | 0 | logistics, outcomes | — |
| `available_officers` | CampaignDispatch | 16 (campaign_aftermath_validation.gd, campaign_operations.gd, campaign_operations_validation.gd…) | outcomes | — |
| `preview_dispatch` | CampaignDispatch | 11 (campaign_operations_validation.gd, campaign_ui.gd, city_war_loop_validation.gd…) | — | — |
| `dispatch` | CampaignDispatch | 8 (campaign_aftermath_validation.gd, campaign_operations_validation.gd, campaign_ui.gd…) | — | — |
| `_mobilize` | CampaignDispatch | 9 (campaign_operations_validation.gd, city_war_loop_validation.gd, no_starvation_validation.gd…) | — | — |
| `_spawn_defenders` | CampaignDispatch | 0 | — | 是 |
| `city_intel` | CampaignContext | 2 (strategic_ai.gd, strategic_ai_validation.gd) | — | — |
| `enemy_intel` | CampaignContext | 2 (army_world_3d.gd, tactical_battlefield.gd) | — | — |
| `player_city_intel` | CampaignContext | 2 (map_slice.gd, war_validation.gd) | — | — |
| `player_has_city_access` | CampaignContext | 4 (campaign_operations.gd, city_interior.gd, game_state.gd…) | — | — |
| `_observe_all` | CampaignContext | 14 (battle_ai_flow_validation.gd, battle_balance_validation.gd, battle_discipline_validation.gd…) | dispatch | 是 |
| `_update_operations` | CampaignContext | 4 (battle_ai_flow_validation.gd, battle_scenarios.gd, tactical_battlefield_validation.gd…) | — | 是 |
| `_near_battle` | CampaignContext | 0 | — | — |
| `_support_context` | CampaignContext | 0 | — | — |
| `_observed_contact` | CampaignContext | 1 (army_corps.gd) | — | — |
| `context_for` | CampaignContext | 7 (army_corps.gd, capture_army_world_3d.gd, no_starvation_validation.gd…) | orders | 是 |
| `_add_candidate` | CampaignContext | 0 | — | — |
| `validate_decision` | CampaignContext | 2 (army_corps.gd, war_validation.gd) | — | 是 |
| `_should_reconsider` | CampaignContext | 0 | — | 是 |
| `_decision_key` | CampaignContext | 1 (tactical_battlefield_validation.gd) | — | 是 |
| `_terrain` | CampaignContactResolver | 3 (army_corps.gd, forecast.gd, siege_system.gd) | context, actions | — |
| `_move_all` | CampaignContactResolver | 3 (campaign_operations_validation.gd, tactical_battlefield_validation.gd, war_validation.gd) | — | 是 |
| `_edge_coordinate` | CampaignContactResolver | 1 (campaign_battlefields.gd) | context | — |
| `_contact` | CampaignContactResolver | 3 (campaign_battlefields.gd, duel_system.gd, siege_system.gd) | outcomes | — |
| `_resolve_contacts` | CampaignContactResolver | 6 (battle_ai_flow_validation.gd, ranged_pressure_validation.gd, tactical_battlefield_validation.gd…) | — | 是 |
| `_battle_contact` | CampaignContactResolver | 1 (tactical_battlefield.gd) | — | — |
| `_resolve_sieges` | CampaignOutcomes | 4 (corps_validation.gd, no_starvation_validation.gd, siege_corps_validation.gd…) | — | 是 |
| `_capture_city` | CampaignOutcomes | 1 (siege_system.gd) | — | — |
| `_fate_enemy` | CampaignOutcomes | 0 | — | — |
| `_check_rout` | CampaignOutcomes | 7 (army_corps.gd, battle_balance_validation.gd, city_fortifications.gd…) | logistics, contact_resolver | — |
| `_check_leader_lost` | CampaignOutcomes | 2 (officer_command_validation.gd, tactical_battlefield.gd) | — | — |
| `_battle_victory` | CampaignOutcomes | 1 (tactical_battlefield.gd) | contact_resolver | — |
| `_remember_win` | CampaignOutcomes | 0 | — | — |
| `_remember_loss` | CampaignOutcomes | 0 | contact_resolver | — |
| `_nearest_enemy_id` | CampaignOutcomes | 0 | — | — |
| `_execute` | CampaignActions | 3 (army_corps.gd, siege_corps_validation.gd, war_validation.gd) | orders, outcomes | 是 |
| `_start_return` | CampaignActions | 4 (campaign_battlefields.gd, retreat_route_replay_validation.gd, tactical_battlefield.gd…) | logistics, outcomes | 是 |
| `_finish` | CampaignActions | 7 (battle_scenarios.gd, corps_validation.gd, duel_validation.gd…) | outcomes | — |

## 本地合并时注意

- 新增 8 个 `class_name`：CampaignLogistics、CampaignReports、CampaignOrders、CampaignDispatch、CampaignContext、CampaignContactResolver、CampaignOutcomes、CampaignActions。如果本地脚本里有同名的 class_name 或全局常量，会冲突。
- 8 个新文件没有附 `.gd.uid`（沙箱生成的 uid 与本地无关），Godot 首次打开项目会自动生成，生成后可以一起提交。
- 本地脚本若改过 campaign_state.gd 里已搬走的函数体，需要把改动搬到对应模块，并照上面的约定改写 `self`/成员访问。

## 验证

每个拆分提交都跑了：

- 沙箱验证工具 `check3.sh`（不在仓库内）全套（battle suite 59 项、tests/officers 5 项、identity harness 文本与 json、解析错误、全量编译加载），与 bd50b9f 基线对比 RESULT SAME。注意沙箱缺那 15 个脚本，用空壳顶替时 campaign_state.gd 本身编译失败、battle suite 全部因 game_state 不能编译而失败，所以这一套只能证明“没有新增错误”。
- 补充的运行期对比（仅沙箱，不提交，对最终提交）：给 15 个缺失脚本生成声明了全部被调用成员的空壳，让 CampaignState 真正跑起来；仓库里 41 个现存的 battle suite 测试，加一个三场景共推进 180 日、含出征/改军令/撤军的驱动脚本，逐日比较完整存档的 sha256 和全部输出（去掉回溯行号），拆分前后一致（只归一化了耗时毫秒数和地形网格缓存命中数）。
- 代码层逆向核对：把每个模块函数按改写规则还原，必须与原函数逐字节相同；保留函数逐字节相同；每个转发签名与原函数相同。
