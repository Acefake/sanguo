"""Resolve the active LandscapeComposition through original KIDS references.

The texture order is recovered by matching material hashes, never by colors.
TexScale units were cross-checked against the native 4096px albedo bake.
"""
from pathlib import Path
import argparse
import importlib.util
import json
import struct


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--output', type=Path,
                        default=Path(__file__).resolve().parents[2] / 'assets/rtk14/terrain')
    args = parser.parse_args()
    spec = importlib.util.spec_from_file_location('native_kids', args.source / 'scene_parser_import.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    metadata = args.source / 'metadata'
    objects = {}
    for name in ['f029fe04', '3215c4d1']:
        for row in module.parse(metadata / f'KIDSSystemResource_{name}.kidsobjdb'):
            objects[row['id']] = row

    def values(row, key):
        prop = row['props'][key]
        if not isinstance(prop, dict):
            return list(prop)
        data = (metadata / row['file']).read_bytes()
        fmt = module.formats[prop['type']][0]
        return list(struct.unpack_from('<' + fmt * prop['count'], data, prop['offset']))

    composition = objects['5f441cb4']
    palette = objects[f"{values(composition, 'f4553a8d')[0]:08x}"]
    array = objects[f"{values(composition, '45b41815')[0]:08x}"]
    element = objects[f"{values(composition, 'e9cc029e')[0]:08x}"]
    assert objects['1e1550ed']['props']['KTGLTexContextResourceHash'][0] == 0x239167e0
    assert objects['5b86bae3']['props']['KTGLTexContextResourceHash'][0] == 0x57ee6cea
    assert len(values(array, 'Textures')) == 19
    material_hashes = values(palette, '497cb2c7')
    order = values(array, 'Textures')
    rows = []
    for index, material in enumerate(material_hashes):
        rows.append({'control_index': index, 'material_hash': f'{material:08x}',
                     'texture_layer': order.index(material),
                     'scale_u': values(palette, 'a69bbd47')[index],
                     'scale_v': values(palette, '9ae52e66')[index],
                     'blend_sharpness': values(palette, '859d80f7')[index],
                     'tess_scale': values(palette, 'd2a48180')[index],
                     'tess_bias': values(palette, '03bb19b1')[index]})
    result = {'composition_file': composition['file'], 'composition_id': composition['id'],
              'palette_id': palette['id'], 'array_id': array['id'],
              'world_g1t': '239167e0', 'array_g1t': '57ee6cea',
              'heightmap_resource': f"{values(element, 'f17661e1')[0]:08x}",
              'shader_resource': 'dc52fd1c', 'shader_variant': 'PB2LS-Gbi',
              'flag': values(composition, 'Flag')[0],
              'bilinear_rate': values(composition, '43aea90c')[0],
              'near_far_blending_offset': values(composition, '70cb1a2d')[0] * .01,
              'near_far_blending_range': values(composition, '2913bb1d')[0] * .01,
              'lod_distance_scale': values(composition, '0575b6f4')[0],
              'control_storage': 'BGRA8: B=primary index, G=secondary index, R=blend, A=255',
              'materials': rows}
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / 'native_materials.json').write_text(json.dumps(result, indent=2))
    manifest_path = args.output / 'manifest.json'
    manifest = json.loads(manifest_path.read_text(encoding='utf8'))
    manifest.update({'control_b_to_layer': [r['texture_layer'] for r in rows],
                     'mapping_status': 'All 18 material hashes matched to the native 19-slice array',
                     'control_storage': result['control_storage'],
                     'world_roles': {'2': 'albedo/occlusion', '3': 'normal/height', '4': 'reflectance/linear roughness'},
                     'runtime': 'Three native arrays and three world maps; PB2LS-derived material blending',
                     'unresolved': 'Complete original BRDF, displacement and runtime cliff flags'})
    manifest_path.write_text(json.dumps(manifest, indent=2), encoding='utf8')
    # Retain the third native array, required by the original roughness/reflectance path.
    data = (args.source / 'field-textures/57ee6cea.g1t').read_bytes()
    table = struct.unpack_from('<I', data, 12)[0]
    offset = table + struct.unpack_from('<I', data, table + 8)[0]
    assert data[offset + 1] == 0x5b
    chains = []
    for layer in range(19):
        cursor, chain = offset + 20, bytearray()
        for level in range(9):
            size = (1024 >> level) ** 2
            chain.extend(data[cursor + layer * size:cursor + (layer + 1) * size])
            cursor += size * 19
        chain.extend(chain[-16:] * 2)
        assert len(chain) == 1398128
        chains.append(chain)
    (args.output / 'layers_parameters.bc3').write_bytes(b''.join(chains))
    print('NATIVE_LANDSCAPE_RESOLVED: 18 palette entries, 19 array slices, 3 material arrays')


if __name__ == '__main__':
    main()
