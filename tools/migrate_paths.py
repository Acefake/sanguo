"""把文件里的旧 res:// 路径改成 2026-10-21 目录迁移后的新路径。

给只在本地、没进仓库的脚本用：放到新位置后跑一次，它们里面 preload/load 的旧路径会按
docs/目录迁移-2026-10-21.tsv 改写。只改写整段路径，可以重复运行。

    python tools/migrate_paths.py scripts/war/battle/city_defense.gd scripts/agents/unit_brain.gd ...
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TABLE = ROOT / 'docs/目录迁移-2026-10-21.tsv'


def main(paths: list[str]) -> None:
    rows = [line.split('\t') for line in TABLE.read_text(encoding='utf-8').splitlines() if line.strip()]
    mapping = dict(sorted(rows, key=lambda row: -len(row[0])))
    pattern = re.compile(r'res://(' + '|'.join(re.escape(old) for old in mapping) + r')(?![A-Za-z0-9_])')
    for name in paths:
        path = Path(name)
        text = path.read_text(encoding='utf-8')
        new_text, count = pattern.subn(lambda m: 'res://' + mapping[m.group(1)], text)
        if count:
            path.write_text(new_text, encoding='utf-8')
        print(f'{count:3d}  {name}')


if __name__ == '__main__':
    main(sys.argv[1:])
