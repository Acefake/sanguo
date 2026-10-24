extends RefCounted
## 人物 AI 运行参数：读 data/people/ai_runtime.json（时限、优先级价值、并发、日志路径、模型预设）。
##
## 这是配置边界：文件只在这里解析一次，缺项回落到同名默认值，其余代码按字段取用、不再校验。
## 模型名只出现在 JSON 的 presets 里，代码不写死任何模型。

const PATH := "res://data/people/ai_runtime.json"
const DEFAULTS := {
	"deadline_ms": {"commander": 8000, "army": 8000, "unit": 6000, "adviser": 6000},
	"value": {"commander": 3.0, "army": 2.0, "unit": 1.0, "adviser": 1.0},
	"concurrency": {"local": 1, "cloud": 5},
	"commit_delay_ticks": 1,
	"latency_window": 200,
	"decision_log": "user://people_decisions.jsonl",
	"api_key_env": ["SANGUO_MODEL_API_KEY"],
	"presets": {},
}

static var _cache: Dictionary = {}


## 完整配置（首次调用时读文件，之后复用）。
static func config() -> Dictionary:
	if _cache.is_empty():
		_cache = DEFAULTS.duplicate(true)
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(PATH))
		if parsed is Dictionary: _cache.merge(parsed, true)
		else: push_warning("ai_runtime.json 无法解析，使用默认参数")
	return _cache


## 某类决策的现实时限（毫秒）。
static func deadline_ms(kind: String) -> int:
	return int(config()["deadline_ms"].get(kind, 6000))


## 某类决策问模型的价值，用于队列优先级。
static func value(kind: String) -> float:
	return float(config()["value"].get(kind, 1.0))


## 某条通道（local / cloud）的并发上限。
static func concurrency(lane: String) -> int:
	return maxi(1, int(config()["concurrency"].get(lane, 1)))


## 某个预设的某个通道（select / speak），没有则为空。
static func preset(name: String, channel: String = "select") -> Dictionary:
	return config()["presets"].get(name, {}).get(channel, {})


## 按 api_key_env 顺序取第一个非空环境变量；都没有则为空串。
static func api_key_from_env() -> String:
	for name in config()["api_key_env"]:
		var found := OS.get_environment(str(name)).strip_edges()
		if not found.is_empty(): return found
	return ""
