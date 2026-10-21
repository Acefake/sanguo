"""Read-only audit of original RTK14 map records and the currently imported grid."""
import argparse
import collections
import hashlib
import json
from pathlib import Path
import struct

root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument('--game-root', required=True, type=Path)
args = parser.parse_args()
current = (root / 'assets/rtk14/map_grid.bin').read_bytes()
records = []
for name in ['Map.bin', 'MapEx.bin', 'MapExCe.bin']:
    path = args.game_root / '0000' / name
    raw = path.read_bytes()
    count = struct.unpack_from('<I', raw)[0]
    assert len(raw) == 4 + count * 16
    cells = list(struct.iter_unpack('<4I', raw[4:]))
    records.append({'file': str(path), 'bytes': len(raw), 'cells': count, 'record_bytes': 16,
                    'sha256': hashlib.sha256(raw).hexdigest(), 'matches_current_grid': raw == current,
                    'different_records_from_current': sum(raw[offset:offset+16] != current[offset:offset+16] for offset in range(4,len(raw),16)),
                    'second_word_low_byte_counts': dict(collections.Counter(row[1] & 255 for row in cells))})
report = {'source_maps': records, 'current_movement': 'city graph edges and daily progress; 3D endpoint interpolation',
          'native_runtime_pathfinder': 'not recovered; installed executables are binaries, not source code',
          'grid_to_world_registration': 'estimated; original runtime constants unconfirmed',
          'official_manual': ['https://www.gamecity.com.tw/manual/sangokushi14/3300.html', 'https://www.gamecity.com.tw/manual/sangokushi14/5100.html']}
output = root / 'docs/validation/army-assets/movement-source-audit.json'
output.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf8')
for record in records:
    print(Path(record['file']).name, 'cells=',record['cells'], 'matches_current=',record['matches_current_grid'], 'different_records=',record['different_records_from_current'])
