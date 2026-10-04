from pathlib import Path
from PIL import Image

root = Path(__file__).resolve().parents[1]
temp = Path('C:/Users/10228/AppData/Local/Temp')
out = root / 'assets/city/han/ui/user-atlas'
Image.open(temp / 'codex-clipboard-b4cefd4a-303b-47b0-8448-8051805fc9e2.png').save(out / 'detail-paper.png')
ui = Image.open(temp / 'codex-clipboard-7554eeb9-9474-4bc5-983c-bc754240aba7.png')
ui.crop((132, 68, 642, 115)).save(out / 'detail-heading.png')
circles = Image.open(temp / 'codex-clipboard-40c17594-abaa-4b58-b59a-92dd71ed35fe.png').convert('RGBA')
source = Image.open(out / 'building-source.png').convert('RGBA')
cells = {0:[(8,12),(130,12),(252,12)],1:[(740,12),(862,12),(984,12)],2:[(374,12),(496,12),(618,12)],3:[(1106,12),(1228,12),(1350,12)],4:[(1472,12),(1594,12),(1716,12)],5:[(252,140),(374,140),(496,140)],12:[(1838,12),(8,140),(130,140)],13:[(618,140),(740,140),(862,140)],14:[(984,140),(1106,140),(1228,140)]}
for index, positions in cells.items():
    for state, (x,y) in enumerate(positions):
        for names in (True, False):
            canvas = Image.new('RGBA',(112,112))
            box = (8,3,112,107) if state==0 else ((377,124,478,228) if state==2 else (376,7,477,109))
            circle = circles.crop(box).resize((84,84),Image.Resampling.LANCZOS)
            canvas.alpha_composite(circle,(14,0))
            art = source.crop((x,y,x+112,y+112))
            height = 68 if y<100 else 74
            symbol = art.crop((0,0,112,height)).resize((82,50),Image.Resampling.LANCZOS)
            canvas.alpha_composite(symbol,(15,14))
            if names:
                canvas.alpha_composite(art.crop((0,height,112,112)),(0,height))
            if state==1:
                ring = circles.crop((250,0,357,109)).resize((90,90),Image.Resampling.LANCZOS)
                canvas.alpha_composite(ring,(11,-3))
            canvas.save(out / f'building-circle-{index}-{state}-{int(names)}.png')
