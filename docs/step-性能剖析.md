# 战役 step() 性能剖析（2026-10-23）

基线是 `feat/ai-model-queue` 的 4d8f328（A1）。本次先只测量、不优化，再做了两处结果不变的小修复。结论先写在前面：

- 纯规则 step 的 p50 主要花在每日两次的 `_observe_all`（约 1/4）和每日两次的 `FactionLifecycle.maintain`（约 1/4）。
- p95 来自军团每 3 日一次的同步重判：所有军团在第 10 日同时组建，此后每 3 日同一天一起重判（第 13、16、19…日），当天 +80 ms 左右。
- p99 和最大值只来自一天：第 10 日 `StrategicAI.plan` 首次派兵，约 1030 次 `preview_dispatch` 带出约 1090 次 `route()`，其中只有 242 个不同的（势力，起点，终点）。
- 30 秒替身模式的 p50 比纯规则高约 240–320 ms，几乎全部来自 `ArmyCorps.plan_background`：每个军团每天都要构造 2–3 次主帅上下文（`commander_context` → `context_for`），纯规则只在 3 日心跳到期时构造 1 次。模型等待和调度本身只占 1 ms 量级。
- 30 日演示里没有一次接敌，接敌、战术结算、围城的耗时都接近 0。原因是沙箱空壳让军团无法拆分出战部队（见 §8），这部分数字不能代表真实游戏。
- 两处结果不变的修复（§6）经回归核对输出逐字节相同；端到端 A/B 纯规则 p50 −1.6%、p99 −2.1%，替身 p99 −1.9%（§7），是小幅改进。

## 1. 方法

工具都在 `tools/profile/`，不改游戏代码，默认不参与任何运行路径：

| 文件 | 作用 |
|---|---|
| `step_profile.gd` | `ProfiledCampaign` 继承 `CampaignState`，`step()` 是原版的逐行副本，只在阶段之间插 `Time.get_ticks_usec()` 计时，各阶段相加等于 step 总耗时。另外包住若干实例方法（`context_for`、`route`、`preview_dispatch`、`available_officers`、`active_armies`、`_observe_all` 等）记包含式累计耗时和调用次数。每一局先用原版 `CampaignState` 跑同样的日数记下每日 `export_state` 的 sha256，再跑计时版逐日比对，任何一天不同就打印 `PROFILE_DRIFT` 并以退出码 1 结束。 |
| `check_copy.py` | 静态核对：去掉计时行后，副本必须与 `campaign_state.gd` 的 `step()` 逐行相同。`step()` 改动后先跑它。 |
| `micro_profile.gd` | 跑到指定日后，在同一 tick 上把热点子项各重复调用 N 次计时（这些子项重复调用结果相同）。 |
| `summarize.py` | 汇总 p50/p95/p99/占比、最慢 step、逐日中位数。分位数取法与 `tests/agents/step_latency_validation.gd` 相同。 |

```
godot --headless --path . --script res://tools/profile/step_profile.gd -- --days=30 --rounds=3 > profile.raw
python3 tools/profile/summarize.py profile.raw
godot --headless --path . --script res://tools/profile/micro_profile.gd -- --days=12,25 --repeat=20
```

剧本、替身与 `step_latency_validation` 相同：演示剧本 30 日；替身固定延迟 30 秒、取候选第 2 名。

环境：Godot 4.7.2 headless，2 核沙箱，富空壳（§8）。**测量期间同一台机器上还有其他验证在跑，负载均值 3.4–5.2**，所以绝对值比 A1 文档里的数字高（A1：纯规则 p50 84 / p95 167 / p99 575 ms），相对占比更可信。下表是 3 轮 × 30 日（每种模式 90 个 step）。计时版与原版的 p50 相差在噪声内（纯规则原版 97.8 ms、计时版 94.3 ms），计时本身的开销可以忽略。

## 2. 纯规则：各阶段耗时（ms，90 个 step）

原版 step：p50 97.8 / p95 395.5 / p99 693.5。阶段名对应 `step()` 里的代码段，独占计时，相加等于 step。

| 阶段（代码） | p50 | p95 | p99 | 占比 |
|---|---:|---:|---:|---:|
| step 合计（计时版） | 94.3 | 265.4 | 1028.9 | 100% |
| observe：两次 `_observe_all()` | 32.7 | 54.7 | 63.9 | 22.9% |
| corps_plan：`Corps.plan()` | 0.4 | 127.7 | 156.7 | 20.1% |
| strategic_plan：`Strategic.plan()` | 0.0 | 24.3 | 766.5 | 16.6% |
| lifecycle：第二次 `Lifecycle.maintain()` | 17.4 | 28.2 | 33.8 | 14.4% |
| lifecycle_residence_defenders：第一次 `maintain` + `residence` + `_spawn_defenders` | 18.1 | 23.8 | 33.7 | 14.3% |
| fortifications_fire：`Fortifications.fire()` | 4.8 | 8.3 | 10.0 | 3.6% |
| contacts_resolve：`_resolve_contacts()`（接敌） | 4.2 | 6.2 | 8.3 | 2.7% |
| battlefields_prepare | 1.9 | 3.5 | 4.4 | 1.3% |
| operations_unit_decide：`Fate.restore` + `_update_operations` + `UnitBrain.decide` | 0.6 | 5.1 | 7.7 | 0.9% |
| supply_upkeep：`_upkeep()`（补给） | 1.1 | 1.5 | 4.7 | 0.7% |
| army_contexts / army_commit：独立部队决策上下文与落地 | 0.1 | 0.2 | 29.4 | 1.1% |
| march_move_all：`_move_all()`（行军） | 0.1 | 0.2 | 0.4 | 0.1% |
| 军报（三次 `_deliver_reports` 等） | 0.5 | 0.7 | 2.3 | 0.4% |
| scheduler_begin_round（调度） | 0.0 | 0.0 | 0.1 | 0.0% |
| 其余 13 段合计 | — | — | — | <1% |

