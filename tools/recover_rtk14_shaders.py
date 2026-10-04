"""Index original G1S shader variants without exporting the entire 4 GB set.

Resource addresses come from the extracted RDB registry. Only terrain and
vegetation variants are retained; other payloads are read transiently.
The game installation is always opened read-only.
"""
from pathlib import Path
import argparse
import collections
import json
import re
import struct
import zlib


def unpack_payload(entry, block, first_only=False):
    size, stored = struct.unpack_from('<qq', block, 8)
    data = block[size - stored:size]
    if not entry['flags'] & 0x100000:
        return data
    at, parts = 0, []
    while at < len(data):
        length = struct.unpack_from('<I', data, at)[0]
        at += 4
        if not length:
            break
        parts.append(zlib.decompress(data[at:at + length]))
        at += length
        if first_only:
            break
    return b''.join(parts)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--game', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    registry = json.loads((args.source / 'all-index.json').read_text())
    archives = collections.defaultdict(list)
    for entry in registry:
        if entry['package'] != 'system' or entry['ext'] != 'g1s':
            continue
        match = re.fullmatch(r'([a-fA-F0-9]+)@([a-fA-F0-9]+)(?:#([a-fA-F0-9]+))?(?:&([a-fA-F0-9]+))?', entry['address'])
        if not match:
            continue
        filename = 'system.rdb.bin'
        if match[3]:
            filename += str(int(match[3], 16))
        if match[4]:
            filename += '_' + str(int(match[4], 16))
        archives[filename].append((int(match[1], 16), int(match[2], 16), entry))
    result, counts, saved, processed = [], collections.Counter(), 0, 0
    for filename, entries in archives.items():
        with (args.game / '0002' / filename).open('rb') as archive:
            cache_start, cache = -1, b''
            for offset, length, entry in sorted(entries):
                if not cache_start <= offset or offset + length > cache_start + len(cache):
                    cache_start = offset
                    archive.seek(offset)
                    cache = archive.read(max(16 * 1024 ** 2, length))
                block = cache[offset - cache_start:offset - cache_start + length]
                try:
                    first = unpack_payload(entry, block, first_only=True)
                    assert first[:8] == b'_S2G3000', (entry['id'], first[:8])
                except (zlib.error, AssertionError, struct.error) as error:
                    result.append({'id': entry['id'], 'error': str(error)})
                    processed += 1
                    continue
                variant = first[16:48].split(b'\0')[0].decode('ascii', errors='replace')
                family = variant.split('-')[0]
                counts[family] += 1
                row = {'id': entry['id'], 'variant': variant, 'family': family, 'size': entry['size']}
                # Native terrain and vegetation families have explicit G1S tags.
                # Keep this broad until the first catalogue establishes the names.
                if re.search('TERR|TERRAIN|GRASS|TREE|FOLI|LAND|GROUND|KTF', family, re.I):
                    data = unpack_payload(entry, block)
                    (args.output / (entry['id'] + '.g1s')).write_bytes(data)
                    row['retained'] = True
                    saved += 1
                result.append(row)
                processed += 1
                if processed % 5000 == 0:
                    print(f'{processed} shaders indexed; {saved} terrain/vegetation variants retained', flush=True)
    (args.output / 'shader-index.json').write_text(json.dumps(result, indent=2), encoding='utf-8')
    (args.output / 'shader-families.json').write_text(json.dumps(counts, indent=2), encoding='utf-8')
    print(json.dumps({'total': processed, 'retained': saved, 'families': counts}), flush=True)


if __name__ == '__main__':
    main()
