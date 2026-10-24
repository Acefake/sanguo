"""Build an isolated low-amplitude view of the source PB2LS height channel.

The original tessellation globals are not recovered, so this never changes the
production height map. The output is a diagnostic delta in metres.
"""
from pathlib import Path
import argparse
import json
import numpy as np
from PIL import Image


def sample_alpha(image, x, z, sx, sz):
    h, w = image.shape
    u = np.mod(x / sx, 1.0) * w - 0.5
    v = np.mod(z / sz, 1.0) * h - 0.5
    ix, iz = np.floor(u).astype(np.int32), np.floor(v).astype(np.int32)
    fx, fz = u - ix, v - iz
    a = image[iz % h, ix % w]
    b = image[iz % h, (ix + 1) % w]
    c = image[(iz + 1) % h, ix % w]
    d = image[(iz + 1) % h, (ix + 1) % w]
    return ((a * (1 - fx) + b * fx) * (1 - fz)
            + (c * (1 - fx) + d * fx) * fz)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--gain', type=float, default=0.01,
                        help='diagnostic scale applied to native tessScale/tessBias')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    assets = root / 'assets/rtk14'
    terrain = assets / 'terrain'
    native = json.loads((terrain / 'native_materials.json').read_text(encoding='utf8'))
    control = np.asarray(Image.open(terrain / 'source_control.png'))
    base = np.fromfile(assets / 'heightmap.r32', '<f4').reshape(2049, 2049) * .01
    dz, dx = np.gradient(base)
    normal_y = 1.0 / np.sqrt(1.0 + dx * dx + dz * dz)
    delta = np.zeros_like(base)
    materials = native['materials']
    tile_cache = {}
    for y0 in range(0, 2049, 128):
        y1 = min(y0 + 128, 2049)
        row = control[y0:y1]
        yy, xx = np.mgrid[y0:y1, 0:2049]
        primary = row[:, :, 2]
        secondary = row[:, :, 1]
        mix = row[:, :, 0].astype(np.float32) / 255.0
        primary_height = np.zeros(primary.shape, dtype=np.float32)
        secondary_height = np.zeros(primary.shape, dtype=np.float32)
        for index, material in enumerate(materials):
            layer = material['texture_layer']
            if layer not in tile_cache:
                image = np.asarray(Image.open(terrain / f'layer_{layer:02d}_normal.png'))[:, :, 3].astype(np.float32) / 255.0
                tile_cache[layer] = image
            tile = tile_cache[layer]
            for code, target in ((index, primary_height), (index, secondary_height)):
                mask = primary == code if target is primary_height else secondary == code
                if not np.any(mask):
                    continue
                alpha = sample_alpha(tile, xx[mask], yy[mask], material['scale_u'], material['scale_v'])
                target[mask] = alpha * material['tess_scale'] + material['tess_bias']
        has_secondary = secondary < len(materials)
        height_offset = np.where(has_secondary,
                                 primary_height * (1.0 - mix) + secondary_height * mix,
                                 primary_height)
        delta[y0:y1] = height_offset * normal_y[y0:y1] * args.gain
    out = root / 'docs/validation/native-tessellation-probe-delta.r32'
    delta.astype('<f4').tofile(out)
    report = {'source_shader': 'dc52fd1c PB2LS-Gbi, tessellated domain variant 141',
              'source_alpha': '57ee6cea normal/height array alpha',
              'material_formula': 'normalHeightAlpha * tessScale + tessBias',
              'native_runtime_fade': 'Unknown; gain=0.01 is a diagnostic assumption only',
              'gain': args.gain, 'delta_min_m': float(delta.min()),
              'delta_median_m': float(np.median(delta)),
              'delta_max_m': float(delta.max()), 'delta_stddev_m': float(delta.std()),
              'delta_sha256': __import__('hashlib').sha256(out.read_bytes()).hexdigest(),
              'status': 'Preview-only candidate. Does not replace the production terrain.'}
    (root / 'docs/validation/native-tessellation-probe.json').write_text(
        json.dumps(report, indent=2), encoding='utf8')
    print('NATIVE_TESSELLATION_PROBE_OK', json.dumps(report))


if __name__ == '__main__':
    main()
