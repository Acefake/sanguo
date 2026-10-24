"""Shared map-cell registration for all derived world layers."""
from pathlib import Path
import json
import numpy as np

OUT = Path(__file__).resolve().parents[2] / 'assets/rtk14'

def parameters():
    return json.loads((OUT/'grid_transform.json').read_text(encoding='utf8'))['parameters']

def to_world(row, column):
    sx, sz, ox, oz = parameters()
    column = np.asarray(column)
    return ox + sx*column, oz + sz*(np.asarray(row)+.5*(column%2))

def to_cell(x, z):
    sx, sz, ox, oz = parameters()
    column = np.rint((x-ox)/sx).astype(int)
    row = np.rint((z-oz)/sz-.5*(column%2)).astype(int)
    return row, column

if __name__ == '__main__':
    cities = json.loads((OUT/'cities_map.json').read_text(encoding='utf8'))
    for city in cities:
        cells=np.asarray(city['cells'])
        x,z=to_world(cells//220,cells%220)
        city['x'],city['z']=float(x.mean()),float(z.mean())
        city['grid_conversion']='shared source-terrain registration; runtime formula unconfirmed'
    (OUT/'cities_map.json').write_text(json.dumps(cities,ensure_ascii=False,indent=2),encoding='utf8')
    print('CITY_REGISTRATION_OK',len(cities))