跨阶段累计（包含式，与上表重叠）：`route` 15.3%（p99 546 ms）、`context_for` 14.1%、`preview_dispatch` 12.6%、`available_officers` 8.7%（每 step 83 次）、`active_armies` 8.3%（每 step 251 次）。

step 之外（`GameState._finish_advance` 里的 `_save()`，测试和 A1 的 step 数字都不含）：`export_state` p50 18.9 ms + `JSON.stringify(…, "\t")` p50 79.3 ms，合计约 100 ms/日，比 step 的 p50 还大。第 25 日存档 2.50 MB，其中各部队的 `intel` 占 1.21 MB（49%）。信号：`campaign_progress` / `campaign_changed` 在 headless 下没有接收方，耗时为 0；真实 UI 的接收方没有测。

## 3. 30 秒替身：各阶段耗时（ms，90 个 step）

原版 step：p50 407.5 / p95 594.3 / p99 1026.3。

| 阶段 | p50 | p95 | p99 | 占比 |
|---|---:|---:|---:|---:|
| step 合计（计时版） | 436.7 | 829.2 | 974.2 | 100% |
| corps_plan：`Corps.plan()` → `plan_background()` | 317.6 | 582.4 | 757.1 | 69.1% |
| observe | 44.1 | 80.1 | 110.5 | 10.2% |
| lifecycle_residence_defenders | 21.4 | 36.5 | 57.8 | 5.8% |
| lifecycle | 20.5 | 34.1 | 41.1 | 5.6% |
| strategic_plan | 0.0 | 26.5 | 521.5 | 4.8% |
| scheduler（begin_round + take + submit） | 0.1 | 8.4 | 14.5 | 0.4% |
| 其余 | — | — | — | <5% |

包含式：`context_for` 49.0%（每 step 40.5 次，纯规则 4.7 次），`route` 17.5%（每 step 165 次，纯规则 51 次）。

### 替身模式为什么慢约 240 ms

`ArmyCorps.plan()` 遇到支持后台决策的适配器就走 `plan_background()`（army_corps.gd:885）。它对每个军团每天都：

1. `commander_context()` 一次（:908），算本地兜底答案；
2. 不管有没有下达新命令，再 `commander_context()` 一次（:921），准备发给模型的上下文；
3. 有到期答案时，为复查再构造一次（:896）；外加两次 `decision_signature()`。

纯规则走 `plan()` 的本地循环，只在 `tick - last_plan >= 3` 或情况变糟时才构造一次（:510）。`commander_context` 里的 `context_for` 每次约 5.5–7 ms（`micro_profile`，第 12 日），19–20 个军团 × 每天 2–3 次 ≈ 210–400 ms，与实测的 corps_plan 差值吻合。A1 改动前后替身模式都慢（A1 文档 §6.1），这是原有路径，不是模型等待：调度三项合计 p50 0.07 ms。

## 4. 尖峰

| 日 | 纯规则 step（三轮中位） | 主因 |
|---|---:|---|
| 1–9 | 23–29 ms | 还没有部队，只剩两次 `Lifecycle.maintain`（各约 11 ms） |
| **10** | **664 ms**（三轮 591 / 664 / 1029） | `Strategic.plan`（`eval_interval` = 10）首次派兵：19 支部队、19 个军团同日组建。1030 次 `preview_dispatch`、1091 次 `route()`、只有 242 个不同组合；`route` 合计约 620 ms。当天 `Corps.plan` 还要给 19 个新军团各构造一次上下文（约 92 ms） |
| 13、16、19、22、25、28 | 157–181 ms | 19 个军团都在第 10 日组建，`last_plan` 相同，3 日心跳同一天到期，`Corps.plan` 一起重判（约 +80 ms） |
| 20、30 | 117、103 ms | 第二、三次战略评估（多数势力已无可派之兵，只有 24 / 9 ms） |
| 其余 | 76–100 ms | 稳态：`_observe_all` 两次 + `maintain` 两次占约 70% |

替身模式的最慢 step 是第 10 日（805–870 ms，strategic_plan 约 500 ms）和第 23–26 日（800–974 ms，corps_plan 630–757 ms；上下文随部队情报增长变大）。

