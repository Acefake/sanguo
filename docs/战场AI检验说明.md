# 战场 AI 检验说明

分支 `feat/combat-officer-identity`，2026-10-23。用 6 个数据驱动的检验战场检验人物（武将）能否独立判断、按自己的战术行动，并按能力给所率部队带来增益。跑测结果见 [validation/battlefield-ai.md](validation/battlefield-ai.md)。

## 1. 怎么运行

```
python tools/validate/validate_battlefields.py
godot --headless --path . --script res://tests/officers/officer_intent_validation.gd
godot --headless --path . --script res://tests/war/proving/proving_ground_view_validation.gd
godot --headless --path . --script res://tests/war/proving/battlefield_runner.gd -- --seeds=32 --out=C:/tmp/bf.json [--only=<战场id>] [--log=C:/tmp/bf.jsonl]
python tools/report/battlefield_report.py C:/tmp/bf.json docs/validation/battlefield-ai.md --compact docs/validation/battlefield-ai.json
```

- 跑测器最后一行 `BATTLEFIELD_AI: PASS` 才算通过，失败时逐条列出，退出码 1。
- `--log` 把每个决策点写成一行 JSON：看到的态势、各姿态得分、选择、理由、参军进言、压力失误、生效增益及来源、上限核对、该部最终结果。32 种子约 30 MB，不提交。
- 游戏里看：开始界面点“人物 AI 检验战场”，或直接打开 `res://scenes/war/proving_ground.tscn`。界面不读 GameState，所以快照里缺本地脚本也能打开。

跑测器的硬断言：

1. 数据引用无误。
2. 每个战场 `compare` 列的试验对，同一支部队的决策分布显著不同：每场各决策点所选姿态的占比，同种子配对置换检验 p<0.01，且总变差 ≥0.10。
3. `expect` 列的定向预期成立，比如“颜良比于禁更多强攻”“文丑比张郃更常中伏”“开局张辽更常选侧击”。
4. 镜像试验：同一人物放到对称的另一侧，决策分布的总变差 <0.15。
5. 每个决策点都用 `OfficerLeadership.audit` 核对增益上限，必须零违规。
6. 不含禁用机制：扫描新模块源码与数据，不得出现技能按钮、冷却、怒气、等级压制等字段；姿态表只允许偏好字段。
7. 可复现：每个战场第一个试验的前 3 个种子重跑，结果逐字相同。

## 2. 战场清单

数据在 `data/scenarios/battlefields/<id>.json`。每个战场写明区域与道路、双方部队与主将/参军、初始态势、胜负目标、要检验的 AI 行为（`checks`）、试验（`trials`，只换某支部队的主将或参军）、对照（`compare`）和定向预期（`expect`）。

| id | 战场 | 检验什么 |
|---|---|---|
| `baima_relief` | 白马解围（声东击西） | 荀攸一路公开佯攻延津，张辽一路可走濮阳林道隐蔽东来。围城主将识破隐蔽来援后转入坚守还是继续攻城；解围主将选侧击还是直救；参军沮授的进言 |
| `yanjin_lure` | 延津诱敌（辎重诱饵） | 追击方会不会被辎重和“敌退”引进南阪伏地（争抢辎重的一刻组织下降）；诱敌方主将会不会弃辎重诱敌；参军田丰的提醒 |
| `wuchao_raid` | 乌巢夜袭（奇袭补给） | 袭粮方是否选奇袭；隐蔽行军被发现后全军警戒；袁营主帅在乌巢告急时救粮还是攻营，参军郭图、沮授的建议不同 |
| `guandu_siege` | 官渡营垒对峙（坚守/攻坚） | 攻方强攻还是先做攻具、等不等侧翼（急躁、好谋少决体现在投入时机上）；守方坚守、出营还是弃营；刚愎者是否否决参军 |
| `cangting_pursuit` | 仓亭追击（撤退与追击） | 追击方追多深（穷追越过安全深度会遭反扑）、会不会追进仓亭林伏兵；撤退方直退、设伏还是回身迎战 |
| `mirror_plain` | 对照：镜像平原 | 双方兵力、编成、地形完全对称，只换西军主将（东军为常将：子属性全 60、人格 50、无特性）；同一人物换到东军，结果应当镜像 |

“常将”和战场里带“假设对照”字样的试验（于禁围白马、文丑追仓亭）都不是史实，只用来做对照。

## 3. 决策模块

