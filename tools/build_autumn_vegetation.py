"""Reconstruct fixed placements inside native autumn/winter vegetation biomes.

Maps, species, scales and seeds are native. The runtime PRNG and exact density
sampling are unconfirmed, as recorded explicitly in the output manifest.
"""
from pathlib import Path
import json
import struct
import numpy as np
from PIL import Image

OUT = Path(__file__).resolve().parents[1] / 'assets/rtk14'
config = json.loads((OUT / 'vegetation/native_procedural.json').read_text(encoding='utf8'))
resource = np.asarray(Image.open(OUT / 'vegetation/source_resource_map.png'))
density = np.fromfile(OUT / 'vegetation/source_density_map.r32', '<f4').reshape(resource.shape)
# Source -aw variants and component groups identify autumn/winter species.
# The original runtime seasonal conversion table is still unconfirmed.
autumn = {0: 17, 1: 26, 2: 24, 3: 18, 5: 25, 6: 19,
          7: 20, 8: 21, 9: 22, 15: 23, 16: 23}
selected = []
for biome in np.unique(resource):
    if biome == 255: continue
    component = config['biome_info'][int(biome)][1]
    selected.extend(autumn.get(i, i) for i in config['component_elements'][component])
models = list(dict.fromkeys(config['elements'][i]['model'] for i in selected))
ground_models = list(dict.fromkeys(config['elements'][i]['model'] for i in selected
                                  if 'plane-' in config['elements'][i]['name']))
tree_models = [model for model in models if model not in ground_models]
models = tree_models + ground_models
records, counts, trees, ground = [], {}, 0, 0
width, depth = config['field_size_m']
offset_x, offset_z = config['field_offset_m']
for biome in np.unique(resource):
    if biome == 255: continue
    component = config['biome_info'][int(biome)][1]
    cells = np.argwhere(resource == biome)
    z, x = cells.T
    for source_element in config['component_elements'][component]:
        element = config['elements'][autumn.get(source_element, source_element)]
        rng = np.random.RandomState(element['random_seed'])
        probability = np.clip(density[z, x] * element['density'], 0, 1)
        accepted = rng.random_sample(len(cells)) < probability
        chosen = cells[accepted]
        count = len(chosen)
        positions = chosen[:, ::-1] + rng.random_sample((count, 2))
        positions[:, 0] = offset_x + positions[:, 0] * width / resource.shape[1]
        positions[:, 1] = offset_z + positions[:, 1] * depth / resource.shape[0]
        sizes = rng.uniform(element['minimum_scale'], element['maximum_scale'], count)
        angles = rng.uniform(0, np.pi * 2, count)
        kind = models.index(element['model'])
        records.append(np.column_stack([np.full(count, kind), positions, sizes,
                                        angles, np.zeros(count)]).astype('<f4'))
        counts[f'{int(biome)}:{element["index"]}'] = count
        if element['model'] in ground_models: ground += count
        else: trees += count
records = np.concatenate(records)
(OUT / 'autumn_vegetation.bin').write_bytes(b'RTKPLT02' + struct.pack('<I', len(records)) + records.tobytes())
meta = {'trees': trees, 'ground_cover': ground, 'model_ids': models,
        'tree_models': tree_models, 'ground_cover_models': ground_models,
        'biome_element_counts': counts, 'season': 'autumn/winter -aw source variants',
        'source': 'KIDSSystemResource_b43fcef2.kidsobjdb / e518bbfb',
        'native_resource_map': 'vegetation/source_resource_map.png',
        'native_density_map': 'vegetation/source_density_map.r32',
        'native_element_parameters': 'vegetation/native_procedural.json',
        'source_painted_cells': int((resource != 255).sum()),
        'sampler': 'MT19937 using native per-element seeds; density sampled as probability per 2m cell',
        'unconfirmed': 'Original PRNG, density units and seasonal-switch logic; per-plant coordinates remain reconstructed.'}
(OUT / 'autumn_vegetation.json').write_text(json.dumps(meta, indent=2), encoding='utf8')
print('NATIVE_BIOME_PLANTING_OK trees=', trees, 'ground_cover=', ground, 'models=', len(models))