`route()` 尖峰的构成（`micro_profile`，第 12 日）：每次调用先对全图 72 个地点逐一 `can_cross()` 求排除表，约 0.35 ms；缓存命中后 `graph.path()` 本身很便宜；未命中时 `_search()` 约 0.6 ms。所以第 10 日主要慢在 1091 次重复求排除表，而不是 Dijkstra。

`_observe_all` 随日数从 22 ms 涨到 42 ms（部队数不变），因为每支部队每次都深拷一份全部 72 城的情报（`cities.duplicate(true)`，19 支约 8.6 ms），并释放上一份；城池字典本身也在增长。

## 5. 前 3 个热点与优化思路

估计基于本次占比和 `micro_profile` 的单项耗时，都还没实现，收益是上限估计。

| # | 热点 | 思路 | 预估收益 | 风险 |
|---|---|---|---|---|
| 1 | 军团主帅上下文（替身模式 corps_plan 69%；纯规则 p95 的 3 日同步重判） | (a) `plan_background` 在 :908 与 :921 之间没有 `record_background_order` 时复用第一份上下文，每军团每天少构造 1 次；(b) `context_for` 里每次深拷 72 城情报、`local_map`、武将卡，改成按 tick 共享只读快照；(c) 军团首个 `last_plan` 按 id 错开，打散同日重判 | (a) 替身 p50 约 −100~−150 ms（−30%）；(b) `context_for` 5.5 → 约 3 ms，两种模式都受益；(c) 纯规则 p95 约 −60 ms | (a) 需要确认本地的 `officer_autonomy.gd` 的 `evaluate_corps` 重复调用无副作用；(c) 改变重判日期，是规则变化，要设计确认 |
| 2 | `_observe_all`（纯规则 23%，每日两次） | 所有部队共用同一份城池情报快照（或放在 war 级别、部队只存引用），不再每支部队深拷一份 | 每次约 20 ms → 约 5 ms，纯规则 p50 约 −30 ms（−30%）；存档少约 1.2 MB（−49%），`_save` 约 −50 ms/日 | 共享后若有代码改写某支部队的 `intel.cities` 会互相影响。仓库内只读不写；15 个本地脚本需要核对 |
| 3 | 战略评估日的 `route()`（p99/max） | `Strategic.plan` 一次评估内城池归属和关系不变，对 `route(faction, start, finish)` 做本次评估内的记忆；或按势力只算一次排除表 | 第 10 日 1091 次 → 242 次，约 620 ms → 约 140 ms，纯规则 max 约 −480 ms | 记忆必须只在一次评估内有效，评估结束即清；归属改变（攻城）不在评估中发生，需要加断言 |

另外两项不在前三但值得记下：`Lifecycle.maintain` 每日两次各约 17 ms，其中 `Strategic.lord_of` × 21 势力约 4–5 ms（几乎全在 `Process.value` 的特性修正上，排序只占 0.5 ms），`available_officers` 每 step 83 次；`_save` 的 `JSON.stringify(…, "\t")` 约 80 ms，去掉缩进或改二进制存档可再减一半以上。

## 6. 已做的修复（dd4c43d）

两处“重复计算”，不改任何战斗数值和规则：

1. `CampaignState.hostile / can_cross`：关系键原来每次新建两元素数组、排序、`"|".join()`；改为 `_relation_key()` 直接按字典序拼接。`route()` 每次对 72 个地点调用 `can_cross`；`_observe_all` 对部队两两调用 `hostile`。
2. `OfficerContext.ensure_factions`：原来每次调用都对全部武将逐项排序求技能中位数，而中位数只在需要补生成武将时才用；改为第一次用到时才算。第一次用到时还没有新增武将，所以结果与原先在函数开头计算的相同。

试过但撤回：`MapGraph._search` 把每轮 `sort_custom` 换成线性取最小，新旧结果在全部 72×72 对（含/不含排除表，共 10368 次）上逐一相同，但同进程交替计时新版反而慢 10%（frontier 很短，原生排序比 GDScript 循环快），所以没有提交。

同进程交替计时（第 12 日状态，每项取 7 轮最小值，消除机器负载的影响）：

| 项 | 改前 | 改后 | 倍数 |
|---|---:|---:|---:|
| `route()` 排除表：72 地点 × 10 次 | 2849 µs | 2408 µs | ×1.18 |
| `ensure_factions` 一次 | 5090 µs | 3283 µs | ×1.55 |

折算到 step：纯规则每 step 约 −2 ms（route 51 次）−3.6 ms（`ensure_factions` 两次）≈ −6 ms（约 6%），第 10 日约 −50 ms；替身模式每 step 约 −11 ms（route 165 次）。这比机器负载造成的波动小，端到端 A/B 见 §7。

## 7. 回归核对与修后耗时

改前 4d8f328，改后 dd4c43d（另两个提交只动 `tools/profile/` 和本文档）。每边在自己的镜像里跑，沙箱验证脚本在 `work/refactor/prof/`，不提交。

