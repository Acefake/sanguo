class_name OfficerProcess
extends RefCounted
## 属性→战斗流程。
##
## 每项子属性只拥有一个战斗流程，按 GDD 4.2 的 E(x)/u 曲线进入该流程的耗时或概率，
## 不再折成全局伤害乘子：
##   带兵→命令整理  布阵→展开/整队/行军  治军→轮换与组织恢复  沉着→压力失误
##   应变→重规划    料敌→敌情误差/识破伏兵  奇袭→接触暴露  智计→计划遗漏  攻坚→工事准备
##   体魄→疲劳      威仪→士气光环          膂力/箭术/骑术→对应兵种的局部执行  武艺→个人遭遇
## 同一结算里每项属性只读一次；特性修正都经 TraitRegistry 的 hook 进入，已按上限夹住。
## 时间以小时计，日结算用 readiness() 折成“当天还能打多少”。

const Traits = preload("res://scripts/officers/trait_registry.gd")
const PROFILE_PATH := "res://data/officers/process_profile.json"
const EXECUTION_KEYS := {"infantry": "膂力", "archers": "箭术", "cavalry": "骑术"}

static var _profile: Dictionary = {}


static func profile() -> Dictionary:
	if _profile.is_empty(): _profile = JSON.parse_string(FileAccess.get_file_as_string(PROFILE_PATH))
	return _profile


## GDD 4.2：E(x)=x（0–100）；超过 100 后 E(x)=100+5×(1−exp(−(x−100)/10))，E(120)≈104.32。
static func effective(x: float) -> float:
	if x <= 100.0: return maxf(x, 0.0)
	return 100.0 + 5.0 * (1.0 - exp(-(x - 100.0) / 10.0))


## 本任务的属性视图：当前值加特性点数（已限 ±6）后夹在 0–120，再做 E 换算。
static func value(army: Dictionary, key: String, ctx: Dictionary = {}) -> float:
	var raw := float(army.get("skills", {}).get(key, 50)) + Traits.attribute_points(army, key, ctx)
	return effective(clampf(raw, 0.0, 120.0))


## u(x)=E(x)/105，所有流程公式的输入。
static func u(army: Dictionary, key: String, ctx: Dictionary = {}) -> float:
	return value(army, key, ctx) / 105.0


static func strength(army: Dictionary) -> int:
	var count := 0
	for amount in army.get("units", {}).values(): count += int(amount)
	return count


static func _with(army: Dictionary, hook: String, ctx: Dictionary, base: float) -> float:
	return base * (1.0 + Traits.modifier(army, hook, ctx))


## 新命令传到各部的整理耗时。容量 2+floor(6u) 个标准单元，超出部分按比例排队。
static func command_hours(army: Dictionary, ctx: Dictionary = {}) -> float:
	var p: Dictionary = profile()["command"]
	var level := u(army, "带兵", ctx)
	var capacity := float(p["capacity_base"]) + floorf(float(p["capacity_per_u"]) * level)
	var recipients := maxf(1.0, ceilf(float(strength(army)) / float(p["standard_unit"])))
	var queue := maxf(1.0, recipients / capacity)
	return _with(army, "command整理", ctx, float(p["hours"]) * (1.2 - 0.4 * level) * queue)


## 展开或整队耗时；ctx.terrain 决定地形倍率。
static func formation_hours(army: Dictionary, ctx: Dictionary = {}) -> float:
	var p: Dictionary = profile()["formation"]
	var terrain_factor := float(p["terrain"].get(str(ctx.get("terrain", "plains")), 1.0))
	return _with(army, "formation整队", ctx, float(p["hours"]) * terrain_factor * (1.3 - 0.5 * u(army, "布阵", ctx)))


## 单位路程的相对耗时，1.0 约为布阵 60 的将领。
static func march_time_factor(army: Dictionary, ctx: Dictionary = {}) -> float:
	return _with(army, "march行军", ctx, 1.3 - 0.5 * u(army, "布阵", ctx))


## 前后排轮换一次的耗时；越短，接战中的组织损失越小。
static func rotation_hours(army: Dictionary, ctx: Dictionary = {}) -> float:
	return _with(army, "special轮换", ctx, float(profile()["rotation"]["hours"]) * (1.15 - 0.25 * u(army, "治军", ctx)))


