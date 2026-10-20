extends RefCounted
## 决策侧的倾向与失败模式：什么时候投入、追多深、何时脱离、听不听参军。
##
## officer_process 回答“能否做好”，这里回答“倾向如何选择”。局限特性在这里变成
## 可测的代价：急躁=协同未到位就投入，恋战=到脱离线不走，贪功/追击疏算=越过最大深入，
## 怯战=组织未破先撤，刚愎=否决参军建议。unit_brain / tactical_* 通过这些静态查询接入。

const Traits = preload("res://scripts/officers/trait_registry.gd")
const Process = preload("res://scripts/officers/officer_process.gd")


static func _conduct() -> Dictionary:
	return Process.profile()["conduct"]


## 主力投入前要求的协同就位度（0–1）：侧翼或牵制部队完成就位的比例达到它才投入。
static func commit_readiness(army: Dictionary, ctx: Dictionary = {}) -> float:
	return clampf(float(_conduct()["commit_readiness"]) + Traits.modifier(army, "commit投入", ctx), 0.0, 1.0)


## 追击停止深度（步）。
static func pursuit_limit(army: Dictionary, ctx: Dictionary = {}) -> int:
	return int(_conduct()["pursuit_max_steps"]) + int(Traits.modifier(army, "pursuit深入", ctx))


## 组织低于此值即脱离接战。
static func disengage_line(army: Dictionary, ctx: Dictionary = {}) -> float:
	return float(_conduct()["disengage_line"]) + Traits.modifier(army, "disengage脱离", ctx)


## 主动迎战所需的己方/敌方估计战力比。
static func engage_ratio(army: Dictionary, ctx: Dictionary = {}) -> float:
	return float(_conduct()["engage_ratio"])


## 主将采纳参军建议的概率。
static func advice_adoption(commander: Dictionary, adviser: Dictionary, ctx: Dictionary = {}) -> float:
	return clampf(float(_conduct()["advice_base"]) + Traits.modifier(commander, "advice采纳", ctx) + Traits.modifier(adviser, "advice说服", ctx), 0.0, 1.0)


## 违令概率的特性修正，由 campaign_state 的违令公式相加。
static func dissent_shift(army: Dictionary, ctx: Dictionary = {}) -> float:
	return Traits.modifier(army, "dissent违令", ctx)
