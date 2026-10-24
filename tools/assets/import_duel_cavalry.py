"""Import mounted-duel candidates with original RTK14 material references."""
from pathlib import Path
import json
import shutil
import sys
import import_rtk14_army_assets as importer

SOURCE = Path(r'C:\Users\10228\.codex\visualizations\2026\10\01\01a0f78f-1022-73e2-b695-c363e0e2e1ff\rtk14-assets')
CANDIDATES = Path(r'C:\Users\10228\.codex\visualizations\2026\10\04\01a104a0-d367-7881-a636-f066ae161007\unit-models')
CACHE = importer.ROOT / 'tools/duel-source-cache'
OUTPUT = importer.ROOT / 'assets/duel/rtk14'
SELECTED = {
    '407a9723': ('披风铠甲武将候选', 'officer_caped'),
    '8edce9d9': ('重甲武将候选', 'officer_armored'),
    '179118ca': ('长兵器候选', 'weapon_long'),
    '26f8ff97': ('长刀候选', 'weapon_long_blade'),
    'cdf4bc12': ('战马', 'horse'),
}

if __name__ == '__main__':
    CACHE.mkdir(parents=True, exist_ok=True)
    (CACHE / '.gdignore').write_text('')
    shutil.copyfile(importer.ROOT / 'tools/army-source-cache/native-links.json', CACHE / 'native-links.json')
    for model in SELECTED:
        for extension in ['g1m', 'obj']:
            shutil.copyfile(CANDIDATES / f'{model}.{extension}', CACHE / f'{model}.{extension}')
        # Noesis also exports invisible cloth driver collision meshes. Preserve
        # vertex indices but exclude their faces from the visible draw groups.
        lines, driver = [], False
        for line in (CACHE / f'{model}.obj').read_text().splitlines():
            if line.startswith('g '): driver = 'driver_' in line
            if driver and line.startswith(('g ', 'usemtl ', 'f ')): continue
            lines.append(line)
        (CACHE / f'{model}.obj').write_text('\n'.join(lines))
    importer.SELECTED = SELECTED
    sys.argv = ['import_duel_cavalry', '--source', str(SOURCE), '--game-root', r'\\S-dxp4800plus\资料\游戏\pc游戏\ROMANCE OF THE THREE KINGDOMS XIV\ROMANCE OF THE THREE KINGDOMS XIV (2)', '--cache', str(CACHE), '--output', str(OUTPUT)]
    importer.main()
    manifest = json.loads((OUTPUT / 'manifest.json').read_text(encoding='utf8'))
    for model, row in manifest.items():
        row['path'] = f'res://assets/duel/rtk14/models/{model}.glb'
        row['identity_status'] = 'appearance candidate; officer name not verified'
    (OUTPUT / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding='utf8')
