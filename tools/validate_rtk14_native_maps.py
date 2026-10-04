"""Validate against original binary maps and the native baked albedo, not screenshots."""
from pathlib import Path
import argparse
import json
import struct
import numpy as np
from PIL import Image


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    assets = root / 'assets/rtk14'
    terrain = assets / 'terrain'
    world = (args.source / 'field-textures/239167e0.g1t').read_bytes()
    table = struct.unpack_from('<I', world, 12)[0]
    offsets = [table + n for n in struct.unpack_from('<5I', world, table)]
    source_height = world[offsets[0] + 28:offsets[0] + 28 + 2049 ** 2 * 4]
    assert source_height == (assets / 'heightmap.r32').read_bytes()
    assert source_height == (assets / 'world_preview_height.r32').read_bytes()
    source_control = world[offsets[1] + 28:offsets[1] + 28 + 2049 ** 2 * 4]
    assert Image.open(terrain / 'source_control.png').tobytes() == source_control
    procedural = json.loads((assets / 'vegetation/native_procedural.json').read_text(encoding='utf8'))
    database = (args.source / 'metadata' / procedural['file']).read_bytes()
    records = json.loads((assets / 'native-recovery/procedural-placement-objects.json').read_text(encoding='utf8'))
    properties = next(r['props'] for r in records if r['id'] == procedural['object'])
    density = properties['DensityMap']
    resource = properties['ResourceMap']
    assert (assets / 'vegetation/source_density_map.r32').read_bytes() == database[
        density['offset']:density['offset'] + density['count'] * 4]
    assert Image.open(assets / 'vegetation/source_resource_map.png').tobytes() == database[
        resource['offset']:resource['offset'] + resource['count']]
    painting = np.asarray(Image.open(assets / 'vegetation/source_resource_map.png'))
    cache = (assets / 'autumn_vegetation.bin').read_bytes()
    assert cache[:8] == b'RTKPLT02'
    count = struct.unpack_from('<I', cache, 8)[0]
    plants = np.frombuffer(cache, '<f4', offset=12).reshape(count, 6)
    assert ((plants[:, 1:3] >= 0) & (plants[:, 1:3] < 2048)).all()
    assert (painting[(plants[:, 2] / 2).astype(int), (plants[:, 1] / 2).astype(int)] != 255).all()
    # The original 4096px bake independently identifies physical tile periods.
    # Prefilter the source tile to the bake's pixel footprint before comparing.
    config = json.loads((terrain / 'native_materials.json').read_text(encoding='utf8'))
    control = np.asarray(Image.open(terrain / 'source_control.png'))
    baked = np.asarray(Image.open(terrain / 'source_albedo.png'))[:, :, :3]
    rng = np.random.default_rng(14)
    colors = np.array([.299, .587, .114])
    correlations = {}
    for index in [0, 1, 5, 6, 9]:
        material = config['materials'][index]
        cells = np.argwhere((control[:, :, 2] == index) & (control[:, :, 1] == 255))
        cells = cells[rng.choice(len(cells), min(12000, len(cells)), replace=False)]
        z, x = cells.T.astype(float) + .25
        reference = baked[np.minimum((z * 2).astype(int), 4095),
                          np.minimum((x * 2).astype(int), 4095)] @ colors
        size = 2 ** round(np.log2(material['scale_u'] * 2))
        tile = np.asarray(Image.open(terrain / f'layer_{material["texture_layer"]:02d}_albedo.png')
                          .resize((size, size), Image.Resampling.BOX))[:, :, :3].astype(float)
        result = {}
        for factor in [1, .1, 10]:
            u = (x / (material['scale_u'] * factor) % 1) * size - .5
            v = (z / (material['scale_v'] * factor) % 1) * size - .5
            ix, iz = np.floor(u).astype(int), np.floor(v).astype(int)
            fx, fz = (u - ix)[:, None], (v - iz)[:, None]
            sample = (tile[iz % size, ix % size] * (1 - fx) * (1 - fz)
                      + tile[iz % size, (ix + 1) % size] * fx * (1 - fz)
                      + tile[(iz + 1) % size, ix % size] * (1 - fx) * fz
                      + tile[(iz + 1) % size, (ix + 1) % size] * fx * fz) @ colors
            result[str(factor)] = float(np.corrcoef(reference, sample)[0, 1])
        assert result['1'] > .70, (index, result)
        assert result['1'] - max(result['0.1'], result['10']) > .60
        correlations[str(index)] = result
    report = {'original_height_samples_identical': 2049 ** 2,
              'control_bytes_identical': len(source_control),
              'density_samples_identical': density['count'], 'resource_cells_identical': resource['count'],
              'plant_cache_records_inside_native_painting': count,
              'native_bake_tile_period_correlations': correlations,
              'unverified': 'PRNG, density-to-candidate interpretation, original renderer environment and dynamic building registration'}
    (root / 'docs/validation/native-source-map-check.json').write_text(json.dumps(report, indent=2), encoding='utf8')
    print('NATIVE_SOURCE_MAPS_OK height/control/density/resources exact; tile-period correlations verified')


if __name__ == '__main__':
    main()
