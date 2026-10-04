"""Import the eight visually verified portraits, keeping the original alpha."""
import json
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

root = Path(__file__).resolve().parents[1]
source = Path(r'\\S-dxp4800plus\资料\游戏\pc游戏\【PC】三国志8 REMAKEV1.0.8\SAN8R_解包资源\武将立绘')
output = root/'assets/officers/portraits'
output.mkdir(exist_ok=True)
# IDs describe image resources, not officer IDs. Matches were checked against
# named in-game portraits; Yuan Shao and Sun Ce also match the official site.
matches = {
    '袁绍': (5, '袁紹', (340, 200, 600, 480)),
    '袁尚': (34, '袁尚', (220, 45, 440, 275)),
    '孙策': (63, '孫策', (400, 170, 660, 450)),
    '田丰': (107, '田豊', (385, 115, 605, 375)),
    '颜良': (10, '顔良', (220, 190, 460, 450)),
    '文丑': (11, '文醜', (140, 150, 380, 410)),
    '袁谭': (35, '袁譚', (150, 90, 400, 350)),
    '袁熙': (33, '袁煕', (205, 70, 445, 330)),
}
manifest_path = root/'data/officer_portraits.json'
manifest = json.loads(manifest_path.read_text(encoding='utf-8')) if manifest_path.exists() else {}
gallery = Image.new('RGB', (960, 600), '#e7e0cc')
draw = ImageDraw.Draw(gallery)
font = ImageFont.truetype('C:/Windows/Fonts/simkai.ttf', 24)
for index, (name, (number, page, head)) in enumerate(matches.items()):
    files = list((source/'本体半身立绘_补全').glob(f'anime_{number:04d}_00_*.png'))
    if not files:
        files = list((source/'本体静态半身_补全').glob(f'face_{number:04d}_00_unique_*.png'))
    assert len(files) == 1, (name, files)
    image = Image.open(files[0]).convert('RGBA')
    bounds = image.getchannel('A').getbbox()
    portrait = image.crop(bounds)
    portrait.save(output/f'{number:04d}.png')
    image.crop(head).save(output/f'{number:04d}-head.png')
    manifest[name] = {'image_number': number, 'source': str(files[0]), 'alpha_bounds': list(bounds), 'head_crop': list(head), 'portrait': f'res://assets/officers/portraits/{number:04d}.png', 'thumbnail': f'res://assets/officers/portraits/{number:04d}-head.png', 'verification': f'https://wikiwiki.jp/sangokushi8r/{page}'}
    portrait.thumbnail((220, 258))
    x = (index % 4)*240; y = (index // 4)*300
    gallery.paste(portrait, (x+(240-portrait.width)//2, y), portrait)
    draw.text((x+85,y+265),name,font=font,fill='#493922')
(root/'data/officer_portraits.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2),encoding='utf-8')
gallery.save(root/'assets/officers/portraits-verified.jpg')
print('Imported 8 individually verified officer portraits')
