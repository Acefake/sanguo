class_name PeopleCaps
extends RefCounted
## 人物系统的数值与选择权重上限（00-总览 R3、R4）。
##
## 数值修正三条通道沿用 data/officers/hooks.json 的上限名：attribute_point ±6 点、percent ±10%、pp ±5 个百分点。
## 心志、习性、心结、记忆只产出效用打分里的 bias：单来源 ±15，合计 ±30。
## 只做夹取，不读写任何状态。

const LIMITS := {"attribute_point": 6.0, "percent": 0.10, "pp": 0.05}
const BIAS_SINGLE := 15.0
const BIAS_TOTAL := 30.0


## 把一个通道的合计修正夹到上限内。通道名不在 LIMITS 里是调用方写错，报错并返回 0。
static func clamp_value(channel: String, value: float) -> float:
	if not LIMITS.has(channel):
		push_error("PeopleCaps：未知通道 %s" % channel)
		return 0.0
	var limit: float = LIMITS[channel]
	return clampf(value, -limit, limit)


## 多个来源的 bias 合成一个打分项：每个来源先夹到 ±15，合计再夹到 ±30。
static func bias(values: Array) -> float:
	var total := 0.0
	for value in values:
		total += clampf(float(value), -BIAS_SINGLE, BIAS_SINGLE)
	return clampf(total, -BIAS_TOTAL, BIAS_TOTAL)