| 核对 | 结论 |
|---|---|
| 富空壳战役 harness（纯规则，3 个剧本共 180 日，每日 `export_state` sha256 + 最终存档 + 军报 + 账本） | 183 条每日哈希与最终状态逐字节相同；只有空壳报错的 GDScript 回溯行号不同（`campaign_state.gd` 在 step 之前少了 2 行） |
| 富空壳套件逐项输出（43 项） | 42 项去掉回溯行后逐字节相同。`agents/step_latency_validation` 只有 `STEP_MS`/`SCHEDULER_MS` 的耗时读数不同，两边都因“纯规则底数 p99 超过 16 ms”失败，失败原因相同 |
| 空壳套件（`check3.sh` + `compare.py`：编辑器解析两遍、全量编译、5 个武将测试、身份 harness 文本与 JSON、套件 61 项） | 解析错误、武将测试、身份 harness、套件结果相同；另把套件 61 项的输出逐项比对（去回溯、去耗时），全部相同。全量编译多一条错误：新增的 `tools/profile/step_profile.gd` 在普通空壳下解析不了 `CampaignState`，原因是 `campaign_state.gd` 本身在普通空壳下就加载失败（改前改后都是 FAIL），不是 dd4c43d 引入的 |
| 检验战场跑测器 6 战场 × 32 种子 | 汇总 JSON（8 796 047 字节）逐字节相同，md5 `771228d0…`；文本输出去回溯后相同，两边 `BATTLEFIELD_AI: PASS` |
| `can_cross` 新旧实现 | 21 势力 × 72 地点 = 1512 组逐一相同 |
| `step_profile.gd` 每局计时版与原版逐日哈希 | 全部相同（`PROFILE_DONE drift=false`） |

### 端到端 A/B

用仓库自己的 `tests/agents/step_latency_validation.gd`（演示剧本 30 日，纯规则与 30 秒替身各一组）。同一镜像里只换 dd4c43d 动过的 3 个文件，改前、改后交替跑 10 轮，每轮各自算 p50/p95/p99，下表是 10 轮的中位数（ms）。跑测时机器上没有其他验证，负载均值 1.1–1.8（Godot 自己占 1 核）。每个模式每轮只有 30 个 step，p99 就是最大值，也就是第 10 日。

| 模式 | | p50 | p95 | p99 |
|---|---|---:|---:|---:|
| 纯规则 | 改前 | 86.1 | 171.4 | 579.1 |
| | 改后 | 84.7 | 169.9 | 566.8 |
| 30 秒替身 | 改前 | 331.1 | 373.6 | 722.7 |
| | 改后 | 328.4 | 383.3 | 709.1 |

- 纯规则：p50 −1.4 ms（−1.6%），p99 −12 ms（−2.1%）。p99 在 10 轮里都是改后更低：改前 576–586（第 1 轮预热 668），改后 565–572（第 1 轮 685）。
- 替身：p50 −2.7 ms（−0.8%），p99 −14 ms（−1.9%）。p95 改后反而高约 10 ms，来自第 4、8 轮各有一个 500–700 ms 的离群 step，属于噪声，不是改动造成的。
- 实测比 §6 的折算小（纯规则 p50 折算 −6 ms，实测 −1.4 ms）。§6 是同一 tick 上重复调用的最小值，不含 GC 和缓存状态，端到端以本表为准。结论：dd4c43d 是小幅改进，主要体现在第 10 日的尖峰上；要明显降低 p50，需要做 §5 里的前 3 个热点。

## 8. 空壳带来的失真

仓库缺 15 个被 preload 的本地脚本（`docs/缺失脚本新位置对照表.md`），沙箱里用“富空壳”代替：每个静态函数接受任意参数、返回空字典；`ReportPolicy.allow` 恒为 true。空壳只在沙箱镜像里，没有提交，也没有改任何引用。它对数字的影响：

| 空壳 | 对耗时的影响 | 方向 |
|---|---|---|
| `corps_structure.gd`（`Structure.behavior_of` 返回 `{}`） | `ArmyCorps.deploy_by_commander` 在 army_corps.gd:141 把字典赋给 `String` 报错中止，军团永远拆不出出战部队：30 日里部队数始终等于军团数（19–20），没有一次接敌，战场、战术结算、围城、`TacticalPlan` 全部没跑到 | 真实游戏偏慢，且慢在本次测不到的阶段 |
| `unit_brain.gd`、`officer_brain.gd`、`officer_autonomy.gd`、`tactical_evaluator.gd`、`tactical_plan.gd` | `UnitBrain.communicate/decide`、`OfficerBrain.deliberate/advice/record_command`、`Autonomy.evaluate_corps/summary_rows` 都立即返回，表中 brains_* 与 tactical_* 约为 0；`commander_context` 里的自治与参军建议也是空的 | 真实值偏大 |
| `report_policy.gd`（`allow` 恒真、`observe` 空） | 军报全部放行，但 `ReportPolicy.observe` 不做事 | 不确定，量级小（军报合计 <0.5%） |
| `army_command_roles.gd`、`battle_objectives.gd`、`city_defense.gd`、`duel_*`、`officer_role.gd` | 任命、战场目标、城防、单挑相关调用为空 | 偏小 |
| 上述报错本身 | 每次运行时类型错误带回溯打印约 0.23 ms（单独测得），每 step 约 9 次，约 2 ms/step 计进了 corps_plan | 真实环境没有这部分 |

