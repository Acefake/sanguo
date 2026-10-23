"""确认 scripts/ 里没有写死人物名。

从 data/scenarios/*/officers.json 收集每张人物卡的 name 与 courtesy_name（字），在 scripts/ 下所有
.gd 文件里查找；有命中就逐行列出并以 1 退出，可供 CI 调用。人物相关的台词、预览对阵等放 data/，
代码只按人物 id 或标签查。

    python tools/validate/check_no_hardcoded_names.py
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def names() -> list[str]:
    found = set()
    for path in sorted(ROOT.glob('data/scenarios/*/officers.json')):
        for card in json.loads(path.read_text(encoding='utf-8')):
            found.update(str(card.get(key) or '') for key in ('name', 'courtesy_name'))
    found.discard('')
    return sorted(found, key=len, reverse=True)


def main() -> int:
    targets = names()
    if not targets:
        print('NO_HARDCODED_NAMES: 没有读到人物卡（data/scenarios/*/officers.json）—— FAIL')
        return 1
    pattern = re.compile('|'.join(map(re.escape, targets)))
    hits = []
    for path in sorted((ROOT / 'scripts').rglob('*.gd')):
        for number, line in enumerate(path.read_text(encoding='utf-8').splitlines(), 1):
            matched = sorted(set(pattern.findall(line)))
            if matched:
                hits.append(f'{path.relative_to(ROOT).as_posix()}:{number}: {"、".join(matched)} | {line.strip()[:100]}')
    for hit in hits:
        print(hit)
    print(f'NO_HARDCODED_NAMES: {len(targets)} 个人名/字，命中 {len(hits)} 处 —— {"PASS" if not hits else "FAIL"}')
    return 1 if hits else 0


if __name__ == '__main__':
    sys.exit(main())
