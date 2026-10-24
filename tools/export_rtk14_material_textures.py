"""Export missing source mountain material textures through the native bindings."""
from pathlib import Path
import argparse
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
    materials = json.loads((assets / 'native-recovery/model-materials.json').read_text(encoding='utf8'))
    registry = {r['id']: r for r in json.loads((args.source / 'all-index.json').read_text(encoding='utf8'))}
    sources = json.loads((assets / 'texture_sources.json').read_text(encoding='utf8'))
    selected = ['14d3de0c', '4b17a777', '5b5c506d', 'beaceb35', '84e24956', 'ce4b6bab']
    wanted = {t['texture_id']: t for model in selected
              for material in materials[model]['materials'] for t in material['textures']}
    for identifier, texture in wanted.items():
        target = assets / 'textures' / f'{identifier}.png'
        if not target.exists():
            record = registry[texture['g1t']]
            match = re.fullmatch(r'([a-fA-F0-9]+)@([a-fA-F0-9]+)(?:#([a-fA-F0-9]+))?(?:&([a-fA-F0-9]+))?', record['address'])
            filename = record['package'] + '.rdb.bin'
            if match[3]: filename += str(int(match[3], 16))
            if match[4]: filename += '_' + str(int(match[4], 16))
            with (args.game / '0002' / filename).open('rb') as archive:
                archive.seek(int(match[1], 16))
                block = archive.read(int(match[2], 16))
            payload = unpack_payload(record, block)
            folder = args.source / 'model-textures' / texture['g1t']
            folder.mkdir(parents=True, exist_ok=True)
            resource = folder / f"{texture['g1t']}.g1t"
            resource.write_bytes(payload)
            subprocess.run([str(args.source / 'noesis/Noesis64.exe'), '?cmode', str(resource),
                            str(folder / 'texture.png')], check=True, stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, creationflags=0x08000000)
            Image.open(folder / f"{texture['slot']}.dds").save(target)
        sources[identifier] = {'g1t': texture['g1t'], 'slot': texture['slot'],
                               'path': 'res://assets/rtk14/textures/' + target.name}
        print('MATERIAL_TEXTURE_OK', identifier, texture['g1t'], texture['usage'], flush=True)
    (assets / 'texture_sources.json').write_text(json.dumps(sources, indent=2), encoding='utf8')


if __name__ == '__main__':
    main()
