"""汇总 step_profile.gd 的输出：各阶段 p50/p95/p99/占比、跨阶段累计、尖峰日。

    python3 tools/profile/summarize.py <profile.raw> [--skip-first-round]

分位数取法与 tests/agents/step_latency_validation.gd 相同（ceil(q·n)−1 的有序样本）。
占比 = 该阶段在全部样本里的耗时总和 / step 总耗时总和。
"""
import collections
import json
import math
import sys

path = sys.argv[1]
skip_first = '--skip-first-round' in sys.argv
rows, plain = [], []
for line in open(path, encoding='utf-8', errors='replace'):
    if line.startswith('PROFILE {'):
        rows.append(json.loads(line[len('PROFILE '):]))
    elif line.startswith('PLAIN {'):
        plain.append(json.loads(line[len('PLAIN '):]))
if skip_first:
    rows = [r for r in rows if r['round'] > 0]
    plain = [r for r in plain if r['round'] > 0]


def pick(values, q):
    s = sorted(values)
    return s[max(0, min(len(s) - 1, math.ceil(q * len(s)) - 1))]


def ms(us):
    return us / 1000.0


def table(title, series, total):
    print(f'\n## {title}')
    print('| 项 | p50 | p95 | p99 | max | 平均 | 占比 |')
    print('|---|---:|---:|---:|---:|---:|---:|')
    for name, values in sorted(series.items(), key=lambda kv: -sum(kv[1])):
        share = sum(values) / total * 100 if total else 0
        print(f'| {name} | {ms(pick(values, .5)):.2f} | {ms(pick(values, .95)):.2f} | {ms(pick(values, .99)):.2f} | {ms(max(values)):.2f} | {ms(sum(values) / len(values)):.2f} | {share:.1f}% |')


for mode in sorted({r['mode'] for r in rows}):
    mr = [r for r in rows if r['mode'] == mode]
    mp = [r['step_us'] for r in plain if r['mode'] == mode]
    total = sum(r['step_us'] for r in mr)
    print(f'\n# 模式 {mode}：{len(mr)} 个 step（{len({r["round"] for r in mr})} 轮 × {max(r["day"] for r in mr)} 日）')
    print(f'原版 step：p50 {ms(pick(mp, .5)):.2f} / p95 {ms(pick(mp, .95)):.2f} / p99 {ms(pick(mp, .99)):.2f} / max {ms(max(mp)):.2f} ms；'
          f'分段版：p50 {ms(pick([r["step_us"] for r in mr], .5)):.2f} / p95 {ms(pick([r["step_us"] for r in mr], .95)):.2f} / p99 {ms(pick([r["step_us"] for r in mr], .99)):.2f}')
    phases = collections.defaultdict(list)
    for r in mr:
        for name in set().union(*[x['phases'] for x in mr]):
            phases[name].append(r['phases'].get(name, 0))
    phases['（step 合计）'] = [r['step_us'] for r in mr]
    table('独占阶段（相加 = step）', phases, total)
    inc = collections.defaultdict(list)
    names = set().union(*[x['inclusive'] for x in mr])
    for r in mr:
        for name in names:
            inc[name].append(r['inclusive'].get(name, 0))
    inc['调度（begin_round+take+submit）'] = [r['scheduler_us'] for r in mr]
    table('跨阶段累计（包含式，与上表重叠）', inc, total)
    out = {'save_export': [r['save_export_us'] for r in mr], 'save_stringify': [r['save_stringify_us'] for r in mr]}
    table('step 之外：_save 同款序列化（占比按 step 总耗时折算）', out, total)
    print('\n调用次数（每 step 平均）：' + '，'.join(f'{n} {sum(r["calls"].get(n, 0) for r in mr) / len(mr):.1f}' for n in sorted(names)))
    print('\n## 最慢 8 个 step')
    print('| 轮 | 日 | step | 前三阶段 | 部队 | 军团 | 战术部队 | 接敌 | 战场 | 围城 | 决策上下文 | 新军报 |')
    print('|---|---:|---:|---|---:|---:|---:|---:|---|---:|---:|---:|')
    for r in sorted(mr, key=lambda r: -r['step_us'])[:8]:
        top = sorted(r['phases'].items(), key=lambda kv: -kv[1])[:3]
        print(f'| {r["round"]} | {r["day"]} | {ms(r["step_us"]):.1f} | ' + '，'.join(f'{k} {ms(v):.1f}' for k, v in top) +
              f' | {r["armies"]} | {r["corps"]} | {r["tactical"]} | {r["engaged"]} | {r["battlefields"]}{"+" if r["battlefield"] else ""} | {r["sieges"]} | {r["decision_contexts"]} | {r["reports_new"]} |')
    print('\n## 逐日（各轮中位数，ms）')
    by_day = collections.defaultdict(list)
    for r in mr:
        by_day[r['day']].append(r)
    big = [k for k, _ in sorted(phases.items(), key=lambda kv: -sum(kv[1])) if k != '（step 合计）'][:5]
    print('| 日 | step | ' + ' | '.join(big) + ' | 部队 | 军团 | 接敌 | 决策上下文 |')
    print('|---:|---:|' + '---:|' * len(big) + '---:|---:|---:|---:|')
    for day in sorted(by_day):
        rs = by_day[day]
        med = lambda f: sorted(f(x) for x in rs)[len(rs) // 2]
        print(f'| {day} | {ms(med(lambda x: x["step_us"])):.1f} | ' + ' | '.join(f'{ms(med(lambda x, k=k: x["phases"].get(k, 0))):.1f}' for k in big) +
              f' | {rs[0]["armies"]} | {rs[0]["corps"]} | {rs[0]["engaged"]} | {rs[0]["decision_contexts"]} |')
