"""Recover the active field stage's source visibility list without name guessing."""
from pathlib import Path
import argparse
import hashlib
import importlib.util
import json
import struct


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', type=Path, required=True)
    args = parser.parse_args()
    assets = Path(__file__).resolve().parents[2] / 'assets/rtk14'
    spec = importlib.util.spec_from_file_location('kids', args.source / 'scene_parser_import.py')
    kids = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(kids)
    path = args.source / 'metadata/KIDSSystemResource_b041e18a.kidsobjdb'
    data = path.read_bytes()
    objects = {r['id']: r for r in kids.parse(path)}
    stage = objects['6eff205a']
    visibility = objects[f"{stage['props']['VisibilitySetObjectNameHash'][0]:08x}"]

    def values(record, key):
        prop = record['props'][key]
        if not isinstance(prop, dict):
            return list(prop)
        return list(struct.unpack_from('<' + kids.formats[prop['type']][0] * prop['count'],
                                       data, prop['offset']))

    databases = [f'{v:08x}' for v in values(stage, 'ObjectDatabaseNameHashArray')]
    # Identify the same stage from its recovered landscape, vegetation and static scene.
    assert all(h in databases for h in ['f029fe04', 'b43fcef2', '6dbf662e'])
    assert stage['props']['LandscapeObjectNameHash'][0] == 0xbef4550e
    ids = [f'{v:08x}' for v in values(visibility, 'ObjectNameHashArray')]
    placements = json.loads((assets / 'placements.json').read_text(encoding='utf8'))
    source = {r['instance']: r for r in placements}
    assert len(source) == 1120 and len(ids) == len(set(ids)) == 105
    assert set(ids) <= source.keys()
    result = {'stage_file': path.name, 'stage_object': stage['id'],
              'visibility_object': visibility['id'], 'source_sha256': hashlib.sha256(data).hexdigest(),
              'object_databases': databases, 'group_counts': values(visibility, 'ElementNumArray'),
              'visible_instances': ids, 'source_placement_count': len(source),
              'visible_names': sorted(set(source[h]['name'] for h in ids)),
              'unlisted_count': len(source) - len(ids),
              'status': 'Source stage visibility list; additional game-code visibility overrides are unconfirmed.'}
    (assets / 'stage_visibility.json').write_text(json.dumps(result, indent=2), encoding='utf8')
    print('SOURCE_STAGE_VISIBILITY_OK', len(ids), 'listed instances,', result['unlisted_count'], 'unlisted')


if __name__ == '__main__':
    main()