## 所部弓兵第一次齐射的队形/信号准备耗时。
static func volley_hours(army: Dictionary, ctx: Dictionary = {}) -> float:
	return _with(army, "special齐射", ctx, float(profile()["volley"]["hours"]) * (1.15 - 0.25 * u(army, "箭术", ctx)))


## 获知原方案失效后到新命令成形的耗时。
static func replan_hours(army: Dictionary, ctx: Dictionary = {}) -> float:
	return _with(army, "replan重规划", ctx, float(profile()["replan"]["hours"]) * (1.35 - 0.55 * u(army, "应变", ctx)))


## 一道新命令从下达到部队按新命令作战的总延迟：命令整理 + 展开整队（+ 原方案失效时的重规划）。
static func order_delay_hours(army: Dictionary, ctx: Dictionary = {}, plan_invalid: bool = false) -> float:
	var hours := command_hours(army, ctx) + formation_hours(army, ctx)
	if plan_invalid: hours += replan_hours(army, ctx)
	return hours


## 下达新命令时调用：把延迟记在部队上，供当天的交战折算。
static func issue_order(army: Dictionary, ctx: Dictionary = {}, plan_invalid: bool = false) -> float:
	var hours := order_delay_hours(army, ctx, plan_invalid)
	army["order_delay_hours"] = float(army.get("order_delay_hours", 0.0)) + hours
	return hours


## 当天还能按现行命令作战的比例；延迟跨日时次日继续扣。
static func readiness(army: Dictionary) -> float:
	var day := float(profile()["day_hours"])
	return clampf(1.0 - float(army.get("order_delay_hours", 0.0)) / day, float(profile()["readiness_floor"]), 1.0)


## 日终结转：已消耗的一天从延迟里扣掉。
static func end_day(army: Dictionary) -> void:
	var left := float(army.get("order_delay_hours", 0.0)) - float(profile()["day_hours"])
	if left > 0.0: army["order_delay_hours"] = left
	else: army.erase("order_delay_hours")


## 压力下的决策失误概率；压力为 0 时不制造失误。
static func pressure_error(army: Dictionary, pressure: float, ctx: Dictionary = {}) -> float:
	if pressure <= 0.0: return 0.0
	return clampf(pressure * (0.45 - 0.3 * u(army, "沉着", ctx)) + Traits.modifier(army, "pressure失误", ctx), 0.0, 0.45)


## 隐蔽行动在一个接触窗口里被看见的概率；complexity 越高越难藏。
static func conceal_exposure(army: Dictionary, complexity: float, ctx: Dictionary = {}) -> float:
	var p0 := float(profile()["conceal"]["p0"])
	return clampf(p0 + 0.25 * complexity - 0.2 * u(army, "奇袭", ctx) + Traits.modifier(army, "conceal暴露", ctx), 0.05, 0.95)


## 敌情估计的相对标准差。
static func intel_sigma(army: Dictionary, ctx: Dictionary = {}) -> float:
	return _with(army, "intel误差", ctx, float(profile()["intel"]["sigma0"]) * (1.0 - 0.4 * u(army, "料敌", ctx)))


## 伏兵已暴露时，本军把迹象正确解读为伏兵的概率。
static func ambush_read(army: Dictionary, ctx: Dictionary = {}) -> float:
	var p: Dictionary = profile()["ambush"]
	var relative := intel_sigma(army, ctx) / float(profile()["intel"]["sigma0"])
	return clampf(1.0 - float(p["misread_weight"]) * relative + Traits.modifier(army, "ambush识破", ctx), float(p["floor"]), float(p["cap"]))


## 按 σ 给出一个带噪声的估计值；rng 由调用方的独立种子流提供。
static func estimate(true_value: float, army: Dictionary, rng: RandomNumberGenerator, ctx: Dictionary = {}) -> float:
	return maxf(0.0, true_value * (1.0 + rng.randfn(0.0, intel_sigma(army, ctx))))


## 计划遗漏概率；difficulty 为认知内已有约束的难度 0–1。
static func plan_omission(army: Dictionary, difficulty: float, ctx: Dictionary = {}) -> float:
	return clampf(float(profile()["plan"]["base"]) + 0.3 * difficulty - 0.3 * u(army, "智计", ctx) + Traits.modifier(army, "plan遗漏", ctx), 0.03, 0.8)


