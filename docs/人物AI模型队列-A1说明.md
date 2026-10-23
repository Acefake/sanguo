# 人物 AI 模型队列（A1）说明

分支 `feat/ai-model-queue`（基于 `feat/combat-officer-identity` b3e6858），2026-10-23。对应设计 08b《智能与流畅》第 3、7、9、10 节的 A1：模型传输从适配器里抽出来，新增 ModelQueue 与提交点，战役主循环不再等待模型。不改战斗数值与规则，代码里没有人名、势力名判断。

## 1. 结论

- 战役 `step()` 不再等待模型。问模型的决策当天先执行习惯层答案（默认），请求交给 ModelQueue 后立即返回；到提交点（默认下一日 step）答案已到且复查通过才改判，否则沿用默认。
- 纯规则模式（不启用模型）走的代码路径与改动前相同，不经过队列，也不写决策日志。
- 模型名只出现在 `data/people/ai_runtime.json` 的 presets 里。api_key 优先读环境变量。

## 2. 模块

| 文件 | 职责 |
|---|---|
| `scripts/agents/model_client.gd` | 传输层：Ollama `/api/chat` 与 OpenAI 兼容 `/chat/completions` 的协议字段、OpenRouter 参数（`max_tokens`、关闭 reasoning）、请求头、超时、响应解码。除 `send` 外都是纯函数。 |
| `scripts/agents/model_queue.gd` | Autoload `ModelQueue`：所有模型请求的唯一出口（优先级、并发、顶替、失效丢弃、超时、统计、决策日志）。 |
| `scripts/agents/decision_request.gd` | 一次决策请求：`request_id`、`kind`、`actor`、`default`、`commit_tick`、`real_deadline_ms`、`context_hash`、`value`、`lane`、`fetch`、`alive`。 |
| `scripts/agents/ai_runtime.gd` | 读取 `data/people/ai_runtime.json`（配置边界，只在这里解析）。 |
| `scripts/agents/decision_scheduler.gd` | 每个 CampaignState 一个，负责提交点：把请求交给 ModelQueue，到 commit_tick 决定采用模型答案还是默认答案。对外接口与旧版一致。 |
| `scripts/agents/agent_adapter.gd` | 只负责拼上下文（系统提示词、候选裁剪）和守门（POLICY.veto、本地兜底）。新增 `request_for / fetch / resolve / record_failure`。 |

文件放在 `scripts/agents/`，没有放 08b §7 写的 `scripts/people/ai/`。原因有两个：`scripts/people/` 正由人物系统 P1（`feat/people-p1`）新建和修改，放进去两条分支会冲突；A1 只改战场 AI 的调度，原有的适配器、调度器、基线策略都在 `scripts/agents/`，放在一起按模块就近。等 A2–A4 接入人物数据时，再整体移到 `scripts/people/ai/`。

### 2.1 为什么 ModelQueue 是 Autoload

- `HTTPRequest` 必须挂在场景树上。
- 队列要比 CampaignState 活得久：重开战场、读档都会重建或重置 CampaignState，在飞的请求要能被统一取消，迟到的结果要能被丢弃。
- 并发上限必须对整个进程生效。否则战役、以后的军议和召见各自开请求，会同时压一台本地模型。
- 决策日志只有一个写入者。

在 `project.godot` 里排在 `GameState` 之前。

## 3. 流程

```
step(day T)
  DecisionScheduler.begin_round(T)  ── 结算 commit_tick ≤ T 的请求：没答案 → 默认（记 late）
  每支要决策的部队：
    take(key, 签名, T, 今日上下文) ── 有到期答案：复查（同一行动仍在今日候选里）+ POLICY.veto → 采用
    否则 Policy.choose(今日上下文)  ── 习惯层答案，当天执行
    submit(上下文, default = 当天执行的答案) → ModelQueue.submit → 立即返回（commit_tick = T + 1）
ModelQueue（后台，按帧）
  出队：优先级最高、通道有空位；alive() 为 false 的直接丢弃
  在飞：超过 real_deadline_ms 判超时；答案到达 → DecisionScheduler.ready（只在 commit_tick 那一回合可取）
```

