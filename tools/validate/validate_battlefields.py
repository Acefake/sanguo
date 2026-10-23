"""校验 data/scenarios/battlefields/*.json（检验战场）。

    python tools/validate/validate_battlefields.py

字段契约见 docs/战场AI检验说明.md「战场数据」：顶层必填字段、区域（地形只能是 campaign_rules.terrain 里有的键）、
道路连通、双方各自的退路/粮囤/辎重/诱敌之地引用存在、部队兵力为非负整数且不全为 0、人物 id 在官渡人物卡或为 neutral、
目标类型已登记（relieve 要 deadline、take/hold/relieve 要 zone）、试验 id 唯一且换人的部队存在、compare/expect 引用的试验存在。
另外查禁用字段：战场数据里不得出现技能、冷却、怒气、等级等键。全部通过退出 0，否则逐条打印并退出 1。
"""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DIR = ROOT / "data/scenarios/battlefields"
REQUIRED = ["id", "name", "summary", "checks", "ticks", "tick_hours", "zones", "links", "sides", "subject", "trials", "compare"]
OBJECTIVES = {"take", "hold", "relieve", "burn", "protect", "destroy", "escape", "feint"}
ZONE_OBJECTIVES = {"take", "hold", "relieve", "feint"}
POSTURES = {"assault", "hold", "lure", "flank", "raid", "pursue", "withdraw", "relieve"}
METRICS = {"ambushed", "pursuit_steps", "burn", "commit_share", "loss", "routed", "escaped"}
TROOPS = {"infantry", "archers", "cavalry"}
FORBIDDEN_KEYS = {"skill", "skills", "cooldown", "rage", "level", "mana", "active_skill", "冷却", "怒气", "战法", "等级"}


def walk_keys(value, path=""):
    if isinstance(value, dict):
        for key, child in value.items():
            yield key, f"{path}.{key}"
            yield from walk_keys(child, f"{path}.{key}")
    elif isinstance(value, list):
        for i, child in enumerate(value):
            yield from walk_keys(child, f"{path}[{i}]")


