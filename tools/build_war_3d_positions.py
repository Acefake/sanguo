"""Match strategic nodes to 3D cities by name, and interpolate remaining nodes.

Unmatched locations are estimates, not recovered native game coordinates.
"""
from pathlib import Path
import json
import math

root = Path(__file__).resolve().parents[1]
cities = json.loads((root / 'assets/rtk14/cities_map.json').read_text(encoding='utf8'))
places = json.loads((root / 'data/world_map.json').read_text(encoding='utf8'))['places']
by_name = {city['name']: city for city in cities}
anchors = [(p, by_name[p['name']]) for p in places if p['name'] in by_name]
positions = {}
aliases = {}
for place in places:
    if place['name'] in by_name:
        city = by_name[place['name']]
        positions[place['id']] = {'x': city['x'], 'z': city['z'], 'source': 'matched_city_name'}
        aliases[city['id']] = place['id']
    else:
        near = sorted(anchors, key=lambda a: (a[0]['x'] - place['x']) ** 2 + (a[0]['y'] - place['y']) ** 2)[:3]
        weights = [1 / max(math.hypot(p['x'] - place['x'], p['y'] - place['y']), 1) ** 2 for p, _ in near]
        positions[place['id']] = {'x': sum(c['x'] * w for (_, c), w in zip(near, weights)) / sum(weights),
                                  'z': sum(c['z'] * w for (_, c), w in zip(near, weights)) / sum(weights),
                                  'source': 'estimated_from_three_nearest_strategic_anchors'}
output = root / 'data/war/world_3d_positions.json'
output.write_text(json.dumps({'positions': positions, 'city_aliases': aliases}, ensure_ascii=False, indent=2), encoding='utf8')
print(f'WAR_3D_POSITIONS {len(positions)} nodes; {len(anchors)} matched cities; {len(positions) - len(anchors)} estimates')
