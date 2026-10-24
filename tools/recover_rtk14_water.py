"""Recover the active stage's StreamWater texture bindings from native records.

The game archives are opened read-only. The CSV KTID binding uses original
UTF-8 object names, hashed with the bundled native-resource hash utility.
River control points and runtime water levels remain unresolved.
"""
from pathlib import Path
import argparse
import hashlib
import importlib.util
import json
import re
import subprocess
from PIL import Image
from recover_rtk14_shaders import unpack_payload


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--game', type=Path, required=True)
    args = parser.parse_args()
    assets = Path(__file__).resolve().parents[1] / 'assets/rtk14'
    output = assets / 'water'
    output.mkdir(parents=True, exist_ok=True)
    native_output = args.source / 'native-recovery/water'
    native_output.mkdir(parents=True, exist_ok=True)
    registry = {r['id']: r for r in json.loads((args.source / 'all-index.json').read_text())}
    index = json.loads((args.source / 'native-metadata-id-index.json').read_text())
    spec = importlib.util.spec_from_file_location('kids', args.source / 'scene_parser_import.py')
    kids = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(kids)
    files, objects = set(), {}

    def resolve(identifier):
        for name in index[identifier]:
            if name not in files:
                objects.update({r['id']: r for r in kids.parse(args.source / 'metadata' / name)})
                files.add(name)
        return objects[identifier]

    def extract(identifier):
        record = registry[identifier]
        match = re.fullmatch(r'([a-fA-F0-9]+)@([a-fA-F0-9]+)(?:#([a-fA-F0-9]+))?(?:&([a-fA-F0-9]+))?', record['address'])
        if match is None:
            raise ValueError('Unsupported archive address: ' + record['address'])
        filename = record['package'] + '.rdb.bin'
        if match[3]:
            filename += str(int(match[3], 16))
        if match[4]:
            filename += '_' + str(int(match[4], 16))
        with (args.game / '0002' / filename).open('rb') as archive:
            archive.seek(int(match[1], 16))
            block = archive.read(int(match[2], 16))
        data = unpack_payload(record, block)
        target = native_output / f"{identifier}.{record['ext']}"
        target.write_bytes(data)
        return data, target

    displayset = resolve('ecb1e6a0')
    state = resolve(f"{displayset['props']['TexturesRenderStateObjectHash'][0]:08x}")
    binding_id = f"{state['props']['TextureBindTableCSVFileResourceHash'][0]:08x}"
    data, _ = extract(binding_id)
    rows = [line.split(',', 1) for line in data.decode('utf-8-sig').splitlines()
            if line.strip() and not line.startswith(';')]
    result = subprocess.run([str(args.source / 'tools/Nyotengu.Hasher.exe'), '--raw',
                             *[name for _, name in rows]], capture_output=True,
                            check=True, creationflags=0x08000000)
    try:
        hashed = result.stdout.decode('utf8')
    except UnicodeDecodeError:
        hashed = result.stdout.decode('mbcs')
    hashes = {}
    for line in hashed.splitlines():
        match = re.fullmatch(r'([0-9a-fA-F]{8}),(.*)', line)
        if match:
            hashes[match[2]] = match[1].lower()
    textures, exports = [], {}
    for binding, name in rows:
        identifier = hashes[name]
        texture = resolve(identifier)
        g1t = f"{texture['props']['KTGLTexContextResourceHash'][0]:08x}"
        slot = texture['props'].get('TID', [0])[0]
        if g1t not in exports:
            payload, resource = extract(g1t)
            subprocess.run([str(args.source / 'noesis/Noesis64.exe'), '?cmode',
                            str(resource), str(native_output / 'texture.png')],
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                           creationflags=0x08000000)
            exports[g1t] = hashlib.sha256(payload).hexdigest()
        target = output / f'{identifier}.png'
        with Image.open(native_output / f'{slot}.dds') as image:
            image.save(target)
            dimensions = list(image.size)
        textures.append({'binding': int(binding), 'object_name': name,
                         'texture_id': identifier, 'g1t': g1t, 'slot': slot,
                         'g1t_sha256': exports[g1t], 'dimensions': dimensions,
                         'path': 'res://assets/rtk14/water/' + target.name})
    shader = resolve(f"{displayset['props']['KTGLShaderObjectHash'][0]:08x}")
    shader_id = f"{shader['props']['G1SFileResourceHash'][0]:08x}"
    payload, _ = extract(shader_id)
    manifest = {'displayset': displayset, 'texture_state': state, 'shader_object': shader,
                'shader_g1s': shader_id, 'shader_sha256': hashlib.sha256(payload).hexdigest(),
                'binding_table': binding_id, 'binding_sha256': hashlib.sha256(data).hexdigest(),
                'textures': textures,
                'status': 'Native StreamWater resources recovered. Whole-map control points, water levels and runtime material constants are not confirmed.'}
    (output / 'native_water.json').write_text(json.dumps(manifest, indent=2, ensure_ascii=False), encoding='utf8')
    print('NATIVE_WATER_TEXTURES_OK', len(textures), 'textures; shader', shader_id)


if __name__ == '__main__':
    main()
