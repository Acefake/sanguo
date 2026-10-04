"""Group native type-17 gate cells; retain provenance and coordinate uncertainty."""
from pathlib import Path
import json, math
import numpy as np
from rtk14_grid import to_world, parameters

out=Path(__file__).resolve().parents[1]/'assets/rtk14'
grid=np.fromfile(out/'map_grid.bin',dtype='<i4',offset=4).reshape(220,220,4)
groups={}
for row,col in np.argwhere((grid[:,:,1]&255)==17):
    region=int(grid[row,col,1]>>16)
    groups.setdefault(region,[]).append((int(row),int(col)))
gates=[]
for region,cells in sorted(groups.items()):
    points=np.array([to_world(r,c) for r,c in cells],dtype=float)
    center=points.mean(axis=0)
    _,_,axis=np.linalg.svd(points-center)
    # Fit the wall to its source-cell footprint, rather than widening the pass
    # by flattening mountains. This is a documented reconstruction estimate.
    sx,sz,_,_=parameters()
    direction=axis[0]
    radius=2*sx/3
    hex_support=max(radius*abs(direction[0]),
                    radius*.5*abs(direction[0])+sz*.5*abs(direction[1]))
    footprint_width=float(np.ptp((points-center)@direction)+2*hex_support)
    model_width=36.04385
    gates.append(dict(id=f'gate_{region}',region=region,model='90ca3c38',
        x=float(center[0]),z=float(center[1]),rotation=math.atan2(-axis[0,1],axis[0,0]),
        footprint_width=footprint_width,model_scale=footprint_width/model_width,
        scale_status='Estimated from native hex footprint; original runtime scale unresolved',
        cells=[r*220+c for r,c in cells],source='Map.bin type 17',
        coordinate_status='Shared source-terrain registration; original runtime transform unresolved',
        orientation_status='Principal axis of native footprint; original runtime orientation unresolved'))
(out/'source_gates.json').write_text(json.dumps(gates,indent=2),encoding='utf8')
print('SOURCE_GATE_CELLS_OK',len(gates),'gates',sum(len(g['cells']) for g in gates),'native cells')