接入点盘点：仓库里的决策链是 `campaign_state → baseline_policy`（军级 engage/flank/pursue/withdraw/support 打分）→ `agent_adapter`（模型）。单位级的 `choose/rank` 走 `tactical_evaluator`、`officer_brain`，`unit_brain`、`tactical_plan`、`officer_autonomy` 也依赖它们，这几个都是缺失脚本；`tactical_battlefield` 依赖缺失的 `city_defense`。所以人物“自己想”的那一层做成 `scripts/officers/` 下一个自包含、可插拔的模块，只用仓库里已有的 `officer_process`、`officer_conduct`、`trait_registry`、`combat_system`。

```
战场真值 ──OfficerAwareness.perceive──▶ 本人看到的态势（features + seen）
                                          │
                     OfficerIntent.decide ▼   打分：base + Σ态势×权重 + Σ能力 + Σ人格
                                     姿态 + 理由（带来源）
                                          │  OfficerIntent.consult（参军进言，按 advice_adoption）
                                          │  OfficerIntent.pressure_slip（压力失误，按 pressure_error）
                                          ▼
               ProvingGroundSim：姿态 → 去哪、打谁、守不守；结算走 combat_system 与 OfficerProcess
                                          │
                     OfficerLeadership ◀──┘   每个决策点记录增益拆解与上限核对
```

| 文件 | 回答的问题 |
|---|---|
| `scripts/officers/officer_awareness.gd`（OfficerAwareness） | 这个人看到了什么：兵力按料敌的 σ 估计（σ 就是 `OfficerProcess.intel_sigma`，多源研判、核报经 intel 条件生效；接战后 σ 减半），同一股敌军的误差方向只抽一次，判断会一直错在同一个方向；隐蔽敌军按奇袭抽暴露、按料敌抽识破（参军识破时按采纳概率转达），每刻都有一次看破机会；风险承受高的人只按一部分算未接战的近处敌军 |
| `scripts/officers/officer_intent.gd`（OfficerIntent） | 他选什么：强攻、坚守、诱敌、侧击、奇袭、追击、撤退、救援八种姿态打分，取最高分；理由取贡献最大的 3 项并标来源（态势/属性/人格/特性/参军） |
| `scripts/officers/officer_leadership.gd`（OfficerLeadership） | 他给部队带来什么：十个通道的增益，拆成属性与特性两个来源，并核对上限 |
| `data/officers/intent_profile.json` | 姿态偏好权重。只有 `base/features/skills/axes/requires/requires_any`，没有任何数值加成 |
| `scripts/war/proving/battlefield_data.gd`（ProvingGroundData） | 读战场、查引用、按试验换人；提供“常将” |
| `scripts/war/proving/battlefield_sim.gd`（ProvingGroundSim） | 逐刻推演（默认 6 小时一刻） |
| `scripts/war/proving/proving_ground_view.gd` | 观看界面 |

### 3.1 态势字段（战场真值 → features）

`OfficerAwareness.perceive(own, truth, ctx, rng, adviser)` 读的 `truth` 字段：`own_strength`、`ally_strength`（同区和正与这股敌军交战的友军）、`enemy_strength`、`enemy_key`、`nearby_strength`（两程内未接战的可见敌军，加上刚才还看得见、现在去向不明的）、`enemy_morale`、`enemy_risk`、`in_contact`、`defense`、`target_fort`、`target_cover`、`enemy_retreating`、`bait`、`own_bait`、`lure_ground`、`flank_route`、`flank_open`、`depot`、`hidden`、`ambushed`、`ambush_ready`、`ally_danger`、`relief_target`、`supply_days`、`objectives`、`deadline_ticks`、`ticks_left`。

它们换算成 0–1（或 −1–1）的特征：兵力比相对本人迎战门槛的余量/不足（门槛读 `Conduct.engage_ratio`）、组织相对本人脱离线（`Conduct.disengage_line`）、敌军动摇、工事、伏地、侧翼暴露、粮囤可袭、友军告急、时限、存粮、诱敌之地、两程内敌军、目标类型等。同一份真值，不同人得到的“占优/该撤”可以不同，因为门槛和估计误差都是人物自己的。

### 3.2 人物差异从哪里来