## 将领对某兵种的局部执行，窄幅 ±6%：膂力→步兵，箭术→弓兵，骑术→骑兵；水上另读水练。
## 旧 25 键没有兵种适性，这里以对应子属性代读，待适性数据到位后替换。
static func unit_execution(army: Dictionary, type: String, terrain: String = "plains", ctx: Dictionary = {}) -> float:
	var span := float(profile()["execution"]["span"])
	var value_ := 1.0 + span * (u(army, EXECUTION_KEYS[type], ctx) - 0.5)
	if terrain in ["river", "ford"]: value_ *= 1.0 + span * (u(army, "水练", ctx) - 0.5)
	return value_


## 接战中组织损失的倍率，治军 63、无特性时约为 1。
static func organization_loss_factor(army: Dictionary, ctx: Dictionary = {}) -> float:
	var reference := float(profile()["rotation"]["hours"]) * (1.15 - 0.25 * 0.6)
	return rotation_hours(army, ctx) / reference


static func fatigue_cost(army: Dictionary, base: float, fighting: bool = false) -> float:
	return _with(army, "fatigue疲劳", {"in_contact": fighting}, base * (1.2 - 0.4 * u(army, "体魄")))


static func recovery(army: Dictionary) -> Dictionary:
	var p: Dictionary = profile()["recovery"]
	return {
		"fatigue": float(p["fatigue"]) * (0.8 + 0.4 * u(army, "体魄")),
		"organization": _with(army, "rally收拢", {"resting": true}, float(p["organization"]) * (0.8 + 0.4 * u(army, "治军"))),
		"morale": float(p["morale"]) * (0.8 + 0.4 * u(army, "威仪")),
	}


static func march_speed(army: Dictionary, terrain: String = "plains") -> float:
	var p: Dictionary = profile()["march"]
	var speed := float(p["base"]) / march_time_factor(army, {"terrain": terrain}) - float(army.get("fatigue", 0)) / float(p["fatigue_divisor"])
	if bool(army.get("victory_chain", false)) and not bool(army.get("opening_used", false)):
		speed *= float(Traits.mechanism(army, "victory_chain").get("march", 1.0))
	return clampf(speed, float(p["min"]), float(p["max"]))


## 攻坚/工事准备速率倍率（读攻坚；生成将与守备将的攻坚按模板/默认值给出）。
static func engineering_rate(army: Dictionary, ctx: Dictionary = {}) -> float:
	return 1.0 / _with(army, "engineering准备", ctx, 1.25 - 0.45 * u(army, "攻坚", ctx))


## 敌溃后追击造成损失的速率，已含被追一方的撤离修正。
static func pursuit_rate(pursuer: Dictionary, fleeing: Dictionary) -> float:
	var rate := float(profile()["pursuit"]["rate"]) * unit_execution(pursuer, "cavalry")
	return rate * (1.0 + Traits.modifier(pursuer, "pursuit追击")) * (1.0 + Traits.modifier(fleeing, "withdraw撤离"))


## 个人武勇：武艺六成、膂力四成。只用于个人遭遇与单挑，不进军团伤害。
static func prowess(army: Dictionary, ctx: Dictionary = {}) -> float:
	return value(army, "武艺", ctx) * 0.6 + value(army, "膂力", ctx) * 0.4


## 主将士气光环强度，只读威仪；规则段 officer 的权重与上限沿用 campaign_rules.json。
static func aura_strength(army: Dictionary, config: Dictionary = {}) -> float:
	var section: Dictionary = config.get("officer", {})
	return clampf(maxf(0.0, value(army, "威仪") - 50.0) * float(section.get("aura_skill_weight", 0.003)), 0.0, float(section.get("aura_max", 0.15)))


static func aura_range(army: Dictionary, config: Dictionary = {}) -> int:
	var section: Dictionary = config.get("officer", {})
	var bonus := int(section.get("aura_range_bonus", 1)) if value(army, "威仪") >= float(section.get("aura_range_skill", 80)) else 0
	return int(section.get("aura_range", 3)) + bonus
