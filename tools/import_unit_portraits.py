"""Import transparent torso badges from the individually verified officer map.

No officer names are inferred from image ordering or asset numbers.
"""
import json
from pathlib import Path
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]


def main():
    path = ROOT / 'data/officer_portraits.json'
    officers = json.loads(path.read_text(encoding='utf-8'))
    for name, row in officers.items():
        if not row.get('verification') or not row.get('head_crop'):
            raise ValueError(f'Unverified portrait identity or crop: {name}')
        with Image.open(row['source']) as source:
            source = source.convert('RGBA')
            crop = row.get('unit_crop')
            if crop is None:
                x0, y0, x1, y1 = row['head_crop']
                width, height = x1 - x0, y1 - y0
                crop = [max(0, round(x0 - width * .68)), max(0, round(y0 - height * .1)),
                        min(source.width, round(x1 + width * .68)), min(source.height, round(y1 + height * .95))]
            unit = source.crop(crop)
            unit.thumbnail((256, 280), Image.Resampling.LANCZOS)
            destination = ROOT / f"assets/officers/portraits/{row['image_number']:04d}-unit.png"
            unit.save(destination)
            row['unit_portrait'] = 'res://' + destination.relative_to(ROOT).as_posix()
            row['unit_crop'] = crop
    path.write_text(json.dumps(officers, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print('UNIT_PORTRAITS_IMPORTED', len(officers))


if __name__ == '__main__':
    main()
