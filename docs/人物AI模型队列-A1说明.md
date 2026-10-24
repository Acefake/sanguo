# 人物 AI 模型队列（A1）说明

分支 `feat/ai-model-queue`（基于 `feat/combat-officer-identity` b3e6858），2026-10-23；2026-10-24 移植到新 main（分支 `feat/ai-model-queue-port`，见 §9）。对应设计 08b《智能与流畅》第 3、7、9、10 节的 A1：模型传输从适配器里抽出来，新增 ModelQueue 与提交点，战役主循环不再等待模型。不改战斗数值与规则，代码里没有人名、势力名判断。

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

`user://people_decisions.jsonl`（路径在 `ai_runtime.json` 的 `decision_log`），每个结算过的请求写一行：`request_id`、`kind`、`context_hash`、`commit_tick`、`round`、`default`、`model`、`arrived_before_commit`、`outcome`、`final`、`source`。`final` 是最终采用值。`outcome` 取值：`adopted`、`late`（提交点前没有可用答案：未到、失败或超时）、`expired`（答案到了、情境仍有效，但提交点那回合没被取走）、`stale`（情境已失效：提交点复查时失效，或军团/部队在提交点前已撤退、覆没，调用方没来取）、`illegal`、`vetoed`、`context_changed`。只记经过队列的决策；纯规则决策本来就可复现，不写日志。回放（A4）读这份日志。

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
| `tests/agents/model_queue_validation.gd` | 传输层解码与协议字段；优先级；同人同类顶替且队列不增长；顶替在飞请求后通道要等旧请求返回才放行；出队时情境失效丢弃；超时；提交点早到用模型、晚到用默认；非法答案不采用；溃散后答案丢弃不报错；clear 后旧答案不落地；决策日志最终采用值 | 新 main 套件 PASS |
| `tests/agents/step_latency_validation.gd` | 30 秒替身连跑 30 日战役，测 step 与调度耗时，检查 step 没有挂起、调度 p99 < 16 ms；step 总耗时只打印 `STEP_BUDGET`，不作断言（见 §6.1） | 新 main 套件 PASS |
| `tests/agents/decision_scheduler_validation.gd` | 原有测试，并发设置从调度器改到夹具上 | 新 main 套件 PASS |
| `tests/agents/unit_model_validation.gd` | 用户的原有测试：每轮预算 6 条、队列上限 64 两条断言改为“同人同类顶替不让队列增长、并发不超过夹具上限”；答案只在提交点（下一回合）可取 | 新 main 套件 PASS |

两项新测试已加入 `tests/run_battle_suite.gd`。

### 6.1 step 耗时

新 main（真实 unit_brain / tactical_* 链，2026-10-24，Godot 4.7.2 headless、2 核，单 Godot 进程，`step_latency_validation` 连跑 3 次）：

| | p50 | p95 | p99 |
|---|---|---|---|
| 纯规则 step | 45–58 | 860–1035 | 875–1067 |
| 30 秒替身 step | 31–36 | 870–1003 | 890–1023 |
| 其中决策调度（begin_round + submit + take） | 0.01 | 9.5–9.9 | 9.5–10.1 |

- 30 次 step 都在同一帧内返回，没有挂起。提交 288 个请求、在飞 5 个（云端通道上限），192 个在提交点按默认结算（替身 30 秒不回）。
- 调度耗时每 10 日一次尖峰：参军（adviser）96 个请求一起提交、次日一起作废。移植时测到这两步原来分别约 10–13 ms 与 10–21 ms：队列积到上百条后每次 submit 都整表扫描（平方级），决策日志在提交点同步写盘。现在出队前先看“有人排队的通道是否还有空位”，日志延到下一帧写，96 条一批的 submit 降到约 2–3 ms，调度 p99 约 10 ms。
- step 总耗时远超 16 ms，慢在引擎（纯规则一组就是底数，每 10 日一次战略评估约 0.9–1 s），不在模型等待；替身模式 p50 反而低于纯规则，是同机读数波动。

以下是 2026-10-23 在旧分支（富空壳）上的数，留作对照。

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

