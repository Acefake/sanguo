"""Rebuild painted masks and a faction banner. Original color textures stay untouched."""
from pathlib import Path
import json
import math
import numpy as np
from PIL import Image, ImageDraw, ImageFont, ImageFilter

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'assets' / 'rtk14'

def paths():
    # Local layout follows the supplied screenshot, in Godot world units.
    return [([(70, 64), (68, 73), (66, 85), (62, 102), (58, 128)], 5.5),
            ([(58, 59), (51, 55), (49, 44), (50, 41)], 4.4),
            ([(72, 47), (77, 39), (83, 31), (88, 25)], 4.5),
            ([(82, 57), (95, 52), (109, 46), (131, 47)], 4.0),
            ([(51, 55), (34, 52), (23, 48), (9, 46)], 3.0),
            ([(95, 52), (100, 65), (110, 79)], 2.0)]

def distance_to_path(x, z, points):
    result = np.full_like(x, 1e6)
    for (ax, az), (bx, bz) in zip(points, points[1:]):
        dx, dz = bx-ax, bz-az
        t = np.clip(((x-ax)*dx+(z-az)*dz)/(dx*dx+dz*dz), 0, 1)
        result = np.minimum(result, np.hypot(x-ax-dx*t, z-az-dz*t))
    return result

def build_reference():
    lo, extent, n = -70., 260., 1024
    z, x = np.mgrid[:n, :n].astype(float)
    x = lo+x/(n-1)*extent
    z = lo+z/(n-1)*extent
    road = np.zeros_like(x)
    for points, width in paths():
        d = distance_to_path(x, z, points)
        edge = 0.45*np.sin(x*1.7+np.sin(z*0.8)) + 0.25*np.cos(z*2.4)
        road = np.maximum(road, np.clip((width*.5+1.8-d+edge)/1.8, 0, 1))
    apron = np.maximum(np.abs(x-69.0)-13.5, np.abs(z-56.0)-10.5)
    road = np.maximum(road, np.clip(1-apron/2.5, 0, 1)*.87)
    for sx,sz in [(50,41),(10,46),(129,48)]:
        road = np.maximum(road, np.clip((5.5-np.hypot(x-sx,z-sz))/2.5,0,1)*.70)
    left_edge = 41 + 3*np.sin(z*.16) + 4*np.sin(z*.05)
    right_edge = 82 + 2*np.sin(z*.12)
    forest = np.maximum(1-np.maximum((x-left_edge)/9, (37-z)/8),
                        1-np.maximum((right_edge-x)/10, (85-z)/8))
    forest = np.clip(forest, 0, 1)
    noise = (np.sin(x*.39+np.sin(z*.27))*np.cos(z*.33)+1)/2
    bare = np.clip((noise-.54)*2.1, 0, .6) * (1-forest*.7)
    shore = 24+2.1*np.sin(x*.055)+1.2*np.sin(x*.16)
    bank = np.clip((4.2-np.abs(z-shore-8))/4.2, 0, 1)
    road = np.maximum(road, bank*.4)
    rgba = np.stack([road, forest*(1-road), bare, np.ones_like(x)], -1)
    Image.fromarray((rgba*255).astype('uint8')).save(OUT/'reference_splat.png')
    # Riverbank distance for white ripples where the water meets the land.
    distance = np.minimum(np.abs(z-shore+38), np.abs(z-shore-10))
    coast_x = 120 - np.clip(z-65, 0, 100)*.24+2*np.sin(z*.17)
    distance = np.minimum(distance, np.abs(x-coast_x))
    Image.fromarray(np.uint8(np.clip(distance/12, 0, 1)*255)).save(OUT/'reference_shore.png')
    (OUT/'reference_layout.json').write_text(json.dumps({'bounds': [-70,-70,260,260],
        'city': {'model': '85fe8b84', 'x':70, 'z':56},
        'roads': [{'points':p,'width':w} for p,w in paths()],
        'layout_source':'Manually composed from the user screenshot; not original world coordinates'}, indent=2), encoding='utf8')

def build_world():
    n = 2048
    road = Image.new('L', (n,n))
    draw = ImageDraw.Draw(road)
    cities = json.loads((OUT/'cities_map.json').read_text(encoding='utf8'))
    # Minimum spanning tree plus nearby links; this is a preview road layout.
    points = [(c['x'],c['z']) for c in cities]
    joined = {0}; edges = []
    while len(joined)<len(points):
        best = min((math.dist(points[a],points[b]),a,b) for a in joined
                   for b in range(len(points)) if b not in joined)
        joined.add(best[2]); edges.append(best[1:])
    for a,b in edges:
        ax,az=points[a]; bx,bz=points[b]
        mid=((ax+bx)/2+(bz-az)*.035,(az+bz)/2-(bx-ax)*.035)
        draw.line([points[a],mid,points[b]], fill=210, width=5)
    for x,z in points:
        draw.ellipse((x-17,z-14,x+17,z+14),fill=220)
    road = road.filter(ImageFilter.GaussianBlur(1.9))
    z,x=np.mgrid[:n,:n]
    forest=np.clip((np.sin(x*.012)*np.sin(z*.009)+np.sin((x+z)*.025)*.55+.12)*1.8,0,1)
    noise=(np.sin(x*.039+np.sin(z*.017))*np.cos(z*.033)+1)/2
    rgba=np.stack([np.asarray(road)/255,forest*(1-np.asarray(road)/255),
                   np.clip((noise-.58)*1.5,0,.6),np.ones_like(forest)],-1)
    Image.fromarray((rgba*255).astype('uint8')).save(OUT/'world_splat.png')
    (OUT/'preview_roads.json').write_text(json.dumps([{'from':cities[a]['id'],'to':cities[b]['id']} for a,b in edges],indent=2),encoding='utf8')

def build_banner():
    im=Image.new('RGBA',(384,256),(0,0,0,0)); d=ImageDraw.Draw(im)
    outline=[(8,12),(345,18),(325,39),(375,61),(335,83),(365,110),(330,136),(371,160),(333,189),(355,224),(8,242)]
    d.polygon(outline,fill=(50,44,36,255))
    d.line([(12,20),(331,25)],fill=(178,149,99,255),width=3)
    d.line([(12,232),(330,218)],fill=(178,149,99,255),width=3)
    font=ImageFont.truetype('C:/Windows/Fonts/msyhbd.ttc',122)
    d.text((68,32),'吕',font=font,fill=(235,229,211,255),stroke_width=1)
    for y in range(47,223,29):
        d.line([(277,y),(330,y)],fill=(191,168,119,255),width=2)
    im.save(OUT/'faction_banner.png')

if __name__=='__main__':
    build_reference(); build_world(); build_banner()
    print('SURFACE_MASKS_AND_BANNER_OK')
