extends RefCounted

# Notifications are opt-in milestones. Urgency affects delivery, never eligibility.
const KEY_EVENTS := ["占领", "破城", "城门攻破", "城墙攻破", "主帅失位", "主将失位", "主将接替", "武将战死", "武将被俘", "军队覆没", "溃败", "战局结果", "战役总结", "战役终结"]

static func eligible(kind: String) -> bool:
	return kind in KEY_EVENTS

static func scope(army: Dictionary) -> String:
	var corps_id := str(army.get("corps_id", ""))
	return corps_id if not corps_id.is_empty() else str(army.get("id", "campaign"))

static func allow(state: Dictionary, army: Dictionary, kind: String, event_key: String = "") -> bool:
	if not eligible(kind): return false
	if not state.has("report_policy"): state["report_policy"] = {"sent": {}}
	var sent: Dictionary = state["report_policy"].get("sent", {})
	state["report_policy"]["sent"] = sent
	var landmark := event_key
	if landmark.is_empty():
		landmark = str(army.get("battlefield_id", "")) + ":" + str(army.get("location", {}).get("node", ""))
		if kind in ["武将战死", "武将被俘", "主将接替", "主将失位", "主帅失位"]:
			landmark += ":" + str(army.get("officer_id", ""))
	var key := "%s:%s:%s" % [scope(army), kind, landmark]
	if sent.has(key): return false
	sent[key] = int(state.get("tick", 0))
	return true

## Records the last position, strength and status each player army was seen with, so the next report can be
## compared against it. Armies without a "location" yet (fixtures built by hand, or an army created mid-setup)
## record an empty location instead of aborting the whole pass; armies that have one are recorded unchanged.
static func observe(war) -> void:
	for army in war.state["armies"].values():
		if army.get("faction", "") != war.state["player_faction"]: continue
		army["last_observation"] = {"location": army.get("location", {}).duplicate(true), "strength": war.Combat.strength(army), "ended": army.get("status", "active") == "ended", "tick": war.state["tick"], "date": war.store.date_text()}

static func migrate(state: Dictionary) -> void:
	# Legacy daily options must not resurrect frequent notifications after loading.
	for army in state["armies"].values():
		if army.get("orders", {}) is Dictionary: army.get("orders", {}).erase("report_level")
	for corps in state["corps"].values():
		if corps.get("standing_orders", {}) is Dictionary: corps.get("standing_orders", {}).erase("report_level")
	state["reports"] = state["reports"].filter(func(report): return report.get("received", false) or eligible(str(report.get("kind", ""))))
