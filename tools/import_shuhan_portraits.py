"""Import individually matched Shu portraits, preserving existing faction art."""
import json
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont
root = Path(__file__).resolve().parents[1]
source = Path(r'\\S-dxp4800plus\资料\游戏\pc游戏\【PC】三国志8 REMAKEV1.0.8\SAN8R_解包资源\武将立绘')
output = root/'assets/officers/portraits'
manifest_path = root/'data/officer_portraits.json'
manifest = json.loads(manifest_path.read_text(encoding='utf-8'))
matches = {
    '廖化': (121, '廖化', (400,110,650,390)),
    '关兴': (81, '関興', (220,90,440,340)),
    '张苞': (103, '張苞', (250,90,470,360)),
    '张遵': (631, '張遵', (220,180,440,430)),
    '诸葛亮': (45, '諸葛亮', (410,200,660,470)),
    '关凤': (571, '関銀屏', (160,80,380,310)),
    '周仓': (20, '周倉', (180,150,420,400)),
    '关羽': (2, '関羽', (340,100,600,400)),
    '黄忠': (23, '黄忠', (440,300,710,620)),
    '魏延': (15, '魏延', (440,100,700,380)),
}
gallery = Image.new('RGB',(1200,660),'#e7e0cc')
draw = ImageDraw.Draw(gallery)
font = ImageFont.truetype('C:/Windows/Fonts/simkai.ttf',23)
for index,(name,(number,page,head)) in enumerate(matches.items()):
    assert number > 0, name
    files = list((source/'本体半身立绘_补全').glob(f'anime_{number:04d}_00_*.png')) or list((source/'本体静态半身_补全').glob(f'face_{number:04d}_00_unique_*.png'))
    assert len(files)==1,(name,files)
    original = Image.open(files[0]).convert('RGBA')
    bounds = original.getchannel('A').getbbox()
    portrait = original.crop(bounds)
    portrait.save(output/f'{number:04d}.png')
    crop = list(head)
    original.crop(crop).save(output/f'{number:04d}-head.png')
    manifest[name] = {'image_number':number,'source':str(files[0]),'alpha_bounds':list(bounds),'head_crop':crop,'portrait':f'res://assets/officers/portraits/{number:04d}.png','thumbnail':f'res://assets/officers/portraits/{number:04d}-head.png','verification':f'https://wikiwiki.jp/sangokushi8r/{page}'}
    portrait.thumbnail((230,295))
    x=index%5*240;y=index//5*330
    gallery.paste(portrait,(x+(240-portrait.width)//2,y),portrait)
    draw.text((x+85,y+300),name,font=font,fill='#493922')
manifest_path.write_text(json.dumps(manifest,ensure_ascii=False,indent=2),encoding='utf-8')
gallery.save(root/'assets/officers/shuhan-portraits-verified.jpg')
print('Imported 10 matched Shu officer portraits')
