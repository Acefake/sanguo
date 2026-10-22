class_name WarStateKeys
extends RefCounted
## CampaignState.state 顶层键（即战役存档的顶层字段）。值就是存档里的键名，改值等于改存档格式。
##
## 用法：脚本里 `const StateKeys = preload("res://scripts/war/campaign/war_state_keys.gd")`，
## 然后 `war.state[StateKeys.ARMIES]`。GDScript 编译期把它折叠成字符串常量，运行期没有额外开销。
## 只管顶层键；军队、军团等记录内部的键仍是字面量。tests/ 与 tools/ 保留字面量，作为存档格式的独立校验。

## 存档结构版本号。
const VERSION := "version"
## 战斗 AI 数据版本号。
const BATTLE_AI_VERSION := "battle_ai_version"
## 战役日序（每推进一日加一）。
const TICK := "tick"
## 战斗回合序号，供将领经验记忆计龄。
const BATTLE_ROUND := "battle_round"
## 下一个军队、军团等实体的自增编号。
const NEXT_ID := "next_id"
## 玩家势力 id。
const PLAYER_FACTION := "player_faction"
## 战役是否已正式开始。
const CAMPAIGN_STARTED := "campaign_started"
## 战役结果（胜负与提示），未结束时不存在或为空。
const CAMPAIGN_RESULT := "campaign_result"
## 势力之间的关系表。
const RELATIONS := "relations"
## 各势力的存续状态与城池数。
const FACTION_STATUS := "faction_status"
## 非玩家势力本旬剩余行动点。
const FACTION_ACTION_POINTS := "faction_action_points"
## 各城的防守与重建方针。
const CITY_POLICIES := "city_policies"
## 全部军队，按 id 索引。
const ARMIES := "armies"
## 全部军团，按 id 索引。
const CORPS := "corps"
## 玩家尚未下达的军团计划草案。
const PENDING_CORPS_PLAN := "pending_corps_plan"
## 分兵等任务，按军队 id 索引。
const MISSIONS := "missions"
## 各城的围城状态。
const SIEGES := "sieges"
## 各城守军出击的冷却（上次出击的日序）。
const DEFENSE_COOLDOWNS := "defense_cooldowns"
## 各城的守将。
const GARRISON_COMMANDERS := "garrison_commanders"
## 当前（主）战场棋盘。
const BATTLEFIELD := "battlefield"
## 正式战役中的多个独立战场，按 battle_id 索引。
const BATTLEFIELDS := "battlefields"
## 本日城头箭雨记录，供表现层播放。
const CITY_VOLLEYS := "city_volleys"
## 各战场的战况反馈账本。
const BATTLE_FEEDBACK := "battle_feedback"
## 各将领最近一次胜仗的日序。
const BATTLE_VICTORIES := "battle_victories"
## 军报（含待送达与已送达）。
const REPORTS := "reports"
## 军报发送策略的去重记录。
const REPORT_POLICY := "report_policy"
## 各势力的侦察情报。
const FACTION_INTEL := "faction_intel"
## 决策记录。
const DECISIONS := "decisions"
## 势力战略 AI 的决策日志。
const STRATEGY_LOG := "strategy_log"
## 武将状态（出征、养伤、所在城等）。
const OFFICER_STATES := "officer_states"
## 武将去向（阵亡、被俘等）。
const OFFICER_FATES := "officer_fates"
## 武将的部队杀敌累计。
const OFFICER_KILLS := "officer_kills"
## 武将本人杀敌累计。
const OFFICER_PERSONAL_KILLS := "officer_personal_kills"
## 武将本人击杀的兵卒累计。
const OFFICER_PERSONAL_SOLDIERS := "officer_personal_soldiers"
## 将领智能体的持久数据。
const OFFICER_AGENTS := "officer_agents"
## 生成将的人物数据（存档时一并保存）。
const GENERATED_OFFICERS := "generated_officers"
## 单挑记录、配对与次数。
const DUELS := "duels"
## 战役随机数发生器状态（字符串保存）。
const RNG_STATE := "rng_state"
## 违令判定的种子。
const DISSENT_SEED := "dissent_seed"
## 违令判定随机数的延续状态。
const DISSENT_STATE := "dissent_state"
## 战斗 AI 影子对比记录（不存档）。
const BATTLE_AI_SHADOW := "battle_ai_shadow"
## 战斗 AI 统计（不存档）。
const BATTLE_AI_METRICS := "battle_ai_metrics"
## 战斗 AI 消息记录（数组，读档时带入）。
const BATTLE_AI_MESSAGES := "battle_ai_messages"
## 战斗 AI 模型调用日志（数组，读档时带入）。
const BATTLE_AI_MODEL_LOG := "battle_ai_model_log"
## 战斗 AI 回放记录（数组，读档时带入）。
const BATTLE_AI_REPLAY := "battle_ai_replay"