- 优先级 = `value / max(1, commit_tick − now)`；同分时先问最近被服务得少的人。value 按类别读 `ai_runtime.json` 的 `value`（主帅 3、部队 2、单位与参军 1）。
- 并发：`ModelClient.lane(endpoint)` 判断本机（127.0.0.1、localhost、::1）走 `local`，其余走 `cloud`。本地默认 1，云端取 `ai_runtime.json` 的 `concurrency.cloud` 与设置页并发数的较小值。
- 顶替：同一个人同一类决策只留最新请求，排队中的直接替换，在飞或已到未取的结果作废。
- 情境失效：`CampaignContext.decision_alive(key, 弱引用)` 判断部队是否覆没、溃退，军团是否撤退。出队时和提交点各检查一次，失效就丢弃，不报错。
- 有到期答案的部队，即使态势签名没变，当天也会重判一次，让答案按时落地或作废。
- 失败、超时、晚到在提交点统一按“没有可用答案”处理，用默认答案。
- 只实现 `choose_batch` 的适配器（测试夹具）也走队列：每个上下文包成一个请求，答案即最终结果。
- 没有 `supports_background_decisions` 的适配器（几个测试夹具，同步返回）仍按原样在 step 里直接调用 `choose_batch`。`step()` 里保留的两处 `await`（`campaign_state.gd:271`、`:317`，以及 `army_corps.gd:513`）只对这些夹具生效。真实的 AgentAdapter 走 DecisionScheduler，不会进入这两条路径。

### 3.1 决策日志

`user://people_decisions.jsonl`（路径在 `ai_runtime.json` 的 `decision_log`），每个结算过的请求写一行：`request_id`、`kind`、`context_hash`、`commit_tick`、`round`、`default`、`model`、`arrived_before_commit`、`outcome`、`final`、`source`。`final` 是最终采用值。`outcome` 取值：`adopted`、`late`（提交点前没有可用答案：未到、失败或超时）、`expired`、`stale`、`illegal`、`vetoed`、`context_changed`。只记经过队列的决策；纯规则决策本来就可复现，不写日志。回放（A4）读这份日志。

### 3.2 统计

`ModelQueue.stats()`：`submitted`、`calls`、`answers`、`failures`、`timeouts`、`superseded`、`stale`、`late`、`adopted`、`fallbacks`、`vetoes`、`queued`、`inflight`、`p50_ms`、`p95_ms`（最近 200 次）。设置页与军报里显示的仍是 `AgentAdapter.metrics`（本适配器视角），两者不合并。

## 4. 参数与 api_key

`data/people/ai_runtime.json` 是 08b §8 首版，补了 A1 用到的字段：`deadline_ms` 里的 `commander/army/unit/adviser`、`value`、`commit_delay_ticks`、`latency_window`、`decision_log`、`api_key_env`。现实时限取 `deadline_ms[kind]` 与设置页“决策预算”的较小值。

api_key：

1. 按 `api_key_env` 的顺序读环境变量，第一个非空的生效。默认只有游戏专用的 `SANGUO_MODEL_API_KEY`：不读 `OPENROUTER_API_KEY`、`OPENAI_API_KEY` 这类通用变量，免得用户给别的工具设的密钥被发到这里配置的任意接口。
2. 有环境变量时，设置页保存不再把密钥写进 `user://officer_agent.cfg`（写空串）。
3. 没有环境变量时保持原有方式：密钥存在本机 `user://officer_agent.cfg`。这个文件不在存档里，也不在仓库里，旧配置不用改就能继续用。

预设：配置里写 `preset = "local_light"` 等、且接口和模型留空时，从 presets 的 `select` 通道取接口和模型。设置页的预设下拉框属于 A2（`game_settings.gd` 不在本次范围内）。

## 5. 行为变化（只在启用模型时）

- 答案在下一日 step 之前没到就作废。改动前会保留 2–10 个回合，晚到的答案也可能被采用。
- 晚到作废后，部队下次重判会重新提交，所以模型调用会比以前多：30 日替身测试里 25 次，改动前 6 次（改动前请求挂起期间不重复提交）。
- 采用条件从“情境签名必须一致”放宽为“同一行动仍在今日候选里，并通过 veto”（08b §3.1）。旧调用方不传今日上下文时，仍按签名一致判断。
- 被分差规则判为“不必问”的决策不再进 ready、次日重复落地一遍，当天的本地答案就是最终答案。

## 6. 测试

