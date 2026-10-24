"""Preserve native SMD weights in the textured duel GLBs. No game animation claims."""
from pathlib import Path
import json
import struct
import numpy as np

ROOT = Path(__file__).resolve().parents[2]
CACHE = ROOT / 'tools/duel-source-cache'
MODELS = ROOT / 'assets/duel/rtk14/models'

def rotation(axis, angle):
    c, s = np.cos(angle), np.sin(angle)
    if axis == 'x': return np.array([[1,0,0],[0,c,-s],[0,s,c]])
    if axis == 'y': return np.array([[c,0,s],[0,1,0],[-s,0,c]])
    return np.array([[c,-s,0],[s,c,0],[0,0,1]])

def read_rig(name):
    text = (CACHE / f'{name}.smd').read_text()
    bones = []
    for line in text.split('nodes\n')[1].split('end')[0].splitlines():
        if line.strip():
            parts = line.split()
            bones.append((int(parts[0]), parts[1].strip('"'), int(parts[2])))
    local, global_bind = {}, {}
    for line in text.split('skeleton\n')[1].split('end')[0].splitlines():
        parts = line.split()
        if not parts or parts[0] == 'time': continue
        bone, values = int(parts[0]), list(map(float, parts[1:]))
        matrix = np.eye(4)
        matrix[:3,3] = np.array(values[:3]) * 0.01
        matrix[:3,:3] = rotation('z',values[5]) @ rotation('y',values[4]) @ rotation('x',values[3])
        local[bone] = matrix
        parent = bones[bone][2]
        global_bind[bone] = global_bind[parent] @ matrix if parent >= 0 else matrix
    vertices = {}
    by_position = {}
    for line in text.split('triangles\n')[1].split('end')[0].splitlines():
        parts = line.split()
        if len(parts) < 10: continue
        p = tuple(round(float(v)*0.01, 5) for v in parts[1:4])
        uv = tuple(round(float(v), 5) for v in parts[7:9])
        count = int(parts[9])
        weights = [(int(parts[10+2*i]), float(parts[11+2*i])) for i in range(count)]
        weights = sorted(weights, key=lambda w: -w[1])[:4]
        vertices[p+uv] = weights
        by_position[p] = weights
    print(name, 'bones', len(bones), 'sample rest positions', {bones[i][1]: global_bind[i][:3,3].round(3).tolist() for i in range(min(23,len(bones)))})
    return bones, local, global_bind, vertices, by_position

def prepare(model, name):
    bones, local, bind, weights_map, by_position = read_rig(name)
    raw = (MODELS / f'{model}.glb').read_bytes()
    length = struct.unpack_from('<I',raw,12)[0]
    doc = json.loads(raw[20:20+length])
    data = bytearray(raw[28+length:])
    def accessor(index):
        acc = doc['accessors'][index]
        view = doc['bufferViews'][acc['bufferView']]
        width = {'VEC3':3,'VEC2':2}[acc['type']]
        return np.frombuffer(data, '<f4', count=acc['count']*width, offset=view.get('byteOffset',0)+acc.get('byteOffset',0)).reshape(-1,width).copy()
    attrs = doc['meshes'][0]['primitives'][0]['attributes']
    positions = accessor(attrs['POSITION'])
    uv = accessor(attrs['TEXCOORD_0'])
    joints = np.zeros((len(positions),4), '<u2')
    weights = np.zeros((len(positions),4), '<f4')
    missing = 0
    for i, (point, texcoord) in enumerate(zip(positions, uv)):
        p = tuple(round(float(v),5) for v in point)
        u = tuple(round(float(v),5) for v in texcoord)
        row = weights_map.get(p+u, by_position.get(p))
        if row is None:
            missing += 1
            # Export float rounding differs slightly; use closest native position.
            keys = list(by_position)
            idx = np.argmin(np.sum((np.asarray(keys)-point)**2,axis=1))
            row = by_position[keys[idx]]
        for j,(bone,weight) in enumerate(row): joints[i,j], weights[i,j] = bone,weight
        weights[i] /= max(float(weights[i].sum()), 1e-9)
    visible = set()
    for primitive in doc['meshes'][0]['primitives']:
        acc = doc['accessors'][primitive['indices']]
        view = doc['bufferViews'][acc['bufferView']]
        visible.update(np.frombuffer(data, '<u4', count=acc['count'], offset=view.get('byteOffset',0)).tolist())
    used = {int(joints[v,k]) for v in visible for k in range(4) if weights[v,k] > 0}
    for bone in list(used):
        parent = bones[bone][2]
        while parent >= 0:
            used.add(parent)
            parent = bones[parent][2]
    retained = [bone for bone in bones if bone[0] in used]
    remap = {bone[0]:i for i,bone in enumerate(retained)}
    joints = np.asarray([[remap.get(int(j),0) for j in row] for row in joints],'<u2')
    def add(array, kind, component, target=None):
        data.extend(b'\0'*(-len(data)%4))
        offset = len(data)
        data.extend(array.tobytes())
        view = {'buffer':0,'byteOffset':offset,'byteLength':array.nbytes}
        if target: view['target'] = target
        doc['bufferViews'].append(view)
        doc['accessors'].append({'bufferView':len(doc['bufferViews'])-1,'componentType':component,'count':len(array),'type':kind})
        return len(doc['accessors'])-1
    j = add(joints,'VEC4',5123,34962)
    w = add(weights,'VEC4',5126,34962)
    inverse = np.asarray([np.linalg.inv(bind[i]).T.flatten() for i,_,_ in retained],'<f4')
    ibm = add(inverse,'MAT4',5126)
    doc['nodes'] = [{'name':'MountedModel','mesh':0,'skin':0,'children':[1]}]
    for i,name,parent in retained:
        node = {'name':name,'matrix':local[i].T.flatten().tolist()}
        children = [remap[b]+1 for b,_,p in retained if p == i]
        if children: node['children'] = children
        doc['nodes'].append(node)
    doc['skins'] = [{'joints':list(range(1,len(retained)+1)),'inverseBindMatrices':ibm,'skeleton':1}]
    doc['scenes'] = [{'nodes':[0]}]
    for primitive in doc['meshes'][0]['primitives']:
        primitive['attributes'].update(JOINTS_0=j, WEIGHTS_0=w)
    doc['buffers'] = [{'byteLength':len(data)}]
    doc['asset']['generator'] = 'RTK14 native textured geometry and original SMD skin weights; project duel rig'
    encoded = json.dumps(doc,separators=(',',':')).encode()
    encoded += b' '*(-len(encoded)%4)
    data.extend(b'\0'*(-len(data)%4))
    out = struct.pack('<III',1179937895,2,28+len(encoded)+len(data))+struct.pack('<II',len(encoded),1313821514)+encoded+struct.pack('<II',len(data),5130562)+data
    (MODELS / f'{model}-rig.glb').write_bytes(out)
    print('DUEL_RIG_READY',model,len(positions),'weighted vertices; rounded matches',missing)

if __name__ == '__main__':
    for model,name in [('407a9723','caped'),('8edce9d9','armored'),('cdf4bc12','horse')]: prepare(model,name)
