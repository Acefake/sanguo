"""确认 scripts/ 里没有写死人物名。

人物卡路径取自 scripts/officers/officer_repository.gd 的 PATH（人物卡单一入口），收集每张卡的
name 与 courtesy_name（字），在 scripts/ 下所有 .gd 里查找（注释也算）；有命中就逐行列出并以 1
退出，可供 CI 调用。人物相关的台词、预览对阵等放 data/，代码只按人物 id 查。

    python tools/validate/check_no_hardcoded_names.py
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
REPOSITORY = ROOT / 'scripts/officers/officer_repository.gd'


def cards_path() -> Path:
    """OfficerRepository.PATH（res:// 路径）对应的本地文件。"""
    match = re.search(r'^const PATH := "res://([^"]+)"', REPOSITORY.read_text(encoding='utf-8'), re.M)
    if not match:
        sys.exit(f'NO_HARDCODED_NAMES: {REPOSITORY.relative_to(ROOT)} 里找不到 const PATH —— FAIL')
    return ROOT / match.group(1)


def names() -> list[str]:
    """人物名与字，长的在前（正则先匹配长名）。"""
    found = set()
    for card in json.loads(cards_path().read_text(encoding='utf-8')):
        found.update(str(card.get(key) or '') for key in ('name', 'courtesy_name'))
    found.discard('')
    return sorted(found, key=len, reverse=True)


def main() -> int:
    targets = names()
    if not targets:
        print('NO_HARDCODED_NAMES: 没有读到人物卡 —— FAIL')
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