| 测试 | 内容 | 本沙箱结果 |
|---|---|---|
| `tests/agents/model_queue_validation.gd` | 传输层解码与协议字段；优先级；同人同类顶替且队列不增长；出队时情境失效丢弃；超时；提交点早到用模型、晚到用默认；非法答案不采用；溃散后答案丢弃不报错；clear 后旧答案不落地；决策日志最终采用值 | 通过 |
| `tests/agents/step_latency_validation.gd` | 30 秒替身连跑 30 日战役，测 step 与调度耗时，检查 step 没有挂起 | 无挂起、调度 p99 达标；step 总耗时不达标（见 §6.1） |
| `tests/agents/decision_scheduler_validation.gd` | 原有测试，并发设置从调度器改到夹具上 | 依赖缺失脚本，见 §7 |

两项新测试已加入 `tests/run_battle_suite.gd`。

### 6.1 step 耗时

沙箱环境：Godot 4.7.2 headless、2 核且同时有其他验证在跑，缺失脚本用富空壳代替，演示剧本 30 日，单位毫秒，不含渲染。

| | p50 | p95 | p99 | max |
|---|---|---|---|---|
| 纯规则 step | 84.5 | 167.0 | 574.9 | 574.9 |
| 30 秒替身 step | 324.9 | 373.3 | 711.7 | 711.7 |
| 其中决策调度（begin_round + submit + take） | 0.05 | 5.47 | 5.74 | 5.74 |

- 30 次 step 都在同一帧内返回，没有挂起；提交 98 个请求，78 个在提交点按默认结算。
- step 总耗时达不到 16 ms，原因在引擎本身：纯规则的底数在这台机器上已是 p50 84 ms（第一天 575 ms）。替身模式比纯规则慢，改动前就是这样：同一探针在 b3e6858 上替身模式 p50 320 ms，改动后 325 ms。差别来自启用模型时军团后台规划等原有路径，不来自等待。
- 调度耗时每 5 日有一次 4–6 ms 的尖峰（战略 AI 一次派出多支部队）。最初对每个上下文做深拷贝时尖峰是 12–16 ms，改成浅拷贝后降到现在的数值。

## 7. 回归核对

仓库缺 15 个被 preload 的脚本（见 `docs/缺失脚本新位置对照表.md`），本次没有创建、猜测或删除它们的引用。沙箱里用临时空壳运行，空壳只在沙箱镜像里，不提交。`tests/run_battle_suite.gd` 在沙箱里改动前就全部 FAIL（GameState 依赖缺失脚本、缺美术资源），所以“纯规则下与改动前一致”用改动前后逐项输出对比来核对：

| 核对 | 改动前 b3e6858 | 改动后 | 结论 |
|---|---|---|---|
| 解析错误（编辑器两遍） | 5 | 5 | 集合相同 |
| 全量编译错误 | 85 | 85 | 集合相同 |
| 套件逐项输出（空壳环境，59 项） | — | — | 59 项去掉行号与耗时后逐字相同；多出的 2 项是新测试 |
| 富空壳战役 harness（纯规则，3 个剧本约 180 日，每日状态哈希 + 最终存档） | — | — | 1800 行逐字相同 |
| 富空壳套件逐项输出（41 项） | — | — | 41 项相同；`agent_settings_validation` 一度不同，原因是沙箱设了 `OPENROUTER_API_KEY`，已改为只读 `SANGUO_MODEL_API_KEY` 后相同 |
| 检验战场跑测器 6 战场 × 32 种子 | `BATTLEFIELD_AI: PASS` | `BATTLEFIELD_AI: PASS` | 汇总 JSON 与文本报告逐字节相同 |

检验战场跑测器不经过战役调度代码，相同是预期结果。新测试在套件里显示 FAIL，是因为套件把输出里任何 `ERROR:` 都算失败，而沙箱缺 `assets/theme_sanguo.tres`；单独运行 `model_queue_validation` 退出码 0。

## 8. 已知问题

1. `scripts/core/game_settings.gd:128` 设置页把 `store.agent.api_key` 填进密钥框（掩码显示）。有环境变量时显示的是环境变量里的密钥，保存时不会写盘。预设下拉框、状态行留给 A2。
2. DecisionScheduler 去掉了旧的内部字段 `concurrency`、`round_budget`、`queue_limit`、`last_batch_ms`。仓库里没有调用方；只在本地的 `unit_brain.gd`、`officer_brain.gd` 如果直接读写这些字段，需要改为调整 `ai_runtime.json`。
3. `campaign_state.gd:315`（改动前就有）：submit 返回 false（包括当天没有请求）时都会给 `dropped_batches` 加一，这个计数偏大。
4. 启用本地慢模型时，下一日提交点对很多决策太紧，会大量回落到默认。按场景设 commit_tick（接敌预警时发、接敌日提交）是 A2/A3 的工作。
