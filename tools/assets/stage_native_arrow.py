"""Stage the native RTK14 arrow with its verified texture binding and UVs."""
from pathlib import Path
import argparse
import json
import shutil
import struct
import subprocess
import sys

import numpy as np
from PIL import Image
from extract_rtk14_army_candidates import extract
from import_rtk14_army_assets import materials_and_ranges

ROOT = Path(__file__).resolve().parents[2]


def load(path):
    return json.loads(path.read_text(encoding='utf-8')) if path.exists() else {}


def save(path, data):
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


def orient(source, target, provenance):
    raw = source.read_bytes()
    size = struct.unpack_from('<I', raw, 12)[0]
    doc = json.loads(raw[20:20 + size])
    binary = bytearray(raw[28 + size:])
    attributes = doc['meshes'][0]['primitives'][0]['attributes']
    for attribute in ('POSITION', 'NORMAL'):
        accessor = doc['accessors'][attributes[attribute]]
        view = doc['bufferViews'][accessor['bufferView']]
        offset = view.get('byteOffset', 0) + accessor.get('byteOffset', 0)
        points = np.frombuffer(binary, '<f4', accessor['count'] * 3, offset).reshape(-1, 3)
        points[:] = points[:, [2, 1, 0]]
        if attribute == 'POSITION':
            points[:, 2] -= .55
            accessor.update(min=points.min(0).tolist(), max=points.max(0).tolist())
    doc['extras'] = provenance
    encoded = json.dumps(doc, separators=(',', ':')).encode('utf-8')
    encoded += b' ' * (-len(encoded) % 4)
    target.write_bytes(struct.pack('<III', 1179937895, 2, 28 + len(encoded) + len(binary))
                       + struct.pack('<II', len(encoded), 1313821514) + encoded
                       + struct.pack('<II', len(binary), 5130562) + binary)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True, help='Extraction folder with all-index.json and noesis/')
    parser.add_argument('--game-root', type=Path, required=True)
    parser.add_argument('--cache', type=Path, default=ROOT / 'tools/army-source-cache')
    args = parser.parse_args()
    output = ROOT / 'assets/armies/rtk14'
    index = {row['id']: row for row in load(args.source / 'all-index.json')}
    objects = load(args.cache / 'native-links.json')
    by_id = {row['id']: row for row in objects}
    identifier = 'f893127a'
    display = next(row for row in objects if row['props'].get('KTGLModelDataResourceHash') == [int(identifier, 16)])
    state = by_id[f"{display['props']['TexturesRenderStateObjectHash'][0]:08x}"]
    binding = f"{state['props']['TextureBindTableCSVFileResourceHash'][0]:08x}"
    table = extract(index[binding], args.game_root)
    slots = dict(struct.unpack_from('<II', table, offset) for offset in range(0, len(table), 8))
    links = load(args.cache / 'model-texture-links.json')
    links[identifier] = materials_and_ranges((args.cache / (identifier + '.g1m')).read_bytes(), slots)
    textures = load(args.cache / 'converted-textures.json')
    sources = load(output / 'texture_sources.json')
    for material in links[identifier]['materials']:
        for texture in (material['texture'], material['normal']):
            if texture is None:
                continue
            node = by_id.get(texture, {})
            resource_id = f"{node['props']['KTGLTexContextResourceHash'][0]:08x}" if node else texture
            slot = int(node.get('props', {}).get('TID', [0])[0])
            target = output / 'textures' / (texture + '.png')
            if not target.exists():
                raw_texture = args.cache / (resource_id + '.g1t')
                if not raw_texture.exists():
                    raw_texture.write_bytes(extract(index[resource_id], args.game_root))
                decoded = args.cache / 'decoded-textures' / resource_id
                decoded.mkdir(parents=True, exist_ok=True)
                subprocess.run([str(args.source / 'noesis/Noesis64.exe'), '?cmode', str(raw_texture), str(decoded / 'texture.png')],
                               check=True, capture_output=True, timeout=45,
                               creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
                with Image.open(decoded / f'{slot}.dds') as image:
                    image.save(target)
            with Image.open(target) as image:
                image.verify()
            sources[texture] = textures[texture] = {'source_package': index[resource_id]['package'], 'resource': resource_id, 'slot': slot}
    save(args.cache / 'model-texture-links.json', links)
    save(args.cache / 'converted-textures.json', textures)
    (args.cache / 'obj').mkdir(exist_ok=True)
    shutil.copyfile(args.cache / (identifier + '.obj'), args.cache / 'obj' / (identifier + '.obj'))
    subprocess.run([sys.executable, '-X', 'utf8', str(ROOT / 'tools/assets/convert_rtk14_models.py'),
                    '--source', str(args.cache), '--output', str(output), '--models', identifier], check=True)
    provenance = {'source_model': identifier, 'texture_binding': binding,
                  'materials': links[identifier]['materials'], 'orientation': 'original +X to field +Z'}
    orient(output / 'models' / (identifier + '.glb'), output / 'models/arrow.glb', provenance)
    save(output / 'texture_sources.json', sources)
    effects = load(output / 'effects/sources.json')
    effects['arrow_trail']['usage'] = 'Archived native streak candidate; unused by current troop and city projectiles.'
    effects['arrow_model'] = {**provenance, 'file': 'res://assets/armies/rtk14/models/arrow.glb',
                             'source_package': index[identifier]['package'], 'native_database': display['file'],
                             'usage': 'Original geometry, UVs and material references; trajectory and volley timing authored locally.'}
    save(output / 'effects/sources.json', effects)
    manifest = load(output / 'manifest.json')
    manifest[identifier] = {'label': '箭矢', 'role': 'arrow', 'path': effects['arrow_model']['file'],
                            'source_model': identifier, 'source_package': index[identifier]['package'],
                            'native_database': display['file'], 'texture_binding': binding,
                            'materials': provenance['materials'], 'animation_status': 'native geometry; authored ballistic playback',
                            'unresolved_textures': [], 'verification': 'native material references and rendered UVs', 'triangles': 630}
    save(output / 'manifest.json', manifest)
    print('NATIVE_ARROW_STAGED', identifier, binding, provenance['materials'])


if __name__ == '__main__':
    main()
