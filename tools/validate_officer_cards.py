"""校验 data/officers.json（人物卡 schema 6）。

    python tools/validate_officer_cards.py

字段契约来自人物系统 GDD v0.3.1 §3.2 与 §8.1：25 项子属性固定键（0–120）与成长潜质、五维派生、
五兵种适性、十类地形经验、特性 id 已登记且数量合规、人格（价值倾向/风险偏好/忠诚三轴）取值 0–1、
有向关系五轴 0–100、岗位、失败模式、来源与推定标记。status=source 的卡必须有 Notion 来源，
status=draft 的卡必须把数值字段列进 inferred。Notion 原文本身违反 GDD 数量预算时，卡上 gdd_exceptions 写明原因，降为警告。全部通过退出 0，否则逐条打印并退出 1。
"""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ATTRS = ["统兵", "攻坚", "机动", "奇袭", "治军", "智计", "沉着", "料敌", "应变", "辩论",
         "膂力", "体魄", "武艺", "骑术", "射术", "农桑", "财赋", "吏治", "法度", "外交",
         "威仪", "仁德", "信义", "名望", "容人"]
DIMS = ["军事", "谋略", "勇武", "政务", "影响"]
TROOPS = ["步兵", "骑兵", "弓弩", "水军", "攻城"]
TERRAIN = ["平原", "丘陵", "山地", "谷道", "森林", "沼泽", "河岸", "城邑", "关隘", "水域"]
VALUES = ["秩序", "个人利益", "群体利益", "承诺", "功业"]
LOYALTY = ["承诺坚持", "组织依附", "私人依附"]
RELATION_AXES = ["信任", "敬重", "恩义", "利益", "怨恨"]
POSTS = {"君主", "主帅", "前锋", "奇兵", "护军", "参军", "军师", "随军", "太守", "外交"}
STATUS = {"source", "draft"}
TRAIT_SOURCES = {"notion", "draft"}
INFERABLE = {"attributes", "potentials", "troop_aptitudes", "terrain_experience", "traits", "personality",
             "personality.flaws", "relations", "posts", "failure_modes", "summary"}
REQUIRED = ["id", "name", "faction", "status", "schema_version", "snapshot", "role", "summary", "attributes", "potentials",
            "five_dims", "troop_aptitudes", "terrain_experience", "traits", "personality", "relations", "posts",
            "failure_modes", "history", "sources", "inferred"]
# Notion 原文的错字；新卡里一个都不许出现。
TYPOS = ["运筹帷幂", "骄秽", "带兽", "带养", "臀力", "故兔", "急造", "尤豫", "记仄"]


