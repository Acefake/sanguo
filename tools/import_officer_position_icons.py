"""Extract the officer's primary-role badge from the supplied SAN8R atlases."""
import json
from pathlib import Path

from PIL import Image, ImageOps

ROOT = Path(__file__).resolve().parents[1]
FOLDER = ROOT / 'assets/officers'
SOURCES = (FOLDER / 'asset-index.txt').read_text(encoding='utf-8').splitlines()
GLYPHS = {
    'advisor': ('军师', (6, 1, 51, 45)),
    'commander': ('主帅', (2, 0, 51, 54)),
    'warrior': ('前锋', (5, 1, 58, 54)),
    'politics': ('政治', (0, 3, 55, 58)),
    'diplomat': ('外交', (3, 0, 56, 54)),
    'governor': ('太守', (0, 1, 54, 57)),
    'staff': ('参军', (4, 1, 53, 54)),
}


def main():
    records = {}
    for kind, (role, rect) in GLYPHS.items():
        source = FOLDER / 'position-references' / f'{kind}.png'
        # Preserve the supplied white silhouette and its antialiased edges.
        # Its black screenshot backing becomes transparency, including the
        # dark lines between the fan handle and feathers.
        alpha = ImageOps.grayscale(Image.open(source).crop(rect)).point(lambda p: 0 if p < 16 else p)
        alpha = alpha.crop(alpha.getbbox())
        glyph = Image.new('RGBA', alpha.size, 'white')
        glyph.putalpha(alpha)
        glyph.save(FOLDER / f'position-{kind}.png')
        records[kind] = {'role': role, 'source': str(source.relative_to(ROOT)), 'rect': list(rect)}
    background_rect = (929, 123, 1023, 217)
    Image.open(SOURCES[28]).crop(background_rect).save(FOLDER / 'position-background.png')
    records['background'] = {'source': SOURCES[28], 'rect': list(background_rect)}
    (FOLDER / 'position-icons-source.json').write_text(
        json.dumps(records, ensure_ascii=False, indent=2), encoding='utf-8')
    print('Extracted the 7 supplied white role glyphs and the octagonal badge background.')


if __name__ == '__main__':
    main()