1. `scripts/core/game_settings.gd:130` 设置页把 `store.agent.api_key` 填进密钥框（掩码显示）。有环境变量时显示的是环境变量里的密钥，保存时不会写盘。预设下拉框、状态行留给 A2。
2. DecisionScheduler 去掉了旧的内部字段 `concurrency`、`round_budget`、`queue_limit`、`last_batch_ms`、`queue`、`_inflight`、`_submitted`。新 main 的 `unit_brain.gd`、`officer_brain.gd` 不读写这些字段（只用 take/submit/has_pending/invalidate）；`tests/agents/agent_arena.gd` 已改读 `ModelQueue` 的计数。
3. `campaign_state.gd` step 里（改动前就有）：submit 返回 false（包括当天没有请求）时都会给 `dropped_batches` 加一，这个计数偏大。
4. 启用本地慢模型时，下一日提交点对很多决策太紧，会大量回落到默认。按场景设 commit_tick（接敌预警时发、接敌日提交）是 A2/A3 的工作。

## 9. 移植到新 main（2026-10-24）

来源 `feat/ai-model-queue` 85e95b8^..4d8f328（5 个提交），目标 main 7564b84。新 main 的 `scripts/agents` 是用户的真实 AI 链（unit_brain、officer_brain、tactical_*、decision_commit 等），旧分支当时只有空壳。

### 9.1 保留的用户改动

| 用户在 agent_adapter 的改动 | 移植后所在 |
|---|---|
| 并发默认 6→3、决策预算 8→20 s（含读配置的默认值） | `agent_adapter.gd` 不变 |
| `failure_reasons` 按原因计数 | `record_failure(reason)` 计数；队列路径的原因由 `ModelQueue.failure_reason(id)` 给出（模型报错原文或“超过现实时限”），不再一律记成“没有在时限内回复” |
| Ollama `num_ctx` 4096→8192 | `model_client.gd` 的 `chat_payload` |
| HTTP 错误带响应体前 160 字 | `model_client.gd` 的 `decode` |
| `_compact_context` 只给模型 name + personality（去掉 officer_explain） | 保持用户写法 |
| `decision_scheduler.gd` 去掉 `class_name` | 保持（新调度器也不注册全局类名） |

### 9.2 接线

- `campaign_state.gd`（新 main 未拆分）：`decision_alive(key)` 放在 CampaignState 本身，`setup` 时 `planner.alive = decision_alive`；有到期答案的部队当天重判；`take` 传今日上下文、`submit` 传当天执行的默认答案。
- `army_corps.gd`：主帅提案在提交点按今日 `commander_context` 复查。
- `unit_brain.gd` / `officer_brain.gd` 不改：它们调用 `take` 不传今日上下文，按签名一致判断，再走各自的 `model_verdict` / 候选比对；答案只在提交点（下一回合）可取。

### 9.3 移植时新增的修正

- **作废的在飞请求继续占通道**：HTTP 请求不会因顶替、取消、超时而中断，模型服务仍在算它。原实现作废后立即释放槽位，本地通道（并发 1）会同时收到多个请求。现在作废的在飞请求要等 `fetch` 真正返回才释放槽位；`request_id` 被新请求重用时只认本次发出的请求对象。
- 出队判断按通道记排队数，有人排队的通道都满时不扫描队列；决策日志延到下一帧写（见 §6.1）。
- `model_client.decode` 用 JSON 实例解析：模型输出不合法是常见情况，`JSON.parse_string` 会打印引擎 `ERROR`，套件把它判为失败。

### 9.4 回归核对（基线 = main 7564b84 的套件全量输出）

| 核对 | 结果 |
|---|---|
| 原有 64 项（套件 54 项 + 新 main 额外 10 项，含 2 项 SKIP：GPU 截图、真模型服务），逐项状态与日志（去掉耗时读数） | 全部相同；唯一差异是 `war_month_performance_validation` 的回溯行号 `campaign_state.gd:532→533`（该测试改动前就失败，原因是夹具的 preview 缺 `home`） |
| 战役逐日哈希 harness（3 个剧本 183 日） | 逐行相同，完整输出相同 |
| 新增 `model_queue_validation`、`step_latency_validation` | PASS |
| `local_agent_validation`（不在套件） | 改动前后都 FAIL（单候选上下文被分差门判为不必问模型），与本次无关 |

无模型服务（纯规则、或适配器未启用）时不经过队列：`request_for` 返回 null，`submit` 没有请求，`ready` 始终为空，所以与改动前逐字节一致。
