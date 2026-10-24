"""Reuse the exact SAN8R battle atlas supplied as the third reference image."""
from pathlib import Path
import hashlib
import json
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[2]
SOURCE = Path(r'\\S-dxp4800plus\资料\游戏\pc游戏\【PC】三国志8 REMAKEV1.0.8\SAN8R_解包资源\PNG\03_界面\按钮边框面板等混合图集\0x01e1e380_233e72fe_15b7dc0_014.png')
OUT = ROOT/'assets/war/badges'
REGIONS = {
    # Located against the three explicit user references, then visually checked.
    'cavalry': (1203,356,1230,384),
    'infantry': (2012,352,2040,376),
    'archers': (1804,360,1830,389),
    'speech-ally': (1026,554,1138,616),
    'speech-enemy': (1140,554,1254,616),
    'morale-track': (1258,581,1718,597),
    'morale-yellow': (1026,636,1122,644),
    'morale-red': (1123,636,1221,644),
}


def main():
    OUT.mkdir(parents=True,exist_ok=True)
    original = Image.open(SOURCE).convert('RGBA')
    manifest = {'source':str(SOURCE),'source_sha256':hashlib.sha256(SOURCE.read_bytes()).hexdigest(),
                'reference':'user supplied third atlas image, visually verified against original library','sprites':REGIONS}
    for name, rect in REGIONS.items(): original.crop(rect).save(OUT/(name+'.png'))
    factions = json.loads((ROOT/'data/scenario_world_demo.json').read_text(encoding='utf-8'))['factions']
    symbols = {'unknown':'敌'}
    for key, value in factions.items():
        name = value['name']
        symbols[key] = name[:2] if name[:2] in ('公孙','司马','诸葛') else name[0]
    for key, text in symbols.items():
        canvas = Image.new('RGBA',(256,256))
        draw = ImageDraw.Draw(canvas)
        font = ImageFont.truetype('C:/Windows/Fonts/simkai.ttf',140 if len(text)==1 else 78)
        # The flag shader maps local cloth coordinates consistently on both faces.
        for index, char in enumerate(text):
            y = 128 if len(text)==1 else 86+index*84
            draw.text((128,y),char,font=font,fill=(255,255,255,255),anchor='mm')
        canvas.save(OUT/f'flag-{key}.png')
    manifest['flag_symbols'] = symbols
    manifest['flag_processing'] = 'locally rendered Kai glyph masks; shader projects local cloth coordinates consistently onto both native mesh faces'
    (OUT/'sources.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    preview=Image.new('RGB',(640,160),'#262a2b'); draw=ImageDraw.Draw(preview)
    font=ImageFont.truetype('C:/Windows/Fonts/simkai.ttf',19)
    for index,name in enumerate(('infantry','archers','cavalry','speech-ally','speech-enemy')):
        image=Image.open(OUT/(name+'.png'));image.thumbnail((108,88))
        if index<3:image=image.resize((72,72))
        preview.paste(image,(index*128+16,15),image);draw.text((index*128+8,120),name,font=font,fill='white')
    preview.save(ROOT/'docs/validation/army-badge-sprites.png')
    print('ARMY_BADGE_SPRITES',len(REGIONS),'native sprites;',len(symbols),'flag glyphs')


if __name__=='__main__':main()
