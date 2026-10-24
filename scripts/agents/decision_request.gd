extends RefCounted
## 一次要问模型的决策：习惯层答案先定好，模型只在提交点之前回来才可能改判。
##
## 字段对应 08b §3.1。fetch 是取模型答案的协程（返回 Dictionary，失败时带 "error"），
## alive 判断情境是否仍有效（军队溃散、军团撤退后返回 false），两者都由提交方提供，
## 队列只调用、不理解它们的内容。

## 全局唯一；ModelQueue.take 用它在提交点取结果。
var request_id: String
## 决策类别（commander / army / unit / adviser，以后有 plan / council_speak 等）。
var kind: String
## 谁的决策；同一 slot 的新请求顶替旧请求。
var actor: String
## 习惯层答案，到提交点模型没回来或被否决时采用。
var default: Dictionary = {}
## 游戏时间：到这一刻必须定。
var commit_tick: int
## 现实时间上限（毫秒），超过即视为超时，槽位释放。
var real_deadline_ms: int
## 发出时的情境指纹，提交时用来判断情境是否已变。
var context_hash: String
## 问模型的价值，参与优先级。
var value: float = 1.0
## 通道：local 或 cloud，决定并发上限。
var lane: String = "cloud"
## 这条通道本请求方允许的并发上限（0 表示只用运行参数）。
var lane_limit: int = 0
## 提交方标识，用于整批取消（如重开战场、改模型配置）。
var owner: int = 0
var fetch: Callable
var alive: Callable


## 同一个人的同一类决策共用一个槽位。
func slot() -> String:
	return kind + "|" + actor


## 优先级 = value / max(1, commit_tick − now)；越临近提交点越先问。
func priority(now_tick: int) -> float:
	return value / maxf(1.0, float(commit_tick - now_tick))


## 情境是否仍有效；未提供 alive 时视为一直有效。
func still_alive() -> bool:
	return not alive.is_valid() or bool(alive.call())
