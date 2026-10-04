from pathlib import Path
from PIL import Image
root=Path(__file__).resolve().parents[1]
out=root/'assets/city/han/ui/user-atlas'
im=Image.open('C:/Users/10228/AppData/Local/Temp/codex-clipboard-1870fd7d-77a0-47fb-aecd-ce41d7c30b11.png')
for name,box in {'command-red':(1472,540,1528,571),'command-hover':(1537,541,1595,573),'command-disabled':(1605,542,1660,574),'command-tip':(619,495,868,556),'command-summary':(134,466,382,525),'command-cursor':(679,313,754,388)}.items():
    im.crop(box).save(out/(name+'.png'))
