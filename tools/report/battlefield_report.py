"""把检验战场跑测器的汇总 JSON 写成 Markdown 报告。

    python tools/report/battlefield_report.py <summary.json> docs/validation/battlefield-ai.md [--compact docs/validation/battlefield-ai.json]

每个战场一节：检验点、人物对比表、决策差异（置换检验）、增益明细（属性/特性来源与上限）、
代表性决策记录（种子 0）、胜负与伤亡统计。--compact 另存一份精简 JSON 供提交（去掉逐条决策、逐场分布与非被测部队的理由计数）。
"""
import json
import sys

POSTURE = {"assault": "强攻", "hold": "坚守", "lure": "诱敌", "flank": "侧击", "raid": "奇袭", "pursue": "追击", "withdraw": "撤退", "relieve": "救援"}
SIDE = {"yuan": "袁军", "cao": "曹军", "west": "西军", "east": "东军"}
OBJECTIVE = {"take": "夺取", "hold": "守住", "relieve": "解围", "burn": "焚粮", "protect": "保粮", "destroy": "击溃", "escape": "退走", "feint": "佯动"}


def pct(x):
    return f"{x * 100:.0f}%"


def shares(share, limit=4):
    items = sorted(share.items(), key=lambda kv: -kv[1])[:limit]
    return "、".join(f"{POSTURE.get(k, k)} {pct(v)}" for k, v in items if v >= 0.005) or "—"


def wins_text(wins, runs):
    return "、".join(f"{SIDE.get(k, '和局' if k == 'draw' else k)} {v}/{runs}" for k, v in sorted(wins.items(), key=lambda kv: -kv[1]))


def buffs_rows(rows):
    out = []
    for row in rows:
        if abs(row["value"]) < 0.005 and not row["trait"]["sources"]:
            continue
        levels = "、".join(f"{k}{v}" for k, v in row["attribute"]["levels"].items())
        traits = "、".join(f"{s['name']}（{s['hook']} {s['value']:+g}）" for s in row["trait"]["sources"]) or "—"
        caps = "；".join(f"{c['hook']} 合计 {c['applied']:+g} / 上限 ±{c['cap']:g}{'' if c['ok'] else ' 超限'}" for c in row["trait"]["caps"]) or "—"
        out.append(f"| {row['label']} | {row['value'] * 100:+.1f}% | {levels} → {row['attribute']['value'] * 100:+.1f}% | {traits} → {row['trait']['value'] * 100:+.1f}% | {caps} |")
    return out


def decision_rows(sample):
    out = []
    for d in sample:
        seen = d["seen"]
        sit = f"兵力比 {seen['ratio']}（估 {seen['enemy_est']} / 实 {seen['enemy_true']}）门槛 {seen['engage_ratio']}；组织 {seen['organization']} 士气 {seen['morale']}；{'接战' if seen['in_contact'] else '未接战'}{'；察觉伏兵' if seen['threat_known'] else ''}"
        reasons = "；".join(f"［{r['source']}］{r['text']}" for r in d["reasons"])
        extra = []
        if d.get("advice", {}).get("from"):
            extra.append(f"参军{d['advice']['from']}建议{POSTURE.get(d['advice']['posture'], d['advice']['posture'])}，{'采纳' if d['advice']['adopted'] else '未采纳'}（{pct(d['advice']['p'])}）")
        if d.get("slip", {}).get("intended"):
            extra.append(f"压力失误（本想{POSTURE.get(d['slip']['intended'])}）")
        buffs = "；".join(f"{b['label']} {b['value'] * 100:+.1f}%" + (f"（特性 {'、'.join(s['name'] for s in b['sources'])}）" if b["sources"] else "") for b in d["buffs"][:4])
        res = d["result"]
        result = f"伤亡 {res['loss']}/{res['start']}{'，溃' if res['routed'] else ''}{'，退走' if res['escaped'] else ''}"
        out.append(f"| t{d['tick']}（{d['trigger']}） | {sit} | **{d['name']}**{'' if d['changed'] else '（维持）'} | {reasons}{'；' + '；'.join(extra) if extra else ''} | {buffs} | {result} |")
    return out


