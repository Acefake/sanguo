"""Resolve model material and texture references without loading the 495 MB JSON.

The source KIDS databases and game archives are read-only. An ID/file index in
the extraction directory avoids rescanning every database on later runs.
"""
from pathlib import Path
import argparse
import importlib.util
import json
import struct


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--output', type=Path, default=Path(__file__).resolve().parents[1]
                        / 'assets/rtk14/native-recovery/model-materials.json')
    args = parser.parse_args()
    meta = args.source / 'metadata'
    cache = args.source / 'native-metadata-id-index.json'
    if cache.exists():
        index = json.loads(cache.read_text(encoding='utf8'))
    else:
        index = {}
        files = sorted(meta.glob('*.kidsobjdb'))
        for number, path in enumerate(files):
            data = path.read_bytes()
            offset = struct.unpack_from('<I', data, 8)[0]
            count = struct.unpack_from('<I', data, 16)[0]
            for _ in range(count):
                size, oid = struct.unpack_from('<II', data, offset + 8)
                index.setdefault(f'{oid:08x}', []).append(path.name)
                offset += (size + 3) & ~3
            if number % 500 == 0:
                print('KIDS_INDEX', number, '/', len(files), flush=True)
        cache.write_text(json.dumps(index, separators=(',', ':')), encoding='utf8')
        print('KIDS_INDEX_OK', len(index), flush=True)
    spec = importlib.util.spec_from_file_location('kids', args.source / 'scene_parser_import.py')
    kids = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(kids)
    objects, parsed_files = {}, set()

    def resolve(identifier):
        if isinstance(identifier, int):
            identifier = f'{identifier:08x}'
        for filename in index.get(identifier, []):
            if filename not in parsed_files:
                objects.update({row['id']: row for row in kids.parse(meta / filename)})
                parsed_files.add(filename)
        return objects.get(identifier)

    world = json.loads((args.source / 'world-scene-records.json').read_text(encoding='utf8'))
    project_assets = args.output.parent.parent
    links = json.loads((project_assets / 'model_texture_links.json').read_text(encoding='utf8'))
    model_objects = {f"{r['props']['KTGLModelDataResourceHash'][0]:08x}": r for r in world
                     if r['props'].get('KTGLModelDataResourceHash')}
    result = {}
    for model, link in links.items():
        native = model_objects.get(model)
        if not native:
            continue
        props = native['props']
        state = resolve(props['TexturesRenderStateObjectHash'][0])
        table_hash = state['props']['TextureBindTableCSVFileResourceHash'][0]
        table = (meta / f'{table_hash:08x}.ktid').read_bytes()
        binding = dict(struct.unpack_from('<II', table, offset)
                       for offset in range(0, len(table), 8))
        group_file = meta / f"{props['KTGLMaterialGroupBindTableResourceHash'][0]:08x}.mtl"
        group_data = group_file.read_bytes()
        # The material-group table header is four words; each row is hash, count, index.
        group_hashes = [struct.unpack_from('<I', group_data, offset)[0]
                        for offset in range(16, len(group_data), 12)]
        materials = []
        for material in link['materials']:
            textures = []
            for entry in material['entries']:
                identifier = binding[entry[0]]
                texture = resolve(identifier)
                assert texture, (model, f'{identifier:08x}')
                textures.append({'binding': entry[0], 'usage': entry[2], 'shader_slot': entry[3],
                                 'texture_id': f'{identifier:08x}',
                                 'g1t': f"{texture['props']['KTGLTexContextResourceHash'][0]:08x}",
                                 'slot': texture['props'].get('TID', [0])[0], 'object': texture})
            materials.append({'textures': textures})
        result[model] = {'displayset': native, 'texture_state': state,
                         'material_groups': [resolve(identifier) for identifier in group_hashes],
                         'materials': materials}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2), encoding='utf8')
    print('MODEL_MATERIAL_REFERENCES_OK', len(result), 'models', flush=True)


if __name__ == '__main__':
    main()