不受空壳影响、可以直接参考的结论：`_observe_all` 的深拷贝、`Lifecycle.maintain` 每日两次、战略评估日的重复 `route()`、替身模式下 `plan_background` 每日重复构造主帅上下文、存档序列化的大小与耗时。部队数会随真实军团拆分成倍增加，其中 `_observe_all`（部队数 × 城数，加上部队两两的敌情）和 `context_for` 会随之放大，热点排序大概率不变，只会更突出。

## 9. 结构性优化（perf/step-structural，2026-10-23）

起点 70a62a7（本文 §1–§8 的状态），分支 `perf/step-structural`。按 §5 的热点逐项做，每项一个提交，全部要求结果逐字节不变；做不成就不做，原因写在 §9.7。

| 提交 | 内容 | 新模块 |
|---|---|---|
| 5793d66 | 1 主帅上下文同一军团一天内复用 | `scripts/war/campaign/commander_context_memo.gd` |
| d3d663e | 2 `route()` 记忆 | `scripts/war/campaign/route_memo.gd`，`MapGraph.path_generation()` |
| c1880d2 | 3 `_observe_all` 城池情报复用 | `scripts/war/campaign/observation_reuse.gd` |
| 3bf893f | 4 势力维护按需重算 | `scripts/war/campaign/lord_memo.gd` |
| —（无提交） | 5 军团同日重判错峰：会改变结果，只写建议（§9.7） | — |
| fc700c5 | 6 存档去缩进、后台线程写盘 | `scripts/core/save_writer.gd`，`tests/war/campaign/save_format_validation.gd` |
| f9aa8de | 有接敌的剖析剧本 | `data/war/perf_scenarios/contact_demo.json`，`tools/profile/scenario_setup.gd` |
| fdd0f1e | 新脚本的 `.uid` | — |

所有缓存都按同一个原则失效：**不靠写入方通知**。要么每次使用前核对它依赖的状态与快照是否相同（不同就整表丢弃），要么只活在一段确定没有写入的代码里、遇到写入点显式丢弃。拿不准的依赖一律算进去。

### 9.1 主帅上下文复用（5793d66）

改法：`ArmyCorps.plan_background` 对每个军团每天构造 3–5 次 `commander_context`：取模型答案时复查（有到期答案才构造）、本地兜底、`record_background_order` 里复查、准备新请求。只要中间没有下达军令，这几次的结果逐字节相同。新增 `CommanderContextMemo`，每处理一个军团新建一个，几次构造共用一份。

失效条件：
- `record_background_order` 调 `issue` 之后立即 `invalidate()`，不管军令是否被接受；
- 只认构造它的军团 id；换军团、换日都是新对象，不跨军团、不跨日；
- 复用时照常调用 `Structure.ensure` 与 `Autonomy.evaluate_corps`（`commander_context` 里会改状态的两个本地脚本入口），保持与原先相同的调用次数和副作用；
- 复用的是同一个字典，调用方只改顶层的 `background`、`decision_trigger` 两个标记键，它们每次都重新赋值。

前提（无法在沙箱验证）：`commander_context` 调用的本地脚本（`officer_autonomy.gd`、`officer_brain.gd`、`corps_structure.gd`）对同一状态重复调用结果相同。仓库内的写法支持这一点：`plan()` 本身就在 `commander_context` 前连调两次 `evaluate_corps`。

核对：沙箱补丁让每次复用时另算一份新的并比较 JSON，替身 30 日（答案不落地）410 次复用、（答案即时落地）484 次复用，全部相同。

### 9.2 `route()` 记忆（d3d663e）

改法：`CampaignState.route()` 交给 `RouteMemo`，按（势力，起点，终点）记结果。排除表只取决于各地点的归属和势力关系；路径本身仍由 `MapGraph.path()` 按封锁代数缓存，命中时返回的就是原实现会返回的那个 `MapGraph` 缓存对象。

失效条件（每次调用都核对，约 20–45 µs，原实现一次约 280 µs）：剧本城池表、别名表、路网地点表是不是同一个对象、数量是否变化；每个路网地点对应的城池字典是否被换掉、`faction` 是否变化；势力关系表内容；`MapGraph.path_generation()`（封锁变化或重新 setup 时加一）与封锁、关闭道路的数量。任一不同就整表清空。

核对：沙箱补丁让每次命中时另按原实现算一遍并比较对象与内容，富空壳 harness（183 日）与替身 30 日约 7000 次命中，0 次不同；三个剧本各只清空 1 次（演示剧本里没有城池易手）。

### 9.3 `_observe_all` 城池情报复用（c1880d2）