def check(field, officer_ids, terrains):
    errors = []
    name = field.get("id", "?")
    for key in REQUIRED:
        if key not in field:
            errors.append(f"缺少字段 {key}")
    if errors:
        return errors
    zones = {}
    for zone in field["zones"]:
        zid = zone.get("id")
        if zid in zones:
            errors.append(f"区域 id 重复：{zid}")
        zones[zid] = zone
        if zone.get("terrain") not in terrains:
            errors.append(f"区域 {zid} 地形未登记：{zone.get('terrain')}")
        for key in ("x", "y", "cover"):
            if key in zone and not 0 <= float(zone[key]) <= 1:
                errors.append(f"区域 {zid}.{key} 应在 0–1")
        if float(zone.get("fort", 0)) < 0 or float(zone.get("fort", 0)) > float(zone.get("fortifiable", zone.get("fort", 0))) + 1e-9:
            errors.append(f"区域 {zid} 工事 fort 应在 0 与 fortifiable 之间")
    graph = {z: set() for z in zones}
    for link in field["links"]:
        if len(link) != 3 or link[0] not in zones or link[1] not in zones or float(link[2]) <= 0:
            errors.append(f"道路不合规：{link}")
            continue
        graph[link[0]].add(link[1])
        graph[link[1]].add(link[0])
    if zones:
        start = next(iter(zones))
        seen, stack = {start}, [start]
        while stack:
            for nxt in graph[stack.pop()]:
                if nxt not in seen:
                    seen.add(nxt)
                    stack.append(nxt)
        if len(seen) != len(zones):
            errors.append(f"区域不连通：{sorted(set(zones) - seen)}")
    if len(field["sides"]) != 2:
        errors.append("必须正好两方")
    units = {}
    for side, spec in field["sides"].items():
        for key in ("retreat", "lure_zone", "baggage"):
            if key in spec and spec[key] not in zones:
                errors.append(f"{side}.{key} 区域不存在：{spec[key]}")
        if "retreat" not in spec:
            errors.append(f"{side} 缺少退路 retreat")
        if "depot" in spec and spec["depot"].get("zone") not in zones:
            errors.append(f"{side} 粮囤区域不存在")
        for objective in spec.get("objectives", []):
            errors += check_objective(f"{side}", objective, zones)
        if not spec.get("objectives"):
            errors.append(f"{side} 没有目标")
        if not spec.get("units"):
            errors.append(f"{side} 没有部队")
        for unit in spec.get("units", []):
            uid = unit.get("id")
            if uid in units:
                errors.append(f"部队 id 重复：{uid}")
            units[uid] = side
            if unit.get("zone") not in zones:
                errors.append(f"{uid} 位置不存在")
            for key in ("officer", "adviser"):
                if key in unit and unit[key] not in officer_ids:
                    errors.append(f"{uid}.{key} 人物不存在：{unit[key]}")
            troops = unit.get("troops", {})
            if set(troops) - TROOPS or any(not isinstance(v, int) or v < 0 for v in troops.values()) or sum(troops.values()) <= 0:
                errors.append(f"{uid} 兵力不合规：{troops}")
            for key in ("morale", "organization"):
                if not 0 < float(unit.get(key, 90)) <= 100:
                    errors.append(f"{uid}.{key} 应在 1–100")
            for objective in unit.get("objectives", []):
                errors += check_objective(uid, objective, zones)
    if field["subject"] not in units:
        errors.append(f"subject 部队不存在：{field['subject']}")
    trials = set()
    for trial in field["trials"]:
        tid = trial.get("id")
        if tid in trials:
            errors.append(f"试验 id 重复：{tid}")
        trials.add(tid)
        for uid, oid in trial.get("assign", {}).items():
            if uid not in units:
                errors.append(f"试验 {tid} 换人的部队不存在：{uid}")
            if oid not in officer_ids:
                errors.append(f"试验 {tid} 人物不存在：{oid}")
        for uid, oid in trial.get("adviser_assign", {}).items():
            if uid not in units or (oid and oid not in officer_ids):
                errors.append(f"试验 {tid} 参军配置不合规：{uid}={oid}")
        if trial.get("subject", field["subject"]) not in units:
            errors.append(f"试验 {tid} subject 不存在")
        if "mirror_of" in trial and trial["mirror_of"] not in trials:
            errors.append(f"试验 {tid} mirror_of 引用了不存在（或排在后面）的试验")
    for pair in field["compare"]:
        if pair[0] not in trials or pair[1] not in trials or (len(pair) > 2 and pair[2] not in units):
            errors.append(f"compare 引用不合规：{pair}")
    for expect in field.get("expect", []):
        if expect.get("trial") not in trials or expect.get("unit") not in units or not expect.get("why"):
            errors.append(f"expect 引用不合规：{expect}")
        for key in ("more_than", "first_more", "metric_more", "metric_less"):
            if key in expect:
                if expect[key].get("trial") not in trials:
                    errors.append(f"expect.{key} 试验不存在：{expect}")
                if "postures" in expect[key] and set(expect[key]["postures"]) - POSTURES:
                    errors.append(f"expect.{key} 姿态未登记：{expect[key]['postures']}")
                if "metric" in expect[key] and expect[key]["metric"] not in METRICS:
                    errors.append(f"expect.{key} 指标未登记：{expect[key]['metric']}")
    if len(field["compare"]) < 1:
        errors.append("至少要有一组 compare")
    for key, path in walk_keys(field):
        if key in FORBIDDEN_KEYS:
            errors.append(f"禁用字段 {path}")
    return [f"{name}: {e}" for e in errors]


def check_objective(owner, objective, zones):
    errors = []
    kind = objective.get("type")
    if kind not in OBJECTIVES:
        errors.append(f"{owner} 目标类型未登记：{kind}")
    if kind in ZONE_OBJECTIVES and objective.get("zone") not in zones:
        errors.append(f"{owner} 目标 {kind} 缺少有效 zone")
    if kind == "relieve" and "deadline" not in objective:
        errors.append(f"{owner} relieve 目标缺少 deadline")
    return errors


def main():
    officers = json.load(open(ROOT / "data/scenarios/guandu/officers.json", encoding="utf-8"))
    officer_ids = {o["id"] for o in officers} | {"neutral"}
    terrains = set(json.load(open(ROOT / "data/war/campaign_rules.json", encoding="utf-8"))["terrain"])
    files = sorted(DIR.glob("*.json"))
    errors = []
    for path in files:
        field = json.load(open(path, encoding="utf-8"))
        if field.get("id") != path.stem:
            errors.append(f"{path.name}: id 与文件名不一致")
        errors += check(field, officer_ids, terrains)
    for e in errors:
        print("FAIL", e)
    print(f"BATTLEFIELDS: {len(files)} 个战场，{'PASS' if not errors else f'FAIL {len(errors)} 项'}")
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
