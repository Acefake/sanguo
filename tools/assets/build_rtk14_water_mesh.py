"""Cache one-metre river meshes clipped by the original painted footprint.

Source terrain is untouched. Water levels remain explicitly reconstructed.
"""
from pathlib import Path
import hashlib
import json
import struct
import numpy as np
from PIL import Image


def main():
    assets = Path(__file__).resolve().parents[2] / 'assets/rtk14'
    height_path, mask_path = assets / 'world_water_height.r32', assets / 'world_water_mask.png'
    levels = np.fromfile(height_path, '<f4').reshape(2049, 2049)
    mask = np.asarray(Image.open(mask_path)) / 255.0
    output = assets / 'water'
    output.mkdir(parents=True, exist_ok=True)
    parts, total_vertices, total_triangles = [], 0, 0
    for cz in range(8):
        for cx in range(8):
            x0, z0 = cx * 256, cz * 256
            h = levels[z0:z0 + 257, x0:x0 + 257]
            m = mask[z0:z0 + 257, x0:x0 + 257]
            coverage = np.maximum.reduce([m[:-1, :-1], m[:-1, 1:], m[1:, :-1], m[1:, 1:]])
            high = np.maximum.reduce([h[:-1, :-1], h[:-1, 1:], h[1:, :-1], h[1:, 1:]])
            rows, cols = np.nonzero((coverage >= .45) & (high > .31))
            if not len(rows):
                continue
            a = rows * 257 + cols
            full_indices = np.stack([a, a + 1, a + 257, a + 1, a + 258, a + 257], axis=1).ravel()
            selected, indices = np.unique(full_indices, return_inverse=True)
            z, x = np.divmod(selected, 257)
            vertices = np.stack([x + x0, h.ravel()[selected], z + z0], axis=1).astype('<f4')
            indices = indices.astype('<i4')
            parts.append(struct.pack('<4I', cx, cz, len(vertices), len(indices))
                         + vertices.tobytes() + indices.tobytes())
            total_vertices += len(vertices)
            total_triangles += len(indices) // 3
    payload = b'RTKWTR01' + struct.pack('<I', len(parts)) + b''.join(parts)
    (output / 'river_mesh.bin').write_bytes(payload)
    manifest = {'mesh': 'res://assets/rtk14/water/river_mesh.bin',
                'sha256': hashlib.sha256(payload).hexdigest(), 'sampling_step_m': 1,
                'block_size_m': 256, 'blocks': len(parts), 'vertices': total_vertices,
                'triangles': total_triangles, 'mask_threshold': .45,
                'source_mask_sha256': hashlib.sha256(mask_path.read_bytes()).hexdigest(),
                'water_heights_sha256': hashlib.sha256(height_path.read_bytes()).hexdigest(),
                'status': 'Source painted footprint and one-metre relief sampling. Water levels remain reconstructed, not native river control points.'}
    (output / 'river_mesh.json').write_text(json.dumps(manifest, indent=2), encoding='utf8')
    print('SOURCE_SAMPLED_WATER_MESH_OK', len(parts), 'blocks;', total_triangles, 'triangles')


if __name__ == '__main__':
    main()
