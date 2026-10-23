"""Recover the native painted vegetation biomes, element scales and random seeds."""
from pathlib import Path
import argparse
import hashlib
import importlib.util
import json
import struct
import numpy as np
from PIL import Image


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', type=Path, required=True)
    args = parser.parse_args()
    out = Path(__file__).resolve().parents[2] / 'assets/rtk14/vegetation'
    out.mkdir(parents=True, exist_ok=True)
    spec = importlib.util.spec_from_file_location('kids', args.source / 'scene_parser_import.py')
    kids = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(kids)
    index = json.loads((args.source / 'native-metadata-id-index.json').read_text(encoding='utf8'))
    objects, files = {}, set()

    def resolve(identifier):
        if isinstance(identifier, int): identifier = f'{identifier:08x}'
        for filename in index.get(identifier, []):
            if filename not in files:
                objects.update({r['id']: r for r in kids.parse(args.source / 'metadata' / filename)})
                files.add(filename)
        return objects[identifier]

    native = resolve('e518bbfb')
    data = (args.source / 'metadata' / native['file']).read_bytes()

    def values(key):
        prop = native['props'][key]
        if not isinstance(prop, dict): return list(prop)
        return list(struct.unpack_from('<' + kids.formats[prop['type']][0] * prop['count'], data, prop['offset']))

    resource = np.array(values('ResourceMap'), dtype='uint8').reshape(1024, 1024)
    density = np.array(values('DensityMap'), dtype='<f4').reshape(1024, 1024)
    Image.fromarray(resource).save(out / 'source_resource_map.png')
    density.tofile(out / 'source_density_map.r32')
    info = np.array(values('ElementInfoArray')).reshape(27, 9)
    flags, seeds = values('5c9ee311'), values('e065f0e9')
    elements = []
    for i, identifier in enumerate(values('e3c9c8f0')):
        instance = resolve(identifier)
        template = resolve(instance['parent'])
        displayset = resolve(template['props']['DisplaysetObjectNameHash'][0])
        elements.append({'index': i, 'name': template['props']['ObjNames'],
                         'model': f"{displayset['props']['KTGLModelDataResourceHash'][0]:08x}",
                         'density': float(info[i, 0]), 'minimum_scale': float(info[i, 1]),
                         'maximum_scale': float(info[i, 2]), 'info': info[i].tolist(),
                         'flag': flags[i], 'random_seed': seeds[i],
                         'instance': instance, 'template': template, 'displayset': displayset})
    packed = values('7c441a6e')
    components, at = [], 0
    while at < len(packed):
        count = packed[at]
        components.append(packed[at + 1:at + count + 1])
        assert packed[at + count + 1:at + count + 3] == [0, 0]
        at += count + 3
    biomes = np.array(values('e9567eeb')).reshape(-1, 5).tolist()
    assert len(components) == len(biomes) == 14
    for b in biomes: assert b[0] == 1 and b[2:] == [0, 0, 0]
    unique, counts = np.unique(resource, return_counts=True)
    result = {'file': native['file'], 'object': native['id'], 'source_sha256': hashlib.sha256(data).hexdigest(),
              'field_size_m': (np.array(values('FieldSize')) * .01).tolist(),
              'field_offset_m': (np.array(values('FieldOffset')) * .01).tolist(),
              'map_size': values('6f1ab58b'), 'num_blocks': values('NumBlocks'),
              'resource_map_counts': {str(k): int(v) for k, v in zip(unique, counts)},
              'density_map_range': [float(density.min()), float(density.max())],
              'biome_info': biomes, 'component_elements': components, 'elements': elements,
              'view_distance_m': values('a3dae7da')[0] * .01,
              'update_distance_m': values('79c02ffe')[0] * .01,
              'free_distance_m': values('a2dd60a1')[0] * .01,
              'terrain_type': values('4b80cfb1')[0], 'global_flags': values('dd5651bc')[0],
              'generator_status': 'Native maps, species references, scale ranges and seeds recovered; random-number algorithm and density sampling interpretation require runtime confirmation.'}
    (out / 'native_procedural.json').write_text(json.dumps(result, indent=2), encoding='utf8')
    print('NATIVE_VEGETATION_CONFIG_OK', len(elements), 'elements,', len(biomes), 'biomes,',
          int((resource != 255).sum()), 'painted cells')


if __name__ == '__main__':
    main()
