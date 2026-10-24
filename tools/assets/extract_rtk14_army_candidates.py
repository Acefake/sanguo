"""Export small CharacterEditor models for visual identification; retain source hashes."""
from pathlib import Path
import argparse
import json
import re
import struct
import subprocess
import zlib
import numpy as np
from PIL import Image, ImageDraw, ImageFont
from audit_army_assets import render_triangles

ROOT = Path(__file__).resolve().parents[2]


def extract(record, game_root):
    match = re.fullmatch(r'([a-fA-F0-9]+)@([a-fA-F0-9]+)(?:#([a-fA-F0-9]+))?(?:&([a-fA-F0-9]+))?', record['address'])
    suffix = (str(int(match[3], 16)) if match[3] else '') + ('_' + str(int(match[4], 16)) if match[4] else '')
    archive = game_root / '0002' / (record['package'] + '.rdb.bin' + suffix)
    with archive.open('rb') as file:
        file.seek(int(match[1], 16))
        entry = file.read(int(match[2], 16))
    total, compressed = struct.unpack_from('<qq', entry, 8)
    packed = entry[total - compressed:total]
    if not record['flags'] & 0x100000:
        return packed
    blocks, offset = [], 0
    while offset < len(packed):
        length, = struct.unpack_from('<I', packed, offset)
        offset += 4
        if not length:
            break
        blocks.append(zlib.decompress(packed[offset:offset + length]))
        offset += length
    return b''.join(blocks)


def obj_triangles(path):
    vertices, faces = [], []
    for line in path.read_text().splitlines():
        parts = line.split()
        if not parts: continue
        if parts[0] == 'v': vertices.append([float(value) for value in parts[1:4]])
        if parts[0] == 'f':
            indices = [int(value.split('/')[0]) - 1 for value in parts[1:]]
            faces.extend([indices[0], indices[index], indices[index + 1]] for index in range(1, len(indices) - 1))
    return np.array(vertices)[np.array(faces)]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--index', required=True, type=Path)
    parser.add_argument('--game-root', required=True, type=Path)
    parser.add_argument('--noesis', required=True, type=Path)
    parser.add_argument('--max-bytes', type=int, default=600000)
    parser.add_argument('--cache', type=Path, default=ROOT / 'tools/army-source-cache')
    parser.add_argument('--output', type=Path, default=ROOT / 'docs/validation/army-assets')
    args = parser.parse_args()
    args.cache.mkdir(parents=True, exist_ok=True)
    (args.cache / '.gdignore').touch()
    args.output.mkdir(parents=True, exist_ok=True)
    records = [row for row in json.loads(args.index.read_text(encoding='utf8'))
               if row['package'] == 'CharacterEditor' and row['ext'] == 'g1m' and 3000 < row['size'] < args.max_bytes]
    candidates = []
    for record in sorted(records, key=lambda row: row['size']):
        identifier = record['id']
        raw = args.cache / (identifier + '.g1m')
        if not raw.exists(): raw.write_bytes(extract(record, args.game_root))
        target = raw.with_suffix('.obj')
        if not target.exists():
            result = subprocess.run([str(args.noesis), '?cmode', str(raw), str(target)], capture_output=True, timeout=45,
                                    creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
            if result.returncode or not target.exists():
                print('CONVERT_FAILED', identifier, result.stdout[-250:], flush=True)
                continue
        triangles = obj_triangles(target)
        points = triangles.reshape(-1, 3)
        candidates.append({**record, 'obj': str(target), 'extent': (points.max(0) - points.min(0)).round(3).tolist(),
                           'triangles': len(triangles), 'classification': 'unverified'})
        print('MODEL', identifier, len(triangles), candidates[-1]['extent'], flush=True)
    font = ImageFont.truetype('C:/Windows/Fonts/simkai.ttf', 18)
    for start in range(0, len(candidates), 24):
        page = Image.new('RGB', (1560, 1120), '#101a1f')
        draw = ImageDraw.Draw(page)
        for index, row in enumerate(candidates[start:start + 24]):
            x, y = index % 6 * 260, index // 6 * 280
            page.paste(render_triangles(obj_triangles(Path(row['obj']))), (x, y))
            draw.text((x + 8, y + 234), f"{start + index:02d} {row['id']}", font=font, fill='#e0ece8')
            draw.text((x + 8, y + 255), f"{row['triangles']} 三角面", font=font, fill='#a1b8af')
        target = args.output / f'rtk14-candidates-{start // 24 + 1:02d}.jpg'
        page.save(target, quality=92)
        print('PREVIEW', target.name, flush=True)
    (args.output / 'rtk14-character-audit.json').write_text(json.dumps(candidates, ensure_ascii=False, indent=2), encoding='utf8')
    print('RTK14_CANDIDATES_OK', len(candidates), flush=True)


if __name__ == '__main__':
    main()
