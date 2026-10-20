extends RefCounted
## 让人物特色看得见：部队面板的意图与理由、军报署名、人物卡“适合/吃亏”摘要、给模型的人物上下文。
##
## 理由一律标注来源：属性（流程读的子属性）、特性（registry 里改了该 hook 的特性）、
## 人格（人格轴）、模型（LLM 选的方案）。只解释已经发生的结算，不另算一套数。

const Traits = preload("res://scripts/officers/trait_registry.gd")
const Process = preload("res://scripts/officers/officer_process.gd")
const Conduct = preload("res://scripts/officers/officer_conduct.gd")
const Dissent = preload("res://scripts/agents/officer_dissent.gd")

## 属性达到这个值才在署名里提属性，避免“张苞料敌：……”这种名不副实的署名。
const NOTABLE := 80.0
const INTENTS := {"engage": "正面接战", "flank": "侧翼包抄", "pursue": "追击", "hold": "固守", "defend": "固守", "withdraw": "撤离", "march": "行军", "continue": "推进", "besiege": "围城", "support": "支援", "scout": "侦察", "resupply": "补给"}
const SOURCE_MODEL := "模型"


## 某个 hook 的结果该署谁的名：先找改了它的特性，其次是读它的子属性（够高才提）。
## 返回“颜良恋战”“田丰料敌”这样的前缀；都不够格时返回空字符串。
static func credit(army: Dictionary, hook: String, ctx: Dictionary = {}) -> String:
	var name := str(army.get("name", ""))
	var sources := Traits.sources(army, hook, ctx)
	if not sources.is_empty(): return name + str(sources[0]["name"])
	var reads := str(Traits.hook_spec(hook).get("reads", ""))
	if not reads.is_empty() and Process.value(army, reads, ctx) >= NOTABLE: return name + reads
	return ""


## 署名军报：“田丰料敌：识破林中伏兵”。没有可署之名时原样返回。
static func signed(army: Dictionary, hook: String, text: String, ctx: Dictionary = {}) -> String:
	var prefix := credit(army, hook, ctx)
	return text if prefix.is_empty() else "%s：%s" % [prefix, text]


## 部队面板：当前意图、计划阶段、1–3 条带来源的理由、放弃条件。
## officer 是部队主将的人物字典（人格在人物上，不在部队上）。
static func intent(army: Dictionary, ctx: Dictionary = {}, officer: Dictionary = {}) -> Dictionary:
	var action := str(army.get("action", {}).get("type", "hold"))
	var reasons: Array = []
	var delay := float(army.get("order_delay_hours", 0.0))
	if delay > 0.0: reasons.append({"text": "新命令整理与展开还需 %.1f 小时（带兵 %d、布阵 %d）" % [delay, int(Process.value(army, "带兵")), int(Process.value(army, "布阵"))], "source": "属性"})
	for hook in ["commit投入", "disengage脱离", "pursuit深入", "command整理", "formation整队"]:
		for source in Traits.sources(army, hook, ctx):
			reasons.append({"text": "%s：%s" % [source["name"], Traits.definition(str(source["id"])).get("summary", "")], "source": "特性"})
	var risk := float(officer.get("personality", army.get("personality", {})).get("风险承受", 50))
	if absf(risk - 50.0) >= 25.0: reasons.append({"text": "风险承受 %d，%s" % [int(risk), "敢打敢追" if risk > 50.0 else "宁守勿进"], "source": "人格"})
	if str(army.get("last_decision_source", "")) == "model" and not str(army.get("last_reason", "")).is_empty():
		reasons.push_front({"text": str(army["last_reason"]), "source": SOURCE_MODEL})
	var unique: Array = []
	for reason in reasons:
		if not unique.any(func(r): return r["text"] == reason["text"]): unique.append(reason)
	var abort: Array = ["组织低于 %d 脱离接战" % int(Conduct.disengage_line(army, ctx))]
	if action in ["pursue", "engage", "flank"]: abort.append("追击不超过 %d 步" % Conduct.pursuit_limit(army, ctx))
	if action in ["engage", "flank"]: abort.append("侧翼就位 %d%% 才投入主力" % int(Conduct.commit_readiness(army, ctx) * 100.0))
	return {"intent": INTENTS.get(action, action), "phase": "整理命令" if delay > 0.0 else "执行", "reasons": unique.slice(0, 3), "abort": abort}


## 面板文本：一行意图，后接理由（带来源）与放弃条件。
static func intent_text(army: Dictionary, ctx: Dictionary = {}, officer: Dictionary = {}) -> String:
	var data := intent(army, ctx, officer)
	var lines: Array = ["%s · %s" % [data["intent"], data["phase"]]]
	for reason in data["reasons"]: lines.append("［%s］%s" % [reason["source"], reason["text"]])
	lines.append("放弃条件：" + "；".join(data["abort"]))
	return "\n".join(lines)


## 人物卡摘要：“适合做什么”来自优势与专属特性，“遇到什么会吃亏”来自局限特性。
static func card(officer: Dictionary) -> Dictionary:
	var suits: Array = []
	var weak: Array = []
	for id in officer.get("trait_ids", []):
		var definition := Traits.definition(str(id))
		var line := "%s：%s" % [definition.get("name", id), definition.get("summary", "")]
		if str(definition.get("tier", "")) == "flaw": weak.append(line)
		else: suits.append(line)
	return {"suits": suits, "weak": weak}


## 给模型的人物上下文：核心定义、生效特性（名称+摘要）、与同军团者的关系。
static func model_profile(officer: Dictionary, colleagues: Array = []) -> Dictionary:
	var traits: Array = []
	for id in officer.get("trait_ids", []):
		var definition := Traits.definition(str(id))
		traits.append({"name": definition.get("name", id), "tier": definition.get("tier", ""), "effect": definition.get("summary", "")})
	var relations: Array = []
	for other in colleagues:
		if str(other.get("id", "")) == str(officer.get("id", "")): continue
		var relation := Dissent.relation(officer, other)
		if relation != "中立": relations.append({"name": other.get("name", ""), "relation": relation})
	return {"name": officer.get("name", ""), "personality": officer.get("personality", {}), "core": str(officer.get("profile_note", "")), "traits": traits, "relations": relations}