改法：每支部队原来每次刷新都深拷贝一份全部 72 城情报（全图可见，各部队内容相同），19 支约 8 ms。一天两次刷新：早上那次与前一晚只差 `observed_at`（日期变了），必须重建；晚上那次与早上通常逐项相同（实测演示剧本第 10–20 日每天晚上 72/72 城相同）。`ObservationReuse.cities_for` 在部队上一份城池表与新算的键序、键值都相同时沿用上一份，否则照原样深拷贝。情报外层字典、敌情每次照旧新建。

失效条件：每次刷新都整表比较（原生 `==` 加键序比较，约为深拷贝的 1/5），不相同就深拷贝。复用后新旧两个情报外层字典共用同一个城池表；仓库内没有改写 `intel.cities` 的代码（`context_for` 读取后会深拷贝）。

没做的部分见 §9.7（敌情按势力共享、早上那次的逐城浅拷贝）。

### 9.4 势力维护（3bf893f）

`FactionLifecycle.maintain` 每天两次，约 17 ms（第 13 日），其中逐城任命太守里反复调 `available_officers` 约 9 ms、21 个势力推选君主约 3.7 ms、按势力逐个扫全部城池和武将约 1.2 ms、八十多名生成将每次深拷贝登记约 1 ms。
- `LordMemo`：君主推选（`StrategicAI.lord_of`）只读 `roster.officers`、势力名和武将状态表，特性修正（`Process.value`）只取决于武将字典本身。每次调用核对 `roster.officers` 与武将状态表是否与快照内容相同（约 0.2 ms），不同就整表丢弃、重新快照。核对补丁：替身 30 日 1000 次调用、5 次重快照，0 次不同。
- 逐城任命时同一势力的可用武将只取一次；同一次维护里只有“释放守将”会改武将状态，释放后整表清空。
- 各势力城数、是否还有在任武将一次扫完（原来对每个势力各扫一遍全部城池和武将；只用到是否为空）。
- 生成将登记内容已相同时不再深拷贝。

“只处理变化的势力”没有按势力拆脏标记：太守任命的 `claimed` 跨城、可用武将与在役部队全局相关，拆开要逐势力追踪武将状态与部队变化，收益已被上面几项拿走大半。

### 9.5 存档（fc700c5）

不计入 step，但每日推进后主线程要卡一下。第 25 日存档 2.50 MB：`export_state` 约 29 ms、`JSON.stringify(…, "\t")` 约 71 ms、写盘约 11 ms。实测去掉缩进只省 1.5 ms 的序列化时间（耗时在数据量和按键排序，不在缩进），但文件小 38%。
- 新增 `SaveWriter`：主线程打开文件、做快照（`export_state` 已是深拷贝；城池与编年另做深拷贝），后台线程序列化（仍按键排序、去掉缩进）并原子替换。全进程同一时刻最多一个写盘任务；读档（`_load_save`）、下一次存档、存档对象退出树（`_exit_tree`）前都先等它结束。打开文件失败时与原来一样在快照前返回。
- 读档仍是 `JSON.parse_string`，带缩进的旧档照读。新测试 `tests/war/campaign/save_format_validation.gd`（已加入 `run_battle_suite.gd`）：后台写盘读回与存档时相同；同一状态按旧格式（带缩进）写出后读回，与新格式读回的完整状态逐字节相同；连续两次存档读到后一次。
- 没做 intel 精简与 `sort_keys=false`，原因见 §9.7。

### 9.6 修后耗时

#### 端到端 A/B（`step_latency_validation`）

做法同 §7：同一镜像只换两个提交之间不同的文件，改前、改后交替跑 10 轮，每轮各算 p50/p95/p99，表中是 10 轮的中位数（ms）。镜像先按 f9aa8de 同步并让编辑器扫描一遍，所有新脚本都已登记，每组开跑前把分支动过的文件全部重置到该组的改前提交，后面提交的改动不会漏进任何一边。跑测时机器上没有其他验证，负载均值 1.2–1.9。每组只有 30 个 step，p99 就是最大值（第 10 日的战略评估）。

| 组 | 模式 | 改前 p50 / p95 / p99 | 改后 p50 / p95 / p99 |
|---|---|---|---|
| 70a62a7 → 5793d66（主帅上下文） | 纯规则 | 85.4 / 171.3 / 574.4 | 84.8 / 170.3 / 568.3 |
| | 30 秒替身 | 323.2 / 370.4 / 704.4 | 250.2 / 285.1 / 638.0 |
| 5793d66 → d3d663e（route 记忆） | 纯规则 | 87.5 / 175.9 / 573.4 | 86.5 / 168.0 / 406.5 |
| | 30 秒替身 | 270.1 / 324.9 / 652.8 | 241.5 / 276.1 / 483.6 |
| d3d663e → c1880d2（城池情报复用） | 纯规则 | 88.0 / 164.6 / 404.2 | 77.9 / 150.9 / 399.5 |
| | 30 秒替身 | 241.0 / 270.8 / 469.3 | 226.5 / 266.2 / 459.2 |
| c1880d2 → 3bf893f（势力维护） | 纯规则 | 76.5 / 147.6 / 395.2 | 64.5 / 135.0 / 391.6 |
| | 30 秒替身 | 220.8 / 252.5 / 452.3 | 214.5 / 245.6 / 452.1 |
| **70a62a7 → f9aa8de（合计）** | 纯规则 | 86.5 / 173.4 / 568.5 | **64.7 / 136.4 / 391.9** |
| | 30 秒替身 | 334.6 / 383.3 / 709.6 | **212.7 / 240.9 / 451.0** |

