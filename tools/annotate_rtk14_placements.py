"""Attach per-instance visibility semantics to the active source stage's props."""
from pathlib import Path
import argparse
import importlib.util
import json


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    assets = root / 'assets/rtk14'
    spec = importlib.util.spec_from_file_location('kids', args.source / 'scene_parser_import.py')
    kids = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(kids)
    scene_path = args.source / 'metadata/KIDSSystemResource_6dbf662e.kidsobjdb'
    template_path = args.source / 'metadata/KIDSSystemResource_03d03eb5.kidsobjdb'
    scene = {row['id']: row for row in kids.parse(scene_path)}
    templates = {row['id']: row for row in kids.parse(template_path)}
    placements = json.loads((assets / 'placements.json').read_text(encoding='utf8'))
    visibility = json.loads((assets / 'stage_visibility.json').read_text(encoding='utf8'))
    listed = set(visibility['visible_instances'])
    for row in placements:
        instance = scene[row['instance']]
        template = templates[row['template']]
        instance_props = instance['props']
        template_props = template['props']
        preview_set = instance_props.get('PreviewVisibilitySet',
                                         template_props.get('PreviewVisibilitySet', [-1]))[0]
        row['preview_visibility_set'] = int(preview_set)
        row['source_flag'] = int(template_props['Flag'][0])
        row['source_group_mask'] = int(template_props['GroupMask'][0])
        row['draw_by_default'] = int(preview_set) < 0
    assert len(placements) == 1120
    assert sum(row['draw_by_default'] for row in placements) == 1015
    assert sum(row['instance'] in listed for row in placements) == 105
    assert all(row['preview_visibility_set'] < 0 or row['instance'] in listed
               for row in placements)
    (assets / 'placements.json').write_text(json.dumps(placements, indent=2), encoding='utf8')
    visibility['placement_visibility_semantics'] = {
        'default_visible_without_visibility_set': 1015,
        'explicitly_listed_preview_visibility_set': 105,
        'source': 'WorldPQ PreviewVisibilitySet inherited from template; stage MotorStageVisibilitySet',
        'interpretation': 'Negative PreviewVisibilitySet inherits default draw; positive values require a stage visibility override.'}
    (assets / 'stage_visibility.json').write_text(json.dumps(visibility, indent=2), encoding='utf8')
    print('SOURCE_PLACEMENT_VISIBILITY_OK default=1015 listed=105 objects=1120')


if __name__ == '__main__':
    main()
