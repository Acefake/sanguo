"""Extract transparent SAN8R UI sprites from the user's original atlas files."""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont
import json

root = Path(__file__).resolve().parents[1]
folder = root/'assets/officers'
sources = (folder/'asset-index.txt').read_text(encoding='utf-8').splitlines()
regions = {
    'radar-base': (115, (2836,2500,3068,2723)),
    'radar-grid': (115, (3070,2499,3302,2723)),
    'title-ornament': (115, (3935,1545,4087,1828)),
    'scroll-up': (115, (3936,2110,4008,2185)),
    'scroll-down': (115, (4020,1890,4090,1965)),
    'scroll-thumb': (115, (4026,0,4084,119)),
    'stat-track': (115, (3550,2507,3891,2565)),
    'title-paper': (10, (0,247,399,315)),
    'name-paper': (10, (404,300,993,379)),
    'row-highlight': (110, (528,278,883,317)),
    'trait-gold': (192, (775,198,925,237)),
    'trait-red': (192, (323,267,400,304)),
    'trait-common': (192, (773,243,854,278)),
    'trait-hover': (192, (432,221,524,263)),
    'meter-fill': (192, (432,172,475,221)),
    'meter-track': (193, (1863,563,1935,574)),
}
# Assets found during the complete PNG audit; retain their exact source regions.
manifest = json.loads((folder/'extracted-regions.json').read_text(encoding='utf-8')) if (folder/'extracted-regions.json').exists() else {}
extra_names = ['title-ribbon', 'window-wing', 'panel-paper', 'scene-background', 'tab-normal', 'tab-active', 'table-header', 'row-hover', 'table-header-hover']
for name in extra_names:
    record = manifest.get(name)
    if record:
        Image.open(record['source']).crop(record['rect']).save(folder/(name+'.png'))
images = {}
for name,(index,box) in regions.items():
    if index not in images: images[index] = Image.open(sources[index])
    images[index].crop(box).save(folder/(name+'.png'))
manifest.update({name:{'source':sources[i],'rect':list(box)} for name,(i,box) in regions.items()})
(folder/'extracted-regions.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2),encoding='utf-8')
regions.update({name:None for name in extra_names if name in manifest})
sheet=Image.new('RGB',(960,((len(regions)+3)//4)*140),'#35312b')
draw=ImageDraw.Draw(sheet)
font=ImageFont.truetype('C:/Windows/Fonts/msyh.ttc',15)
names={'radar-base':'雷达底板','radar-grid':'雷达网格','title-ornament':'标题卷云','scroll-up':'滚动上箭头','scroll-down':'滚动下箭头','scroll-thumb':'滚动滑块','stat-track':'细长进度槽','title-paper':'纸纹标题带','name-paper':'卷云姓名板','panel-paper':'面板纸纹','tab-normal':'普通分页','tab-active':'选中分页','row-highlight':'列表选中条'}
for i,name in enumerate(regions):
    im=Image.open(folder/(name+'.png'));im.thumbnail((220,103))
    x=(i%4)*240;y=(i//4)*140
    sheet.paste(im,(x+(220-im.width)//2,y),im)
    draw.text((x+8,y+111),names.get(name, {'title-ribbon':'原始卷云标题条','window-wing':'渐透明窗口侧翼','scene-background':'原始街市场景','panel-paper':'淡色云纹纸底'}.get(name,name)),font=font,fill='#e8dbba')
sheet.save(folder/'usable-elements.png')
print(f'Extracted {len(regions)} UI elements with original alpha')
