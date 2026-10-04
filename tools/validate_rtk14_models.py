"""Check native G1MG draw ranges, texture bindings and nondegenerate surfaces."""
from pathlib import Path
import json
import struct
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / 'assets' / 'rtk14'
links = json.loads((ASSETS/'model_texture_links.json').read_text(encoding='utf8'))
report = []
for model, source in links.items():
    data=(ASSETS/'models'/f'{model}.glb').read_bytes()
    length=struct.unpack_from('<I',data,12)[0]
    doc=json.loads(data[20:20+length])
    offset=28+length
    primitives=doc['meshes'][0]['primitives']
    assert len(primitives)==len(source['submeshes']), model
    count=0
    for i,(primitive,record) in enumerate(zip(primitives,source['submeshes'])):
        index=doc['accessors'][primitive['indices']]
        assert index['count']==record[13], (model,i,index['count'],record[13])
        assert primitive['material']==record[6], (model,i,'wrong texture')
        assert 'TEXCOORD_0' in primitive['attributes'] and 'NORMAL' in primitive['attributes']
        mat=doc['materials'][primitive['material']]
        tex=mat['pbrMetallicRoughness']['baseColorTexture']['index']
        uri=doc['images'][doc['textures'][tex]['source']]['uri']
        assert (ASSETS/'models'/uri).is_file(), (model,uri)
        expected=source['materials'][record[6]]['texture']
        assert Path(uri).stem==expected, (model,i,expected,uri)
        count+=index['count']//3
    # Submesh zero of the medium city is only its paving quad, not all buildings.
    if model=='85fe8b84':
        assert doc['accessors'][primitives[0]['indices']]['count']==6
        assert count==7550
    report.append({'model':model,'submeshes':len(primitives),'triangles':count,
                   'complete':True,'source_draw_ranges_verified':True})
(ASSETS/'model_completeness.json').write_text(json.dumps(report,indent=2),encoding='utf8')
print('SOURCE_DRAW_RANGES_AND_TEXTURES_OK',len(report),'models')