- 属性：能力项按 `OfficerProcess.u(子属性)` 相对 0.6 进入打分（如侧击读机动、奇袭，诱敌读智计、奇袭、沉着）；料敌决定估计误差与识破伏兵；沉着决定压力失误。
- 人格：风险承受、耐心、贪欲、忠义进入对应姿态；风险承受还决定近处敌军按几成计。
- 特性与局限：全部是条件分支，幅度来自 TraitRegistry，已封顶。
  - 刚愎（程昱）：`Conduct.advice_adoption` −15pp，参军建议更常被否决。
  - 急躁（颜良）、好谋少决（袁绍）：主力是否等侧翼读 `Conduct.commit_readiness`。友军侧击同一目标、就位比例没到本人门槛时，主力原地等；门槛低的人早投入，侧击突然性只剩 `就位比例/0.8×0.5`。战报写“某某投入主力：侧翼就位 x%（本人门槛 y%，颜良急躁）”。
  - 穷追（文丑）、贪功：追击深度读 `Conduct.pursuit_limit`，越过 `pursuit_max_steps` 后每步有反扑风险。
  - 恋战、怯战：脱离线读 `Conduct.disengage_line`。
  - 临危不乱：压力失误 −2pp；过度负责：命令整理与重规划 +5%；临机、合阵、潜行、佯动、多源研判、核报、迂回、伏击、筑垒、梯攻等，在战场情境满足条件时（计划类型、地形遮蔽、情报来源、分统等）自动生效。

### 3.3 增益（OfficerLeadership）

| 通道 | 读的结算函数 | 属性来源 | 可能的特性来源 |
|---|---|---|---|
| 攻 | 兵种局部执行（`unit_execution`，即 `power_breakdown.unit_skill`） | 膂力/射术/骑术 | attribute.* 点数（限 ±6） |
| 防 | 接战组织损耗（`organization_loss_factor`） | 治军 | special轮换（备阵） |
| 行军 | `march_time_factor` | 机动 | march行军（善骑） |
| 士气 | 光环 `aura_strength` | 威仪 | — |
| 组织恢复 | `recovery().organization` | 治军 | rally收拢 |
| 侦察 | `intel_sigma` | 料敌 | intel误差（多源研判、核报、辨迹、援军测时） |
| 号令 | `order_delay_hours` | 统兵、机动 | command整理（合阵、分守、过度负责）、formation整队（城内应援） |
| 隐蔽 | `conceal_exposure` | 奇袭 | conceal暴露（潜行）、attribute.奇袭（佯动） |
| 攻坚 | `engineering_rate` | 攻坚 | engineering准备（筑垒、梯攻） |
| 追击 | `pursuit_rate` | 骑术 | pursuit追击 |

基准是同一支部队换成“子属性全 50、无特性”的将领。属性部分是去掉特性后相对基准的变化，特性部分是带特性相对去掉特性的变化，合计 =(1+属性)(1+特性)−1。属性部分的幅度由 `process_profile.json` 的曲线决定（如兵种执行 ±6%）。特性部分受 `hooks.json` 限制：普通 ±3–5%、卓越 ±8%、合计 ±10%，概率类单来源 2/3pp、合计 5pp，属性点合计 ±6。`audit()` 逐来源、逐 hook 核对，跑测器在每个决策点都调用一次。

### 3.4 推演里的姿态怎么执行

姿态只决定走向、目标和守不守，伤亡与士气全部走 `combat_system`：

- 强攻/救援/追击：走向目标；对方坚守且是区域归属方时吃工事，攻方攻具准备（`engineering_rate`）逐步抵消工事。
- 坚守：原地；归属方在可筑工事的区域加固工事（`engineering_rate`），休整按 `recovery` 恢复。
- 侧击、奇袭：隐蔽行军（偏好有遮蔽的路线），每进一个无敌区域按 `conceal_exposure` 抽一次暴露；与敌同区时，没被看破的一方遭突袭（组织损失、原方案失效、压力），突袭方首刻按 `campaign_rules.combat.flank.flank_attack` 加成。
- 诱敌：退向诱敌之地（或部队自己的佯动目标），放下辎重作饵；进入辎重区的敌军争抢一刻、组织下降。
- 撤退：退向退路，脱离接触时挨一次追击；到退路即算退走。
- 每刻先手轮换；姿态改变时按 `order_delay_hours`（原方案失效时加重规划）扣当刻可用时间。

## 4. 与本地缺失脚本的对接

本分支没有创建、猜写或删除任何缺失脚本，新类名（OfficerAwareness、OfficerIntent、OfficerLeadership、ProvingGroundData、ProvingGroundSim）与缺失脚本按文件名推断的类名（UnitBrain、OfficerBrain、TacticalEvaluator、TacticalPlan、OfficerAutonomy 等）不冲突。要在本地把人物决策接进真实战斗，可以按下面的位置加调用，每条都能单独加：

