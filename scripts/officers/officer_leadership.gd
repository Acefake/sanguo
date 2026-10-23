class_name OfficerLeadership
extends RefCounted
## 主将给所率部队带来的增益，逐项拆成“属性”和“特性”两个来源，并核对特性上限。
##
## 每一项都直接调用结算里真正用到的 OfficerProcess 函数，不另算一套数：
##   攻（兵种局部执行）  防（接战组织损耗）  行军  士气（光环）  组织恢复  侦察（敌情误差）
##   号令（命令整理+展开）  隐蔽（接触暴露）  攻坚（工事准备）  追击
## 基准是同一支部队换成“子属性全 50、无特性”的将领。属性部分 = 去掉特性后相对基准的变化；
## 特性部分 = 带特性相对去掉特性的变化，来源与幅度取自 TraitRegistry.sources/modifier（已按合计上限夹住）。

const Traits = preload("res://scripts/officers/trait_registry.gd")
const Process = preload("res://scripts/officers/officer_process.gd")
const Card = preload("res://scripts/officers/officer_card.gd")
const NEUTRAL_SKILL := 50

## id → 中文名、读哪些子属性、改它的 hook、越大越好还是越小越好（better=-1 表示原始量越小越好）。
const CHANNELS := [
	{"id": "attack", "label": "攻", "keys": ["膂力", "箭术", "骑术"], "hooks": ["attribute.膂力", "attribute.箭术", "attribute.骑术"], "better": 1},
	{"id": "defense", "label": "防", "keys": ["治军"], "hooks": ["special轮换"], "better": -1},
	{"id": "march", "label": "行军", "keys": ["布阵"], "hooks": ["march行军"], "better": -1},
	{"id": "morale", "label": "士气", "keys": ["威仪"], "hooks": [], "better": 1},
	{"id": "recovery", "label": "组织恢复", "keys": ["治军"], "hooks": ["rally收拢"], "better": 1},
	{"id": "scouting", "label": "侦察", "keys": ["料敌"], "hooks": ["intel误差"], "better": -1},
	{"id": "command", "label": "号令", "keys": ["带兵", "布阵"], "hooks": ["command整理", "formation整队"], "better": -1},
	{"id": "conceal", "label": "隐蔽", "keys": ["奇袭"], "hooks": ["conceal暴露"], "better": -1},
	{"id": "siege", "label": "攻坚", "keys": ["攻坚"], "hooks": ["engineering准备"], "better": 1},
	{"id": "pursuit", "label": "追击", "keys": ["骑术"], "hooks": ["pursuit追击"], "better": 1},
]


## 某个通道的原始量（结算里实际用的值）。ctx 是这次行动的情境（地形、计划类型、情报条件等）。
static func raw(army: Dictionary, channel: String, ctx: Dictionary = {}) -> float:
	match channel:
		"attack": return _execution(army, ctx)
		"defense": return Process.organization_loss_factor(army, ctx)
		"march": return Process.march_time_factor(army, ctx)
		"morale": return 1.0 + Process.aura_strength(army, _rules())
		"recovery": return float(Process.recovery(army)["organization"])
		"scouting": return Process.intel_sigma(army, _with_task(ctx, "intel_interpret"))
		"command": return Process.order_delay_hours(army, ctx)
		"conceal": return Process.conceal_exposure(army, 1.0 - float(ctx.get("visibility_cover", 0.5)), _with_task(ctx, "concealed_approach"))
		"siege": return Process.engineering_rate(army, ctx)
		"pursuit": return Process.pursuit_rate(army, {})
	return 1.0


## 全部通道的增益拆解。value 为相对基准的改善比例（+0.05 即好 5%），正数总是“更好”。
static func breakdown(army: Dictionary, ctx: Dictionary = {}) -> Array:
	var bare := army.duplicate()
	bare["trait_ids"] = []
	var neutral := _neutral(army)
	var rows: Array = []
	for spec in CHANNELS:
		var id := str(spec["id"])
		var full := raw(army, id, ctx)
		var no_traits := raw(bare, id, ctx)
		var base := raw(neutral, id, ctx)
		var traits: Array = []
		var caps: Array = []
		for hook in spec["hooks"]:
			var sources := Traits.sources(army, hook, _with_task(ctx, _task_for(id)))
			for source in sources: traits.append({"name": source["name"], "hook": hook, "value": float(source["value"])})
			if not sources.is_empty(): caps.append(_cap_row(army, hook, _with_task(ctx, _task_for(id)), sources))
		var levels := {}
		for key in spec["keys"]: levels[Card.label(key)] = int(army.get("skills", {}).get(key, NEUTRAL_SKILL))
		rows.append({"channel": id, "label": spec["label"], "value": _gain(full, base, int(spec["better"])), "attribute": {"levels": levels, "value": _gain(no_traits, base, int(spec["better"]))}, "trait": {"sources": traits, "value": _gain(full, no_traits, int(spec["better"])), "caps": caps}})
	return rows


