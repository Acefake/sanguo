"""Extract the SAN8R army-card and paper sprites; retain exact source rectangles."""
from pathlib import Path
from PIL import Image, ImageDraw, ImageChops
import hashlib,json
ROOT=Path(__file__).resolve().parents[1]
SOURCE=Path(r'\\S-dxp4800plus\资料\游戏\pc游戏\【PC】三国志8 REMAKEV1.0.8\SAN8R_解包资源\PNG\03_界面\按钮边框面板等混合图集')
OUT=ROOT/'assets/war/inspector';OUT.mkdir(parents=True,exist_ok=True)
regions={
 'army-card':('0x01e1e380_233e72fe_15b7dc0_000.png',(400,1100,866,1228)),
 'paper':('0x01e1e380_1be678dd_10_006.png',(0,0,128,128)),
 'ribbon':('0x0bf91892_1be678dd_10_005.png',(404,300,993,379)),
 'heading':('0x0bf91892_1be678dd_10_005.png',(0,247,399,315)),
 'radar-grid':('0x35c27e14_8e889a5f_8eb0_032.png',(3070,2499,3302,2723)),
 'meter-track':('0x771465d1_e295681c_8f40_032.png',(1863,563,1935,574)),
}
manifest=[]
for name,(filename,rect) in regions.items():
 path=SOURCE/filename;im=Image.open(path); assert rect[2]<=im.width and rect[3]<=im.height
 dest=OUT/(name+'.png');sprite=im.crop(rect).convert('RGBA')
 if name=='army-card':
  # The upper-right triangle belongs to the neighbouring atlas sprite.
  mask=Image.new('L',sprite.size,0)
  ImageDraw.Draw(mask).polygon([(0,0),(400,0),(466,64),(400,128),(0,128)],fill=255)
  sprite.putalpha(ImageChops.multiply(sprite.getchannel('A'),mask))
  sprite.putalpha(sprite.getchannel('A').point(lambda alpha:min(255,round(alpha*1.35))))
 if name=='paper': sprite.putalpha(255)
 sprite.save(dest)
 manifest.append({'asset':dest.relative_to(ROOT).as_posix(),'source':str(path),'rect':rect,'source_sha256':hashlib.sha256(path.read_bytes()).hexdigest(),'asset_sha256':hashlib.sha256(dest.read_bytes()).hexdigest(),'processing':'arrow silhouette mask and alpha x1.35' if name=='army-card' else 'opaque paper alpha' if name=='paper' else 'crop only'})
(OUT/'sources.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2),encoding='utf-8')
print('WAR_UI_ASSETS',len(manifest))
