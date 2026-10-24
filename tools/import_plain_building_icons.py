from pathlib import Path
from PIL import Image, ImageOps
root = Path(__file__).resolve().parents[1]
out = root / 'assets/city/han/ui/user-atlas'
temp = Path('C:/Users/10228/AppData/Local/Temp')
icons = Image.open(temp / 'codex-clipboard-f637771f-2309-478a-9e3c-a6fa843ffa32.png').convert('RGBA')
circles = Image.open(temp / 'codex-clipboard-40c17594-abaa-4b58-b59a-92dd71ed35fe.png').convert('RGBA')
regions = {0:(1004,259,1070,329),1:(1951,439,2026,516),2:(1004,330,1070,404),3:(549,445,620,519),4:(1705,451,1771,526),5:(0,462,65,536),12:(1772,456,1835,523),13:(64,463,130,537),14:(64,463,130,537)}
for index, box in regions.items():
    art = icons.crop(box)
    art = art.crop(art.getbbox())
    art = ImageOps.contain(art, (52,52),Image.Resampling.LANCZOS)
    for state in range(3):
        circle_box = [(8,3,112,107),(377,7,477,109),(377,124,478,228)][state]
        circle = circles.crop(circle_box)
        circle = circle.crop(circle.getbbox()).resize((104,104),Image.Resampling.LANCZOS)
        canvas = Image.new('RGBA',(112,112))
        canvas.alpha_composite(circle,(4,4))
        # The new sheet is already transparent; retain its native symbol silhouette.
        canvas.alpha_composite(art,((112-art.width)//2,(112-art.height)//2))
        for names in (0,1):
            canvas.save(out / f'building-circle-{index}-{state}-{names}.png')