## 只保留有实际改善或削弱（|值| ≥ 0.5%）的通道，按幅度排序，供报告逐项列出。
static func notable(army: Dictionary, ctx: Dictionary = {}) -> Array:
	var rows := breakdown(army, ctx).filter(func(r): return absf(float(r["value"])) >= 0.005)
	rows.sort_custom(func(a, b): return absf(float(a["value"])) > absf(float(b["value"])))
	return rows


## 一行文本：“攻 +3.1%（属性 骑术95 +3.1%）；行军 +12.0%（属性 机动94 +11.2%；特性 善骑 −3%）”。
static func text(rows: Array) -> String:
	var parts: Array = []
	for row in rows:
		var detail: Array = []
		var levels: Dictionary = row["attribute"]["levels"]
		detail.append("属性 %s %+.1f%%" % ["/".join(levels.keys().map(func(k): return "%s%d" % [k, levels[k]])), float(row["attribute"]["value"]) * 100.0])
		if not row["trait"]["sources"].is_empty():
			detail.append("特性 %s %+.1f%%" % ["、".join(row["trait"]["sources"].map(func(s): return str(s["name"]))), float(row["trait"]["value"]) * 100.0])
		parts.append("%s %+.1f%%（%s）" % [row["label"], float(row["value"]) * 100.0, "；".join(detail)])
	return "；".join(parts)


## 上限核对：每个 hook 的合计修正不超过 hooks.json 的合计上限，每个来源不超过其档位上限。
## 返回违规描述，空数组即全部合规。ctx 不同（地形、计划类型）会触发不同特性，调用方按实际情境逐一核对。
static func audit(army: Dictionary, ctx: Dictionary = {}) -> Array[String]:
	var errors: Array[String] = []
	for spec in CHANNELS:
		for hook in spec["hooks"]:
			var hctx := _with_task(ctx, _task_for(str(spec["id"])))
			var sources := Traits.sources(army, hook, hctx)
			if sources.is_empty(): continue
			var row := _cap_row(army, hook, hctx, sources)
			if not bool(row["ok"]): errors.append("%s %s：%s" % [army.get("name", ""), hook, row])
	return errors


static func _cap_row(army: Dictionary, hook: String, ctx: Dictionary, sources: Array) -> Dictionary:
	var kind := str(Traits.hook_spec(hook).get("kind", ""))
	var caps: Dictionary = _caps()
	var total_cap := float(caps.get(kind, {}).get("total", Traits.hook_spec(hook).get("total", 0.0)))
	var ok := true
	var sum := 0.0
	for source in sources:
		var tier := Traits.tier_of(str(source["id"]))
		var band: Dictionary = caps.get(kind, {})
		var single := float(band.get("elite_max" if tier in ["elite", "unique"] else "common_max", band.get("elite_up" if tier in ["elite", "unique"] else "common_up", total_cap)))
		if absf(float(source["value"])) > single + 1e-6: ok = false
		sum += float(source["value"])
	var applied := Traits.modifier(army, hook, ctx)
	if absf(applied) > total_cap + 1e-6: ok = false
	return {"hook": hook, "kind": kind, "sum": sum, "applied": applied, "cap": total_cap, "ok": ok}


static func _gain(value: float, base: float, better: int) -> float:
	if is_zero_approx(base) or is_zero_approx(value): return 0.0
	return value / base - 1.0 if better > 0 else base / value - 1.0


## 兵种局部执行按兵力加权，即 combat_system.power_breakdown 的 unit_skill。
static func _execution(army: Dictionary, ctx: Dictionary) -> float:
	var total := 0.0
	var weighted := 0.0
	for type in Process.EXECUTION_KEYS:
		var amount := float(army.get("units", {}).get(type, 0))
		total += amount
		weighted += amount * Process.unit_execution(army, type, str(ctx.get("terrain", "plains")), _with_task(ctx, "unit_execution"))
	return weighted / total if total > 0.0 else 1.0


static func _neutral(army: Dictionary) -> Dictionary:
	var neutral := army.duplicate()
	var skills := {}
	for key in army.get("skills", {}): skills[key] = NEUTRAL_SKILL
	neutral["skills"] = skills
	neutral["trait_ids"] = []
	return neutral


static func _task_for(channel: String) -> String:
	match channel:
		"scouting": return "intel_interpret"
		"conceal": return "concealed_approach"
	return ""


static func _with_task(ctx: Dictionary, task: String) -> Dictionary:
	if task.is_empty() or ctx.has("task"): return ctx
	var merged := ctx.duplicate()
	merged["task"] = task
	return merged


static var _rules_cache: Dictionary = {}
static var _caps_cache: Dictionary = {}


static func _caps() -> Dictionary:
	if _caps_cache.is_empty(): _caps_cache = JSON.parse_string(FileAccess.get_file_as_string(Traits.HOOKS_PATH))["caps"]
	return _caps_cache


static func _rules() -> Dictionary:
	if _rules_cache.is_empty(): _rules_cache = JSON.parse_string(FileAccess.get_file_as_string("res://data/war/campaign_rules.json"))
	return _rules_cache