def check_card(card, traits, errors, warnings):
    name = card.get("name", card.get("id", "?"))
    err = lambda msg: errors.append(f"{name}: {msg}")
    for key in REQUIRED:
        if key not in card: err(f"缺字段 {key}")
    if errors and errors[-1].startswith(f"{name}: 缺字段"): return
    if card["status"] not in STATUS: err(f"status 只能是 {sorted(STATUS)}")
    if card["schema_version"] != 6: err("schema_version 应为 6")
    attrs, pots = card["attributes"], card["potentials"]
    if list(attrs) != ATTRS: err("attributes 必须是固定 25 键且按 GDD 顺序")
    if list(pots) != ATTRS: err("potentials 必须是固定 25 键且按 GDD 顺序")
    for key in ATTRS:
        value = attrs.get(key)
        if not isinstance(value, int) or not 0 <= value <= 120: err(f"{key}={value!r} 不在 0–120 整数内")
        if pots.get(key) not in ("S", "A", "B", "C"): err(f"{key} 潜质 {pots.get(key)!r} 不是 S/A/B/C")
    if list(card["five_dims"]) != DIMS: err("five_dims 必须是 军事/谋略/勇武/政务/影响")
    else:
        for i, dim in enumerate(DIMS):
            expected = round(sum(attrs.get(k, 0) for k in ATTRS[i * 5:i * 5 + 5]) / 5, 2)
            if abs(card["five_dims"][dim] - expected) > 0.005: err(f"五维 {dim}={card['five_dims'][dim]} 与子属性平均 {expected} 不符")
    if list(card["troop_aptitudes"]) != TROOPS or any(v not in "SABCD" or len(v) != 1 for v in card["troop_aptitudes"].values()):
        err("troop_aptitudes 必须是 步兵/骑兵/弓弩/水军/攻城 五键，取 S/A/B/C/D")
    if list(card["terrain_experience"]) != TERRAIN or any(v not in ("陌生", "熟悉", "精通") for v in card["terrain_experience"].values()):
        err("terrain_experience 必须是十类地形，取 陌生/熟悉/精通")

    counts = {"common": 0, "elite": 0, "unique": 0}
    has_flaw = False
    for entry in card["traits"]:
        tid = entry.get("id")
        definition = traits.get(tid)
        if definition is None: err(f"特性 {tid} 未在 data/officers/traits.json 登记"); continue
        if tid.startswith("flaw_"): err(f"{tid} 是人格型局限，应写在 personality.flaws"); continue
        if entry.get("source") not in TRAIT_SOURCES: err(f"特性 {tid} 的 source 应为 notion 或 draft")
        tier = definition["tier"]
        has_flaw |= tier == "flaw"
        counts["common" if tier in ("common", "flaw") else tier] += 1
    if counts["common"] > 3 or counts["elite"] > 2 or counts["unique"] > 1 or sum(counts.values()) > 5:
        exception = card.get("gdd_exceptions", {}).get("trait_budget", "")
        if card["status"] == "source" and exception: warnings.append(f"{name}: 技术特性数量 {counts} 超出 GDD 8.1，按原文保留——{exception}")
        else: err(f"技术特性数量 {counts} 超出 GDD 8.1（普通≤3、卓越≤2、专属≤1、总数≤5）")

    p = card["personality"]
    if list(p.get("values", {})) != VALUES: err("personality.values 必须是 秩序/个人利益/群体利益/承诺/功业")
    if list(p.get("loyalty", {})) != LOYALTY: err("personality.loyalty 必须是 承诺坚持/组织依附/私人依附")
    numbers = list(p.get("values", {}).values()) + list(p.get("loyalty", {}).values()) + [p.get("risk_preference")]
    numbers += list(p.get("decision_weights", {}).values()) + ([p["defense_preference"]] if "defense_preference" in p else [])
    if any(not isinstance(v, (int, float)) or not 0 <= v <= 1 for v in numbers): err("人格数值必须在 0–1")
    if not str(p.get("behavior", "")).strip(): err("personality.behavior 为空")
    flaws = p.get("flaws", [])
    if len(flaws) > 2: err("人格型局限超过 2 个")
    for flaw in flaws:
        definition = traits.get(flaw.get("id"))
        if definition is None or definition["tier"] != "flaw" or not flaw["id"].startswith("flaw_"): err(f"人格型局限 {flaw.get('id')} 未登记或不是 flaw_*")
        if flaw.get("inferred") and not str(flaw.get("basis", "")).strip(): err(f"推定局限 {flaw.get('id')} 缺 basis")
        has_flaw = True
    if not has_flaw and not str(card.get("no_flaw_reason", "")).strip(): err("没有局限，也没写 no_flaw_reason")

    for edge in card["relations"]:
        if not str(edge.get("to", "")).strip(): err("关系边缺 to")
        for axis in RELATION_AXES:
            if not isinstance(edge.get(axis), int) or not 0 <= edge[axis] <= 100: err(f"关系 →{edge.get('to')} 的 {axis} 不在 0–100")
    posts = card["posts"]
    if not posts.get("core"): err("posts.core 为空")
    for key in ("core", "secondary", "unsuitable"):
        for post in posts.get(key, []):
            if post not in POSTS: err(f"岗位 {post} 不在 {sorted(POSTS)}")
    if set(posts.get("core", [])) & set(posts.get("unsuitable", [])): err("同一岗位既是核心又是不宜")
    for mode in card["failure_modes"]:
        if not str(mode.get("text", "")).strip() or mode.get("source") not in ("notion", "draft"): err("failure_modes 每条要有 text 和 source（notion/draft）")
        if mode.get("trait") and mode["trait"] not in traits: err(f"失败模式引用了未登记的特性 {mode['trait']}")

    if not set(card["inferred"]) <= INFERABLE: err(f"inferred 含未知字段 {sorted(set(card['inferred']) - INFERABLE)}")
    if card["status"] == "source":
        if not any("notion.com" in s.get("url", "") for s in card["sources"]): err("status=source 的卡必须有 Notion 来源")
        if set(card["inferred"]) & {"attributes", "potentials", "troop_aptitudes", "terrain_experience", "relations"}: err("status=source 的卡不得推定数值字段")
    else:
        missing = {"attributes", "personality", "traits"} - set(card["inferred"])
        if missing: err(f"status=draft 的卡须把 {sorted(missing)} 列进 inferred")
    for key in ("portrait", "thumbnail"):
        if key in card and not (ROOT / card[key].removeprefix("res://")).exists(): err(f"{key} 文件不存在：{card[key]}")
    text = json.dumps(card, ensure_ascii=False)
    for typo in TYPOS:
        if typo in text: err(f"含错字 {typo}")


def main():
    cards = json.loads((ROOT / "data/officers.json").read_text(encoding="utf-8"))
    traits = {t["id"]: t for t in json.loads((ROOT / "data/officers/traits.json").read_text(encoding="utf-8"))["traits"]}
    errors = []
    ids = [c.get("id") for c in cards]
    names = [c.get("name") for c in cards]
    if len(set(ids)) != len(ids): errors.append(f"id 重复：{sorted({i for i in ids if ids.count(i) > 1})}")
    if len(set(names)) != len(names): errors.append(f"姓名重复：{sorted({n for n in names if names.count(n) > 1})}")
    warnings = []
    for card in cards: check_card(card, traits, errors, warnings)
    for line in warnings: print("WARN", line)
    for line in errors: print("ERROR", line)
    by_status = {s: sum(1 for c in cards if c.get("status") == s) for s in sorted(STATUS)}
    print(f"OFFICER_CARDS: {len(cards)} 张 {by_status} —— {'PASS' if not errors else f'FAIL {len(errors)} 项'}")
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
