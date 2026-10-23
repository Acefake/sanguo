"""Convert source draw ranges to GLB. Project-G1M already exports the UV orientation Godot expects: never flip V again. Its first OBJ group can contain a whole shared index buffer: trim to the G1MG draw range."""
from pathlib import Path
import json, struct, numpy as np, re, argparse
parser = argparse.ArgumentParser()
parser.add_argument('--source', type=Path, required=True, help='Source folder containing obj and binding JSON')
parser.add_argument('--models', nargs='+', help='Convert only these source model hashes')
parser.add_argument('--output', type=Path, default=Path(__file__).resolve().parents[2] / 'assets' / 'rtk14')
args = parser.parse_args()
p = args.source
out = args.output
(out / 'models').mkdir(parents=True, exist_ok=True)
links = json.loads((p / 'model-texture-links.json').read_text())
textures = json.loads((p / 'converted-textures.json').read_text())
for model, link in links.items():
    if args.models and model not in args.models:
        continue
    verts = []
    uv = []
    norms = []
    groups = {}
    group = 'mesh'
    for line in (p / 'obj' / f'{model}.obj').open():
        s = line.split()
        if not s:
            continue
        if s[0] == 'v':
            verts.append(list(map(float, s[1:4])))
        elif s[0] == 'vt':
            uv.append([float(s[1]), float(s[2])])
        elif s[0] == 'vn':
            norms.append(list(map(float, s[1:4])))
        elif s[0] == 'g':
            group = ' '.join(s[1:])
            groups.setdefault(group, [])
        elif s[0] == 'f':
            ids = []
            for val in s[1:]:
                parts = val.split('/')
                ids.append(int(parts[0]) - 1)
                assert len(parts) < 2 or not parts[1] or int(parts[1]) == int(parts[0]), 'UV indices differ'
            for j in range(1, len(ids) - 1):
                groups.setdefault(group, []).append([ids[0], ids[j], ids[j + 1]])
    v = np.asarray(verts, dtype='<f4') * 0.01
    n = np.asarray(norms, dtype='<f4')
    u = np.asarray(uv, dtype='<f4')
    data = bytearray()
    views = []
    acc = []

    def add(a, target, kind, typ):
        while len(data) % 4:
            data.append(0)
        off = len(data)
        data.extend(a.tobytes())
        views.append(dict(buffer=0, byteOffset=off, byteLength=a.nbytes, target=target))
        x = dict(bufferView=len(views) - 1, componentType=typ, count=len(a), type=kind)
        if kind == 'VEC3':
            x.update(min=a.min(0).tolist(), max=a.max(0).tolist())
        acc.append(x)
        return len(acc) - 1
    vp = add(v, 34962, 'VEC3', 5126)
    npid = add(n, 34962, 'VEC3', 5126) if len(n) == len(v) else None
    up = add(u, 34962, 'VEC2', 5126) if len(u) == len(v) else None
    mats = []
    images = []
    tex = []
    for m in link['materials']:
        tid = m['texture']
        pm = dict(baseColorFactor=[1, 1, 1, 1], metallicFactor=0, roughnessFactor=0.9)
        material = dict(name='Original_' + tid, pbrMetallicRoughness=pm, doubleSided=True)
        if tid in textures:
            images.append(dict(uri='../textures/' + tid + '.png'))
            tex.append(dict(source=len(images) - 1, sampler=0))
            pm['baseColorTexture'] = dict(index=len(tex) - 1)
            material = dict(name='Original_' + tid, pbrMetallicRoughness=pm, doubleSided=True, alphaMode='MASK', alphaCutoff=0.35)
        normal = m.get('normal')
        if normal in textures:
            images.append(dict(uri='../textures/' + normal + '.png'))
            tex.append(dict(source=len(images) - 1, sampler=0))
            material['normalTexture'] = dict(index=len(tex) - 1, scale=0.6)
        mats.append(material)
    primitives = []
    for name, faces in groups.items():
        if not faces:
            continue
        sub = int(re.search('submesh_(\\d+)', name)[1])
        record = link['submeshes'][sub]
        mat = record[6]
        expected = record[13]
        if len(faces) * 3 != expected:
            assert record[9] == 3 and expected % 3 == 0, (model, sub, record)
            start = record[12] // 3
            faces = faces[start:start + expected // 3]
        assert len(faces) * 3 == expected, (model, sub, len(faces) * 3, expected)
        idx = add(np.asarray(faces, dtype='<u4').reshape(-1), 34963, 'SCALAR', 5125)
        attrs = dict(POSITION=vp)
        if npid is not None:
            attrs['NORMAL'] = npid
        if up is not None:
            attrs['TEXCOORD_0'] = up
        primitives.append(dict(attributes=attrs, indices=idx, material=mat))
    g = dict(asset=dict(version='2.0', generator='Original RTK14 UV and texture bindings v4 source UV and draw ranges'), scene=0, scenes=[dict(nodes=[0])], nodes=[dict(mesh=0, name=model)], meshes=[dict(primitives=primitives)], materials=mats, images=images, textures=tex, samplers=[dict(wrapS=10497, wrapT=10497)], buffers=[dict(byteLength=len(data))], bufferViews=views, accessors=acc)
    jb = json.dumps(g, separators=(',', ':')).encode()
    jb += b' ' * (-len(jb) % 4)
    data += b'\x00' * (-len(data) % 4)
    total = 12 + 8 + len(jb) + 8 + len(data)
    (out / 'models' / f'{model}.glb').write_bytes(struct.pack('<III', 1179937895, 2, total) + struct.pack('<II', len(jb), 1313821514) + jb + struct.pack('<II', len(data), 5130562) + data)
    print('textured', model, len(primitives), flush=True)