def render(report):
    runs = report["seeds"]
    lines = ["# 检验战场 · 人物 AI 跑测报告", "",
             f"命令：`godot --headless --path . --script res://tests/war/proving/battlefield_runner.gd -- --seeds={runs} --out=<summary.json>`，"
             "再 `python tools/report/battlefield_report.py <summary.json> docs/validation/battlefield-ai.md`。", "",
             f"每个试验跑种子 0–{runs - 1}，同一种子下只换人物（战斗与每支部队的感知各用独立随机流）。", "",
             "## 总判定", ""]
    failures = report.get("failures", [])
    lines.append("```")
    lines.append("BATTLEFIELD_AI: " + ("PASS" if not failures else f"FAIL {len(failures)} 项"))
    for f in failures:
        lines.append("  " + f)
    lines.append("```")
    static = report["static"]
    lines += ["", f"- 禁用机制扫描：{'通过' if static['pass'] else '未通过'}（扫描 {len(static['scanned'])} 个文件，关键词 {'、'.join(static['forbidden'])}；姿态表只允许偏好字段）。"]
    total_cmp = sum(len(b["comparisons"]) for b in report["battlefields"])
    ok_cmp = sum(1 for b in report["battlefields"] for c in b["comparisons"] if c["pass"])
    total_exp = sum(len(b["expects"]) for b in report["battlefields"])
    ok_exp = sum(1 for b in report["battlefields"] for e in b["expects"] if e["pass"])
    audits = sum(t["audit_violations"] for b in report["battlefields"] for t in b["trials"])
    lines += [f"- 决策分布差异：{ok_cmp}/{total_cmp} 组显著（配对置换检验 p<0.01 且总变差 ≥0.10）。",
              f"- 定向预期：{ok_exp}/{total_exp} 条成立。",
              f"- 增益上限：全部决策点逐项核对，超限 {audits} 处。",
              f"- 可复现：{'、'.join(b['id'] + ('✓' if b['reproducible']['same'] else '✗') for b in report['battlefields'])}（每个战场首个试验前 3 个种子重跑逐字相同）。", ""]
    for b in report["battlefields"]:
        lines += [f"## {b['name']}（`{b['id']}`）", "", b["summary"], "", f"史实：{b['history']}", "", "**检验点**", ""]
        lines += [f"- {c}" for c in b["checks"]]
        lines += ["", "### 人物对比", "", "| 试验 | 被测部队 · 主将（参军） | 决策分布 | 按刻姿态占比 | 胜负 | 双方亡损率 | 目标达成 | 该部伤亡率 / 溃散 / 中伏 / 追击步数 |", "|---|---|---|---|---|---|---|---|"]
        for t in b["trials"]:
            u = t["units"][t["subject"]]
            adviser = f"（{u['adviser']}）" if u["adviser"] else ""
            loss = "、".join(f"{SIDE.get(k, k)} {pct(v)}" for k, v in t["loss_rate"].items())
            objectives = "、".join(f"{SIDE.get(k.split('.')[0], k.split('.')[0])}{OBJECTIVE.get(k.split('.')[1], k.split('.')[1])} {pct(v)}" for k, v in t["objectives"].items() if "." in k)
            lines.append(f"| {t['label']} | {t['subject']} · {u['officer']}{adviser} | {shares(u['choice_share'])} | {shares(u['posture_share'], 3)} | {wins_text(t['wins'], runs)} | {loss} | {objectives} | {pct(u['loss'])} / {pct(u['routed'])} / {pct(u['ambushed'])} / {u['pursuit_steps']:.2f} |")
        lines += ["", "### 决策差异", "", "| 对照 | 部队 | 人物 A 决策分布 | 人物 B 决策分布 | 总变差 | p | 判定 |", "|---|---|---|---|---|---|---|"]
        for c in b["comparisons"]:
            lines.append(f"| {c['a']} vs {c['b']} | {c['unit']} | {c['officer_a']}：{shares(c['choice_a'])} | {c['officer_b']}：{shares(c['choice_b'])} | {c['tvd']:.3f} | {c['p']:.4f} | {'显著' if c['pass'] else '不显著'} |")
        if b["expects"]:
            lines += ["", "| 定向预期 | 实测 | 判定 |", "|---|---|---|"]
            for e in b["expects"]:
                lines.append(f"| {e['why']} | {e['detail']} | {'成立' if e['pass'] else '不成立'} |")
        if b["mirrors"]:
            lines += ["", "| 镜像对照 | 总变差 | 判定 |", "|---|---|---|"]
            for m in b["mirrors"]:
                lines.append(f"| {m['base']}（{m['unit']}） vs {m['mirror']}（{m['twin']}） | {m['tvd']:.3f} | {'对称' if m['pass'] else '不对称'} |")
        lines += ["", "### 主要理由（跨种子计数，数字已归一为 #）", ""]
        for t in b["trials"]:
            u = t["units"][t["subject"]]
            parts = []
            for posture, reasons in sorted(u["reasons"].items(), key=lambda kv: -u["choice_share"].get(kv[0], 0))[:3]:
                parts.append(f"{POSTURE.get(posture, posture)}：" + "；".join(f"{r}×{n}" for r, n in reasons[:3]))
            lines.append(f"- **{t['label']}**（{u['officer']}）—— " + " ｜ ".join(parts))
        lines += ["", "### 增益明细（被测主将，平原情境，相对“子属性全 50、无特性”）", ""]
        seen_officers = set()
        for t in b["trials"]:
            u = t["units"][t["subject"]]
            if u["officer"] in seen_officers:
                continue
            seen_officers.add(u["officer"])
            rows = buffs_rows(t["subject_buffs"])
            lines += [f"**{u['officer']}**", "", "| 通道 | 合计 | 属性来源 | 特性来源 | 特性上限核对 |", "|---|---|---|---|---|"] + rows + [""]
        lines += ["特性在这些战场情境里是否触发，取决于条件字段（计划类型、地形、情报来源等），触发后的逐项来源见下面决策记录的“生效增益”列。", ""]
        first = b["trials"][0]
        lines += [f"### 代表性决策记录（{first['label']}，种子 0，被测部队）", "", "| 决策点 | 看到的态势 | 选择 | 理由 | 生效增益（前 4 项） | 该部结果 |", "|---|---|---|---|---|---|"]
        lines += decision_rows(first["sample"])
        if first["events"]:
            lines += ["", "战报：" + "；".join(f"t{e['tick']} {e['text']}" for e in first["events"][:16])]
        lines.append("")
    return "\n".join(lines) + "\n"


def compact(report):
    slim = json.loads(json.dumps(report))
    for b in slim["battlefields"]:
        for t in b["trials"]:
            for key in ("sample_all", "sample", "events"):
                t.pop(key, None)
            t["subject_buffs"] = [{"label": r["label"], "value": round(r["value"], 4), "attribute": round(r["attribute"]["value"], 4), "trait": round(r["trait"]["value"], 4), "sources": r["trait"]["sources"]} for r in t["subject_buffs"]]
            for uid, u in t["units"].items():
                for key in ("shares", "choice_shares", "commit_share"):
                    u.pop(key, None)
                if uid != t["subject"]:
                    u.pop("reasons", None)
    return slim


def main():
    report = json.load(open(sys.argv[1], encoding="utf-8"))
    with open(sys.argv[2], "w", encoding="utf-8") as f:
        f.write(render(report))
    if "--compact" in sys.argv:
        path = sys.argv[sys.argv.index("--compact") + 1]
        with open(path, "w", encoding="utf-8") as f:
            json.dump(compact(report), f, ensure_ascii=False, indent=1)


if __name__ == "__main__":
    main()
