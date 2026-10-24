from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
from PIL import Image, ImageDraw
import struct, json, os

source=Path(r'\\S-dxp4800plus\资料\游戏\pc游戏\【PC】三国志8 REMAKEV1.0.8\SAN8R_解包资源\PNG')
out=Path(__file__).resolve().parents[2]/'assets/officers/png-catalog'
out.mkdir(exist_ok=True)
files=[Path(e.path) for e in os.scandir(source) if e.name.endswith('.png')]
print(f'Checking PNG headers: {len(files)}',flush=True)
def inspect(path):
    try:
        with path.open('rb') as f: data=f.read(24)
        w,h=struct.unpack('>II',data[16:24])
        return {'path':str(path),'w':w,'h':h}
    except Exception as e: return {'path':str(path),'error':str(e)}
with ThreadPoolExecutor(max_workers=20) as pool:
    records=[]
    for i,row in enumerate(pool.map(inspect,files)):
        records.append(row)
        if (i+1)%1000==0:print(f'Headers: {i+1}',flush=True)
(out/'dimensions.json').write_text(json.dumps(records,ensure_ascii=False),encoding='utf-8')
candidates=[r for r in records if 'w' in r and ((r['w']>=700 and r['h']>=300 and r['w']/r['h']>=1.2) or (r['w']>=350 and 30<=r['h']<=300))]
print(f'Preview candidates: {len(candidates)}',flush=True)
def preview(row):
    try:
        im=Image.open(row['path']).convert('RGBA');im.thumbnail((148,90));return im
    except:return None
for batch in range((len(candidates)+95)//96):
    rows=candidates[batch*96:(batch+1)*96]
    sheet=Image.new('RGB',(1280,((len(rows)+7)//8)*118),'#514b40');draw=ImageDraw.Draw(sheet)
    with ThreadPoolExecutor(max_workers=12) as pool:
        for i,im in enumerate(pool.map(preview,rows)):
            x=(i%8)*160;y=(i//8)*118
            if im is not None:sheet.paste(im,(x,y),im)
            draw.text((x,y+92),f'{batch*96+i}  {rows[i]["w"]}x{rows[i]["h"]}',fill='white')
    sheet.save(out/f'gallery-{batch:02}.jpg')
    print(f'Gallery {batch} ready',flush=True)
(out/'candidates.json').write_text(json.dumps(candidates,ensure_ascii=False),encoding='utf-8')
