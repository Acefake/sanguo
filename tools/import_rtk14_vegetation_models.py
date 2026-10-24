"""Recover the three omitted autumn/winter vegetation models and native textures."""
from pathlib import Path
import argparse
import importlib.util
import json
import re
import struct
import subprocess
from PIL import Image
from recover_rtk14_shaders import unpack_payload


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--game', type=Path, required=True)
    args = parser.parse_args()
    assets = Path(__file__).resolve().parents[1] / 'assets/rtk14'
    flora = json.loads((assets / 'vegetation/native_procedural.json').read_text(encoding='utf8'))
    registry = {r['id']: r for r in json.loads((args.source / 'all-index.json').read_text(encoding='utf8'))}
    index = json.loads((args.source / 'native-metadata-id-index.json').read_text(encoding='utf8'))
    spec = importlib.util.spec_from_file_location('kids', args.source / 'scene_parser_import.py')
    kids = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(kids)
    objects, parsed = {}, set()

    def resolve(identifier):
        for filename in index.get(identifier, []):
            if filename not in parsed:
                objects.update({r['id']: r for r in kids.parse(args.source / 'metadata' / filename)})
                parsed.add(filename)
        return objects[identifier]

    def export(identifier, target):
        if target.exists(): return target.read_bytes()
        record = registry[identifier]
        match = re.fullmatch(r'([a-fA-F0-9]+)@([a-fA-F0-9]+)(?:#([a-fA-F0-9]+))?(?:&([a-fA-F0-9]+))?', record['address'])
        filename = record['package'] + '.rdb.bin'
        if match[3]: filename += str(int(match[3], 16))
        if match[4]: filename += '_' + str(int(match[4], 16))
        with (args.game / '0002' / filename).open('rb') as archive:
            archive.seek(int(match[1], 16))
            payload = unpack_payload(record, archive.read(int(match[2], 16)))
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(payload)
        return payload

    links = json.loads((args.source / 'model-texture-links.json').read_text(encoding='utf8'))
    textures = json.loads((args.source / 'converted-textures.json').read_text(encoding='utf8'))
    models = json.loads((assets / 'models.json').read_text(encoding='utf8'))
    selected = []
    for element_index in [24, 25, 26]:
        element = flora['elements'][element_index]
        model = element['model']
        selected.append(model)
        source = args.source / 'samples' / f'{model}.g1m'
        data = export(model, source)
        obj = args.source / 'obj' / f'{model}.obj'
        if not obj.exists():
            subprocess.run([str(args.source / 'noesis/Noesis64.exe'), '?cmode', str(source), str(obj)],
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                           creationflags=0x08000000)
        state = resolve(f"{element['displayset']['props']['TexturesRenderStateObjectHash'][0]:08x}")
        ktid = state['props']['TextureBindTableCSVFileResourceHash'][0]
        table = (args.source / 'metadata' / f'{ktid:08x}.ktid').read_bytes()
        bindings = dict(struct.unpack_from('<II', table, at) for at in range(0, len(table), 8))
        base = data.index(b'GM1G')
        at, materials, ranges = base + 48, [], []
        for _ in range(struct.unpack_from('<I', data, base + 44)[0]):
            kind, size = struct.unpack_from('<II', data, at)
            if kind == 0x10002:
                count = struct.unpack_from('<I', data, at + 8)[0]
                cursor = at + 12
                for _ in range(count):
                    _, amount, _, _ = struct.unpack_from('<4I', data, cursor)
                    cursor += 16
                    entries = [list(struct.unpack_from('<6H', data, cursor + n * 12)) for n in range(amount)]
                    cursor += amount * 12
                    color = next(e for e in entries if e[2] == 1)
                    normal = next((e for e in entries if e[2] == 3), None)
                    materials.append({'texture': f'{bindings[color[0]]:08x}',
                                      'normal': f'{bindings[normal[0]]:08x}' if normal else None,
                                      'entries': entries})
            if kind == 0x10008:
                count = struct.unpack_from('<I', data, at + 8)[0]
                ranges = [list(struct.unpack_from('<14I', data, at + 12 + n * 56)) for n in range(count)]
            at += size
        links[model] = {'materials': materials, 'submeshes': ranges}
        for material in materials:
            for identifier in [material['texture'], material['normal']]:
                if not identifier: continue
                texture = resolve(identifier)
                resource = f"{texture['props']['KTGLTexContextResourceHash'][0]:08x}"
                slot = texture['props'].get('TID', [0])[0]
                folder = args.source / 'model-textures' / resource
                g1t = folder / f'{resource}.g1t'
                export(resource, g1t)
                target = assets / 'textures' / f'{identifier}.png'
                if not target.exists():
                    subprocess.run([str(args.source / 'noesis/Noesis64.exe'), '?cmode', str(g1t),
                                    str(folder / 'texture.png')], check=True, stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL, creationflags=0x08000000)
                    Image.open(folder / f'{slot}.dds').save(target)
                textures[identifier] = {'g1t': resource, 'slot': slot,
                                        'path': 'res://assets/rtk14/textures/' + target.name}
        models[model] = {'name': element['name'], 'path': 'res://assets/rtk14/models/' + model + '.glb'}
        print('NATIVE_VEGETATION_MODEL_RECOVERED', model, len(ranges), flush=True)
    for target, value in [(args.source / 'model-texture-links.json', links),
                          (assets / 'model_texture_links.json', links),
                          (args.source / 'converted-textures.json', textures),
                          (assets / 'models.json', models)]:
        target.write_text(json.dumps(value, indent=2), encoding='utf8')
    sources = json.loads((assets / 'texture_sources.json').read_text(encoding='utf8'))
    sources.update(textures)
    (assets / 'texture_sources.json').write_text(json.dumps(sources, indent=2), encoding='utf8')
    subprocess.run([str(Path(__import__('sys').executable)), str(Path(__file__).with_name('convert_rtk14_models.py')),
                    '--source', str(args.source), '--models', *selected], check=True)


if __name__ == '__main__':
    main()