- 合计：纯规则 p50 −25%、p95 −21%、p99 −31%；替身 p50 −36%、p95 −37%、p99 −36%。fc700c5 不在 step 里（存档在 step 之后），f9aa8de 只动剖析工具，fdd0f1e 只加 `.uid`，所以 f9aa8de 的数就是最终分支的数。
- 各项的作用位置与 §5 的预判一致：主帅上下文复用几乎只影响替身模式（p50 −73 ms）；`route()` 记忆削第 10 日尖峰（纯规则 p99 −167 ms，替身 p99 −169 ms）；城池情报复用与势力维护降日常 p50（纯规则各约 −10、−12 ms）。
- 分组改前与上一组改后不完全衔接（如 b1 改后替身 p50 250.2，b2 改前 270.1），差在跑测先后的机器状态，同组内交替跑可以抵消，跨组比较以合计组为准。

#### 存档主线程耗时（fc700c5）

第 25 日状态，`GameState._save()` 在主线程的耗时，每次存档间隔 400 ms（后台写盘已结束），每边 5 轮 × 5 次：改前中位数 127.1 ms（最小 111.3），改后 37.1 ms（最小 30.0），存档 2 504 956 → 1 551 037 字节。剩下的 37 ms 是快照（`export_state` 加城池与编年深拷贝），序列化与写盘在后台线程。

#### 接敌剧本 contact_demo（f9aa8de）

§8 说过演示剧本在空壳下一次接敌都没有，§1–§7 的数字测不到战场与围城。`data/war/perf_scenarios/contact_demo.json` 让演示剧本开局就派出四支独立部队（军令不许撤退）：陶谦与吕布在广陵—下邳道上相向而行，孙坚攻武陵、曹操攻河内。运行：

```
godot --headless --path . --script res://tools/profile/step_profile.gd -- --rounds=1 --modes=rules,mock --scenario=res://data/war/perf_scenarios/contact_demo.json
```

剧本只用于剖析与回归，不进游戏流程；逐日输出哈希，可以直接比对两个版本。纯规则前 9 日（第 4 日起有战场）：

| 日 | 战场 | 围城 | 改前 step | 改后 step | 改后最大的阶段 |
|---|---:|---:|---:|---:|---|
| 1–3 | 0 | 0 | 36–47 ms | 29–45 ms | army_contexts、lifecycle_residence_defenders |
| 4 | 1 | 1 | 50 | 49–53 | contacts_resolve 16 ms |
| 5 | 2 | 2 | 65 | 65 | contacts_resolve 27 ms |
| 6–9 | 2 | 2 | 55–57 | 50–53 | contacts_resolve 约 20.5 ms |

- 有战场之后 `contacts_resolve` 约占 step 的 40%，是新的最大阶段，本次没有动它；前 9 日野战接敌计数（`engaged`）一直是 0，陶谦与吕布那一路在这段时间里还没打起来，两处战场都是围城。
- 这一阶段受空壳影响最大：`tactical_evaluator.gd`、`tactical_plan.gd`、`unit_brain.gd` 都是空壳（§8），真实环境里只会更重。拿到这些脚本后应先在这个剧本上重剖析，再决定是否优化 `contacts_resolve`。

端到端（30 日，改前 70a62a7 与改后 f9aa8de 交替 3 对，两边都用 f9aa8de 的剖析工具，ms，3 对的中位数；最后一列是第 11–30 日 step 的中位数，避开第 10 日尖峰）：

| 模式 | | p50 | p95 | p99 | 第 11–30 日 p50 |
|---|---|---:|---:|---:|---:|
| 纯规则 | 改前 | 168.6 | 261.8 | 612.8 | 177.1 |
| | 改后 | 159.0 | 249.7 | 423.7 | 167.5 |
| 替身 | 改前 | 482.3 | 703.5 | 721.7 | 516.4 |
| | 改后 | 323.8 | 392.9 | 495.7 | 332.6 |

纯规则在接敌剧本里只降约 6%，因为增加的耗时在战场结算，不在本次优化的几处；替身模式降 33–45%，主要来自主帅上下文复用。

### 9.7 没做的项与原因