1. `unit_brain.gd`：组单位上下文时，按 3.1 的字段拼一个 `truth`（兵力、士气、地形工事、两程内敌军、隐蔽敌军、友军告急、粮草、任务），调用 `OfficerAwareness.perceive(unit, truth, ctx, rng, adviser_view)`。`rng` 用每支部队独立的种子流；`unit` 上要带主将的 `skills / trait_ids / personality`（见《人物战斗特色-接入说明》§5.1）。
2. `unit_brain.gd` / `tactical_evaluator.gd`：`OfficerIntent.decide(unit, picture, ctx)` 给出姿态，按 `OfficerIntent.ACTION` 映射到现有动作名（assault→engage、hold→hold、flank/raid→flank、pursue→pursue、withdraw/lure→withdraw、relieve→support）。理由写进 `unit["last_reason"]`，`last_decision_source` 写 `"intent"`。也可以只把 `decision["scores"]` 当作 `tactical_evaluator.rank` 的一个加项。
3. `officer_brain.gd`：参军进言用 `OfficerIntent.consult(commander, decision, adviser_view, advice, rng, ctx)`，采纳概率已含刚愎、善辩等。
4. `unit_brain.gd`：压力失误用 `OfficerIntent.pressure_slip(unit, decision, previous_posture, pressure, rng, ctx)`，压力按《接入说明》§5.7 计算。
5. `tactical_plan.gd`：侧击协同沿用 `Conduct.commit_readiness` 的就位门槛（与本推演 `_waits_for_flank` 相同），把结果写进 `operation.support_ready`。
6. `army_inspector.gd` / `tactical_intent_overlay.gd`：面板可以加一行 `OfficerLeadership.text(OfficerLeadership.notable(army, ctx))`，显示“行军 +24.6%（属性 机动94；特性 善骑 −3%）”。
7. `report_policy.gd`：推演战报里的“遭某某突袭”“投入主力：侧翼就位 x%”“追至第 n 步止步”“粮囤被焚”建议不做去重。

## 5. 战场数据字段

顶层：`id`（与文件名相同）、`name`、`summary`、`history`、`checks`、`ticks`、`tick_hours`、`review_ticks`（例行复核间隔）、`intensity`（战斗强度倍率，把战役日结算的伤害折到战术尺度，属于战场规则，不在人物侧）、`rout`（溃散的士气/组织线）、`ambush_org`、`loot_org`、`burnt_morale`、`counter_risk/loss/org`、`memory_ticks`。

- `zones[]`：`id`、`name`、`terrain`（campaign_rules.terrain 的键）、`x/y`（0–1，观看界面用）、`fort`、`fortifiable`、`cover`。
- `links[]`：`[区域, 区域, 基准小时]`。
- `sides.<side>`：`name`、`supply_days`、`retreat`、`depot.zone`、`baggage`、`lure_zone`、`intel`（independent_groups、cross_checked）、`flags`（route_surveyed 等特性条件）、`objectives[]`、`units[]`。
- `units[]`：`id`、`officer`、`adviser`、`zone`、`troops`、`morale`、`organization`、`role`、`hidden`（开局伏兵）、`open_march`（公开行军的佯动部队）、`objectives`（部队自己的任务，如佯动）、`mind_key`（感知随机流的键，镜像战场让两侧同名）。
- 目标类型：`take`、`hold`、`relieve`（要 `deadline`）、`burn`、`protect`、`destroy`（`ratio`）、`escape`（`ratio`）、`feint`。
- `trials[]`：`id`、`label`、`assign`、`adviser_assign`（空字符串表示去掉参军）、`subject`、`mirror_of`。
- `compare[]`：`[试验A, 试验B, 部队id(可省)]`。`expect[]`：`more_than`（姿态决策占比）、`first_more`（开局第一个决定）、`metric_more/metric_less`（ambushed、pursuit_steps、burn、commit_share 等）。

## 6. 已知局限

- 推演是区域图 + 6 小时一刻的抽象战场，不是 `tactical_battlefield` 的六角格。它的作用是在快照里检验人物决策；真实战斗里的行为还要按第 4 节在本地接入后再看。
- `Process.ambush_read` 沿用现有 process_profile，料敌 57 与 98 的识破率只差约 0.30 对 0.43。所以伏击战里“谁中伏”的差别，主要来自追不追、停不停这类决定，识破本身的差别不大。
- 战场的 `intensity`、工事值、兵力按“能在 3–7 天内分出结果”校准，不对应史实兵力。白马、乌巢里曹军胜率偏低或偏高，都只说明在这些参数下人物选择带来的差别，不代表史实还原。
- 部分对照组差异来自参军与主将的组合（沮授、田丰进言），算作“同一部队换人”的一类。
