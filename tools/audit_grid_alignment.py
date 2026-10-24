"""Fit grid-to-height registration from independent terrain features, not screenshots.

This produces candidates only. It does not rewrite source placements.
"""
from pathlib import Path
import json
import numpy as np
from PIL import Image

OUT = Path(__file__).resolve().parents[1] / 'assets/rtk14'
h = np.fromfile(OUT / 'heightmap.r32', '<f4').reshape(2049, 2049) * .01
grid = np.fromfile(OUT / 'map_grid.bin', '<u4', offset=4).reshape(220, 220, 4)
types = grid[:, :, 1] & 255
# A river must occupy a valley relative to nearby ground, including highland rivers.
smooth = np.asarray(Image.fromarray(h).resize((65,65), Image.Resampling.BILINEAR).resize((2049,2049), Image.Resampling.BILINEAR))
relative = h - smooth
gz, gx = np.gradient(h)
slope = np.hypot(gx, gz)
sets = {name: np.argwhere(mask) for name, mask in {
    'river': types == 14,
    'city': types == 16,
    'mountain': np.isin(types, [10,11,19,22]),
    'coast_land': (np.indices(types.shape)[1] > 145) & (np.indices(types.shape)[0] > 40) & ~np.isin(types,[22,23]),
    'coast_sea': (np.indices(types.shape)[1] > 145) & (np.indices(types.shape)[0] > 40) & (types == 23),
}.items()}

def sample(field, r, c, v):
    sx, sz, ox, oz = v
    xx = ox + sx*c
    zz = oz + sz*(r + .5*(c%2))
    ix = np.clip(np.rint(xx).astype(int),0,2048)
    iz = np.clip(np.rint(zz).astype(int),0,2048)
    return field[iz, ix]

def components(v):
    values = {}
    for name, points in sets.items():
        r,c = points.T
        if name == 'river': values[name] = float(np.mean(np.clip(sample(relative,r,c,v),-5,5)))
        if name == 'city': values[name] = float(np.mean(np.minimum(sample(slope,r,c,v),2)))
        if name == 'mountain': values[name] = float(np.mean(np.minimum(sample(slope,r,c,v),2)))
        if name.startswith('coast'):
            prob = 1/(1+np.exp(-np.clip((sample(h,r,c,v)-.25)*8,-30,30)))
            values[name] = float(np.mean((prob-(name == 'coast_land'))**2))
    return values

def loss(v):
    s=components(v)
    return s['river'] + s['city']*2 - s['mountain']*.7 + 3*(s['coast_land']+s['coast_sea'])

if __name__ == '__main__':
    lo=np.array([6,7,100,50]);hi=np.array([8.3,9.1,550,300])
    rng=np.random.default_rng(1426)
    population=rng.uniform(lo,hi,(40,4));population[0]=[7.5,8,250,160]
    scores=np.array([loss(v) for v in population])
    for generation in range(170):
        for i in range(len(population)):
            a,b,c=rng.choice(len(population),3,replace=False)
            mutant=np.clip(population[a]+.65*(population[b]-population[c]),lo,hi)
            cross=rng.random(4)<.8;cross[rng.integers(4)]=True
            trial=np.where(cross,mutant,population[i]);score=loss(trial)
            if score<scores[i]: population[i]=trial;scores[i]=score
    best=population[scores.argmin()]
    report={'old':[7.5,8,250,160],'candidate':best.tolist(),'old_components':components([7.5,8,250,160]),'candidate_components':components(best),'status':'terrain-registration estimate, original runtime transform unconfirmed'}
    print(json.dumps(report,indent=2))
    (OUT/'grid_alignment_audit.json').write_text(json.dumps(report,indent=2),encoding='utf8')
