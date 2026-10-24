"""Check exported water pixels and mesh against independently read source bytes."""
from pathlib import Path
import argparse
import hashlib
import json
import struct
import numpy as np
from PIL import Image


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    assets = root / 'assets/rtk14'
    water = assets / 'water'
    binding = json.loads((water / 'native_water.json').read_text(encoding='utf8'))
    native = (args.source / 'native-recovery/water/bf537a03.g1t').read_bytes()
    table = struct.unpack_from('<I', native, 12)[0]
    slots = struct.unpack_from('<2I', native, table)
    pixels = 0
    for texture in binding['textures']:
        assert hashlib.sha256(native).hexdigest() == texture['g1t_sha256']
        offset = table + slots[texture['slot']]
        assert native[offset + 1] == 1  # Uncompressed BGRA8, not a guessed decoder.
        width, height = texture['dimensions']
        raw = np.frombuffer(native, np.uint8, width * height * 4, offset + 20)
        rgba = raw.reshape(height, width, 4)[:, :, [2, 1, 0, 3]]
        exported = np.asarray(Image.open(water / (texture['texture_id'] + '.png')))
        assert np.array_equal(rgba, exported), texture['texture_id']
        pixels += width * height
    levels = np.fromfile(assets / 'world_water_height.r32', '<f4').reshape(2049, 2049)
    payload = (water / 'river_mesh.bin').read_bytes()
    manifest = json.loads((water / 'river_mesh.json').read_text())
    assert hashlib.sha256(payload).hexdigest() == manifest['sha256']
    assert payload[:8] == b'RTKWTR01'
    blocks = struct.unpack_from('<I', payload, 8)[0]
    cursor, vertices_total, triangles_total = 12, 0, 0
    seen = set()
    for _ in range(blocks):
        cx, cz, nv, ni = struct.unpack_from('<4I', payload, cursor)
        cursor += 16
        assert (cx, cz) not in seen
        seen.add((cx, cz))
        vertices = np.frombuffer(payload, '<f4', nv * 3, cursor).reshape(nv, 3)
        cursor += nv * 12
        indices = np.frombuffer(payload, '<i4', ni, cursor)
        cursor += ni * 4
        assert ni % 3 == 0 and indices.min() >= 0 and indices.max() < nv
        x, z = vertices[:, 0], vertices[:, 2]
        assert np.isfinite(vertices).all()
        assert ((x >= cx * 256) & (x <= (cx + 1) * 256)).all()
        assert ((z >= cz * 256) & (z <= (cz + 1) * 256)).all()
        assert np.array_equal(x, np.floor(x)) and np.array_equal(z, np.floor(z))
        assert np.array_equal(vertices[:, 1], levels[z.astype(int), x.astype(int)])
        triangles = vertices[indices].reshape(-1, 3, 3)
        area = np.cross(triangles[:, 1] - triangles[:, 0], triangles[:, 2] - triangles[:, 0])[:, 1]
        assert np.all(area == -1), 'Each triangle must occupy half of a one-metre cell.'
        vertices_total += nv
        triangles_total += ni // 3
    assert cursor == len(payload)
    assert (blocks, vertices_total, triangles_total) == (manifest['blocks'], manifest['vertices'], manifest['triangles'])
    report = {'source_normal_pixels_identical': pixels, 'blocks': blocks,
              'vertices_with_identical_cached_height': vertices_total,
              'one_metre_triangles': triangles_total,
              'unverified': 'Original water levels, river control points, reflection environment and material constants.'}
    (root / 'docs/validation/native-water-check.json').write_text(json.dumps(report, indent=2), encoding='utf8')
    print('NATIVE_WATER_CHECK_OK', json.dumps(report))


if __name__ == '__main__':
    main()