| 项 | 原因 |
|---|---|
| 5 军团同日重判错峰（§5 #1c） | 把军团首个 `last_plan` 按 id 错开会改变各军团的重判日期，后面的军令、行军和战斗都会跟着变，属于规则变化，不符合“结果逐字节不变”的要求。建议：若设计上接受，按 `hash(corps_id) % 重判间隔` 设初始偏移，预计纯规则 p95 约 −60 ms（§5 的估计），需配套更新回归基线 |
| `context_for` 按 tick 共享只读快照（§5 #1b） | 上下文交给策略与模型，`officer_brain.gd` 等本地脚本可能改写传入的字典，深拷贝是这条边界上的约定；本地缺失的 15 个脚本在沙箱里看不到，无法证明共享安全 |
| 全部部队共享一份城池情报（§5 #2 的完整版） | 只做了“同一部队早晚两次之间复用”（§9.3）。跨部队共享后，任何一处改写某支部队的 `intel.cities` 都会波及所有部队；仓库内只读，但 15 个本地脚本无法核对 |
| 敌情按势力共享 | 同上，跨部队共享的别名风险；收益未单独测量（空壳下部队只有 19–20 支） |
| 早上那次刷新的逐城浅拷贝 | 早上与前一晚每城都差 `observed_at`，浅拷贝后各部队仍要各自持有一份外层，内层字典共享又带来别名风险；收益未单独测量 |
| 存档里的情报精简、`sort_keys=false` | 都会改变存档内容或字节顺序：前者要改读档兼容，后者让同一状态的存档不再逐字节稳定，回归核对（每日 `export_state` 与最终存档的哈希）就失去意义。实测去缩进后耗时主要在数据量和按键排序，后台线程已经把这部分移出主线程 |
| 势力维护按势力拆脏标记 | 见 §9.4：任命的 `claimed` 跨城，可用武将与在役部队全局相关，收益已被已做的几项拿走大半 |
| `contacts_resolve` | 本次剖析才发现（上表），且受空壳影响最大，等本地脚本齐了再剖析 |

### 9.8 回归核对与前提

每个提交都在自己的镜像里跑一遍完整核对，基线是 §7 用的 pb1（e97cd1f，与 70a62a7 只差文档）。沙箱脚本在 `work/refactor/structural/`（`heavy.sh`、`hcompare.sh`），不提交。

| 提交 | 富空壳 harness（183 条每日哈希） | 富空壳套件（43 项逐项输出） | 空壳套件（check3） | 检验战场 6×32 JSON |
|---|---|---|---|---|
| 5793d66 | 相同 | 42 项相同，step_latency 仅耗时读数不同 | 61 项相同 | md5 相同（771228d0…），PASS |
| d3d663e | 相同 | 同上 | 61 项相同 | 同上 |
| c1880d2 | 相同 | 同上 | 61 项相同 | 同上 |
| 3bf893f | 相同 | 同上 | 61 项相同 | 同上 |
| fc700c5 | 相同 | 同上；另有新增的 save_format_validation（见下） | 原有 61 项相同，另多 save_format_validation 一项（共 62 项，见下） | 同上 |
| f9aa8de | 相同 | 同上 | 同 fc700c5 | 同上 |
| fdd0f1e | 相同 | 同上 | 同 fc700c5 | 同上 |

比对方法同 §7：富空壳逐项输出去掉回溯行后比对；空壳套件用 `compare.py` 比解析错误、全量编译、武将测试、身份 harness 和套件 61 项的结果；战场 JSON 比 md5。全量编译的错误数各提交都是 77 条，与基线相同；加载结果只多出到该提交为止新增脚本的 `LOAD … ok`（累计 1–7 条），原有脚本的加载结果没有变化。`step_latency_validation` 的 `STEP_MS`/`SCHEDULER_MS` 是耗时读数，回归时同机还有其他验证在跑，读数本来就不稳定；两边都因“纯规则底数 p99 超过 16 ms”失败，失败原因相同。

fc700c5 新增的 `tests/war/campaign/save_format_validation.gd` 基线里没有，所以单独说明：空壳下它和其余 59 项一样 FAIL，原因相同（`game_state.gd` 引用缺失脚本，解析失败）；富空壳下它打印 `SAVE_FORMAT_VALIDATION_OK`，但套件仍记为失败，原因是运行中出现 `army_corps.gd:142` 的空壳类型错误（`deploy_by_commander` 拿到空壳返回的字典），与其他战役测试同因，不是存档格式本身的问题。

另有快速核对（每个提交都跑）：富空壳 harness 183 条每日哈希、替身 30 日（答案不落地 / 即时落地）每日哈希、接敌剧本 30 日 × 2 模式逐日哈希，s1–s7 与改前全部相同。各缓存还各有一次性核对补丁（每次命中另按原实现算一遍比较），见 §9.1–§9.4，均为 0 次不同。

**前提（沙箱无法验证）**：主帅上下文复用（§9.1）假设 `commander_context` 调用的本地脚本 `officer_autonomy.gd`、`officer_brain.gd`、`corps_structure.gd` 对同一状态重复调用结果相同、除已保留的调用外没有其他副作用。这三个脚本在仓库里缺失（`docs/缺失脚本新位置对照表.md`），沙箱用空壳代替，所以上面的回归核对覆盖不到它们的真实行为。合并前请在有这些脚本的本地环境跑一遍 `step_profile.gd` 两种模式的逐日哈希，与 70a62a7 比对；若不同，撤回 5793d66 即可，其余提交不依赖它。
