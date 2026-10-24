"""把文件里的旧 res:// 路径改成按模块分目录后的新路径。

给只在本地、还没进仓库的脚本用：放到新位置后跑一次，它们里面 preload/load 的旧路径会按
docs/目录迁移-2026-10-24.tsv（以及更早的 docs/目录迁移-2026-10-21.tsv，若存在）改写。
只改写整段路径，可以重复运行。

    python tools/migrate_paths.py scripts/war/battle/my_local_script.gd tests/war/battle/my_test.gd ...
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TABLES = [ROOT / 'docs/目录迁移-2026-10-21.tsv', ROOT / 'docs/目录迁移-2026-10-24.tsv']


def load_mapping() -> dict[str, str]:
    """Old → new path, later tables win; both columns are paths relative to res://."""
    mapping: dict[str, str] = {}
    for table in TABLES:
        if table.exists():
            for line in table.read_text(encoding='utf-8').splitlines():
                if line.strip() and not line.startswith('#'):
                    old, new = line.split('\t')[:2]
                    mapping[old] = new
    return mapping


def main(paths: list[str]) -> None:
    mapping = load_mapping()
    keys = sorted(mapping, key=len, reverse=True)
    pattern = re.compile(r'res://(' + '|'.join(re.escape(old) for old in keys) + r')(?![A-Za-z0-9_])')
    for name in paths:
        path = Path(name)
        text = path.read_text(encoding='utf-8')
        new_text, count = pattern.subn(lambda m: 'res://' + mapping[m.group(1)], text)
        if count:
            path.write_text(new_text, encoding='utf-8')
        print(f'{count:3d}  {name}')


if __name__ == '__main__':
    main(sys.argv[1:])
