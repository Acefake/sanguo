"""Stage visually identified troop assets using their original material bindings."""
from pathlib import Path
import argparse
import json
import re
import struct
import subprocess
from PIL import Image
from extract_rtk14_army_candidates import extract, ROOT

SELECTED = {
    'd3c18f06': ('持长兵器步兵 A · 525 面', 'infantry_low'),
    '5b38b582': ('持长兵器步兵 B · 2625 面', 'infantry_high'),
    'cdf4bc12': ('马匹 · 高面数待简化', 'horse_high'),
    'a9a19ea3': ('象兵 · 姿态待校正', 'elephant'),
    '80c82506': ('三角军旗', 'flag_triangle'),
    '9eea5b67': ('燕尾军旗', 'flag_forked'),
    '682039a2': ('攻城器械 A', 'siege_frame'),
    'e5dc4fba': ('攻城器械 · 楼车', 'siege_tower'),
    'c0d5fa9c': ('攻城器械 · 箱式车辆', 'siege_vehicle'),
    'bd1ef9be': ('船只 · 桨船', 'ship_rowed'),
    '9962ab33': ('船只 · 双体船', 'ship_double'),
    '9a851cde': ('船只 · 帆船', 'ship_sail'),
}


def materials_and_ranges(raw, bindings):
    start = raw.find(b'GM1G')
    if start < 0: raise ValueError('G1MG section missing')
    materials, ranges = [], []
    offset = start + 48
    for _ in range(struct.unpack_from('<I', raw, start + 44)[0]):
        kind, length, count = struct.unpack_from('<III', raw, offset)
        position = offset + 12
        if kind == 0x10002:
            for _ in range(count):
                _, texture_count, _, _ = struct.unpack_from('<4I', raw, position)
                position += 16
                slots = [struct.unpack_from('<6H', raw, position + index * 12) for index in range(texture_count)]
                position += texture_count * 12
                color = next((entry[0] for entry in slots if entry[2] == 1), slots[0][0] if slots else None)
                normal = next((entry[0] for entry in slots if entry[2] == 3), None)
                materials.append({'texture': f'{bindings[color]:08x}', 'normal': f'{bindings[normal]:08x}' if normal in bindings else None})
        if kind == 0x10008:
            ranges = [list(struct.unpack_from('<14I', raw, position + index * 56)) for index in range(count)]
        offset += length
    return {'materials': materials, 'submeshes': ranges}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', required=True, type=Path, help='Existing rtk14-assets extraction folder')
    parser.add_argument('--game-root', required=True, type=Path)
    parser.add_argument('--cache', type=Path, default=ROOT / 'tools/army-source-cache')
    parser.add_argument('--output', type=Path, default=ROOT / 'assets/armies/rtk14')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / 'textures').mkdir(exist_ok=True)
    index = {row['id']: row for row in json.loads((args.source / 'all-index.json').read_text(encoding='utf8'))}
    objects = json.loads((args.cache / 'native-links.json').read_text(encoding='utf8'))
    by_id = {row['id']: row for row in objects}
    links, textures, manifest = {}, {}, {}
    for model, (label, role) in SELECTED.items():
        display = next(row for row in objects if row['props'].get('KTGLModelDataResourceHash') == [int(model, 16)])
        state = by_id[f"{display['props']['TexturesRenderStateObjectHash'][0]:08x}"]
        binding = f"{state['props']['TextureBindTableCSVFileResourceHash'][0]:08x}"
        table = extract(index[binding], args.game_root)
        slots = dict(struct.unpack_from('<II', table, offset) for offset in range(0, len(table), 8))
        links[model] = materials_and_ranges((args.cache / (model + '.g1m')).read_bytes(), slots)
        unresolved = []
        for material in links[model]['materials']:
            for texture in [material['texture'], material['normal']]:
                if texture is None or texture in textures: continue
                texture_node = by_id.get(texture, {})
                texture_resource = f"{texture_node['props']['KTGLTexContextResourceHash'][0]:08x}" if texture_node else texture
                texture_slot = int(texture_node.get('props', {}).get('TID', [0])[0])
                if texture_resource not in index:
                    if not role.startswith('flag_'):
                        raise ValueError(f'Native texture not found: {model}/{texture}')
                    unresolved.append(texture)
                    continue
                resource = args.cache / (texture_resource + '.g1t')
                if not resource.exists(): resource.write_bytes(extract(index[texture_resource], args.game_root))
                target = args.output / 'textures' / (texture + '.png')
                if not target.exists():
                    texture_folder = args.cache / 'decoded-textures' / texture_resource
                    texture_folder.mkdir(parents=True, exist_ok=True)
                    result = subprocess.run([str(args.source / 'noesis/Noesis64.exe'), '?cmode', str(resource), str(texture_folder / 'texture.png')],
                                            capture_output=True, timeout=45, creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
                    decoded = texture_folder / (str(texture_slot) + '.dds')
                    if result.returncode or not decoded.exists():
                        raise RuntimeError(f'Texture conversion failed: {texture}: {result.stdout[-200:]!r}')
                    with Image.open(decoded) as image:
                        image.save(target)
                with Image.open(target) as image:
                    image.verify()
                textures[texture] = {'source_package': index[texture_resource]['package'], 'resource': texture_resource, 'slot': texture_slot}
        manifest[model] = {'label': label, 'role': role, 'path': f'res://assets/armies/rtk14/models/{model}.glb',
                           'source_package': 'CharacterEditor', 'source_model': model,
                           'native_database': display['file'], 'texture_binding': binding,
                           'materials': links[model]['materials'], 'animation_status': 'unbound',
                           'unresolved_textures': unresolved,
                           'verification': 'original geometry preview and native material references'}
        print('MATERIAL_BOUND', model, role, [material['texture'] for material in links[model]['materials']], flush=True)
    (args.cache / 'model-texture-links.json').write_text(json.dumps(links, indent=2), encoding='utf8')
    (args.cache / 'converted-textures.json').write_text(json.dumps(textures, indent=2), encoding='utf8')
    (args.cache / 'obj').mkdir(exist_ok=True)
    for model in SELECTED:
        target = args.cache / 'obj' / (model + '.obj')
        target.write_bytes((args.cache / (model + '.obj')).read_bytes())
    subprocess.run([str(Path(__import__('sys').executable)), '-X', 'utf8', str(ROOT / 'tools/convert_rtk14_models.py'),
                    '--source', str(args.cache), '--output', str(args.output)], check=True)
    (args.output / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding='utf8')
    (args.output / 'texture_sources.json').write_text(json.dumps(textures, ensure_ascii=False, indent=2), encoding='utf8')
    print('ARMY_ASSETS_STAGED', len(manifest), 'models;', len(textures), 'native textures', flush=True)


if __name__ == '__main__': main()
