"""Bake lightweight procedural poses from the original 23-bone RTK14 infantry.

The SMD is exported from d3c18f06.g1m by ProjectG1M/Noesis. These are our
procedural poses, not recovered native G1A animations. UVs and weights survive.
"""
from pathlib import Path
import argparse
import json
import math
import struct
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--smd', type=Path, default=ROOT / 'tools/army-source-cache/soldier-rig.smd')
args = parser.parse_args()
text = args.smd.read_text()
parents = {int(row.split()[0]): int(row.split()[-1]) for row in text.split('nodes\n')[1].split('end')[0].splitlines() if row.strip()}

def rotate(axis, angle):
    c, s = math.cos(angle), math.sin(angle)
    if axis == 'z': return np.array([[c,-s,0],[s,c,0],[0,0,1]])
    if axis == 'y': return np.array([[c,0,s],[0,1,0],[-s,0,c]])
    return np.array([[1,0,0],[0,c,-s],[0,s,c]])

locals, bind = {}, {}
for row in text.split('skeleton\n')[1].split('end')[0].splitlines():
    fields = row.split()
    if not fields or fields[0] == 'time': continue
    bone = int(fields[0]); values = list(map(float, fields[1:]))
    matrix = np.eye(4)
    matrix[:3,3] = values[:3]
    matrix[:3,:3] = rotate('z',values[5]) @ rotate('y',values[4]) @ rotate('x',values[3])
    locals[bone] = matrix
    bind[bone] = bind[parents[bone]] @ matrix if parents[bone] >= 0 else matrix

vertices, normals, uv, weights = [], [], [], []
for row in text.split('triangles\n')[1].split('end')[0].splitlines():
    fields = row.split()
    if not fields or not fields[0].lstrip('-').isdigit(): continue
    vertices.append(list(map(float, fields[1:4])))
    normals.append(list(map(float, fields[4:7])))
    uv.append(list(map(float, fields[7:9])))
    links = [(int(fields[10 + i*2]), float(fields[11 + i*2])) for i in range(int(fields[9]))]
    weights.append([(i, w) for i, w in links if w > 0])
assert len(vertices) == 525 * 3, 'Native infantry draw range changed'
vertices = np.asarray(vertices); normals = np.asarray(normals)
inverse = {i: np.linalg.inv(matrix) for i, matrix in bind.items()}
binary, views, accessors = bytearray(), [], []

def add(values, kind):
    values = np.asarray(values, dtype='<f4')
    binary.extend(b'\0' * (-len(binary) % 4))
    offset = len(binary); binary.extend(values.tobytes())
    views.append({'buffer':0, 'byteOffset':offset, 'byteLength':values.nbytes, 'target':34962})
    accessor = {'bufferView':len(views)-1, 'componentType':5126, 'count':len(values), 'type':kind}
    if kind == 'VEC3': accessor.update(min=values.min(axis=0).tolist(), max=values.max(axis=0).tolist())
    accessors.append(accessor)
    return len(accessors)-1

uv_id = add(uv, 'VEC2')
meshes = []
for frame in range(21):
    fighting = frame >= 9
    phase = ((frame - 9) / 12 if fighting else (frame - 1) / 8) * math.tau
    swing = 0 if frame == 0 else math.sin(phase) * (0.12 if fighting else 0.3)
    pose, transforms = {}, {}
    # World rotations preserve the recovered local skeleton orientation.
    adjustments = {15:('z',-1.05),16:('z',1.05),17:('z',0.45),18:('z',-1.6),
                   3:('x',swing),4:('x',-swing),5:('x',max(0,-swing)*0.5),6:('x',max(0,swing)*0.5)}
    if fighting:
        # Grounded spear thrust: recover, prepare, extend, then recover.
        t = (frame - 9) / 12
        thrust = -0.12 * t / 0.2 if t < 0.2 else -0.12 + 0.77 * (t - 0.2) / 0.25 if t < 0.45 else 0.65 * (1 - (t - 0.45) / 0.55)
        adjustments.update({9:('x',-thrust*0.40),16:('z',1.05-thrust*0.30),18:('z',-1.6+thrust*0.45)})
    for bone in locals:
        matrix = pose[parents[bone]] @ locals[bone] if parents[bone] >= 0 else locals[bone].copy()
        if bone in adjustments:
            axis, angle = adjustments[bone]
            matrix[:3,:3] = rotate(axis,angle) @ matrix[:3,:3]
        if bone == 22:
            # The spear is bound sideways in the source T-pose. Align the wrist
            # weapon with the body's -Z forward, rather than interpreting -X as forward.
            matrix[:3,:3] = rotate('y', -math.pi / 2) @ bind[bone][:3,:3]
            if fighting: matrix[:3,3] += np.array([0, 0, -thrust * 100])
        pose[bone] = matrix
        transforms[bone] = matrix @ inverse[bone]
    moved, moved_normals = [], []
    for vertex, normal, links in zip(vertices,normals,weights):
        matrix = sum((transforms[bone] * weight for bone, weight in links), np.zeros((4,4)))
        # Normalize the baked asset to +Z forward once; all map headings use +Z.
        facing = rotate('y', math.pi)
        moved.append(facing @ (matrix @ np.append(vertex,1))[:3] * 0.01)
        direction = facing @ matrix[:3,:3] @ normal
        moved_normals.append(direction / max(np.linalg.norm(direction),1e-8))
    assert np.isfinite(moved).all(), 'Invalid posed vertex'
    assert np.asarray(moved)[:,2].max() > 1.4, 'Spear must point along normalized +Z forward'
    pos_id = add(moved,'VEC3'); normal_id = add(moved_normals,'VEC3')
    name = 'idle' if frame == 0 else (f'combat_{frame-9}' if fighting else f'march_{frame-1}')
    meshes.append({'name':name, 'primitives':[{'attributes':{'POSITION':pos_id,'NORMAL':normal_id,'TEXCOORD_0':uv_id},'material':0}]})
gltf = {'asset':{'version':'2.0','generator':'RTK14 native weights; procedural infantry poses'},
        'scene':0,'scenes':[{'nodes':[0]}], 'nodes':[{'mesh':0,'name':'infantry_idle'}],
        'meshes':meshes,'materials':[{'name':'native_infantry','doubleSided':True,
        'pbrMetallicRoughness':{'baseColorTexture':{'index':0},'metallicFactor':0,'roughnessFactor':0.9}}],
        'images':[{'uri':'../textures/24b4dfb4.png'}],'textures':[{'source':0}],
        'bufferViews':views,'accessors':accessors,'buffers':[{'byteLength':len(binary)}],
        'extras':{'source_model':'d3c18f06','native_bones':len(bind),'animation':'procedural_baked_8_frame_march_12_frame_spear_thrust', 'forward_axis':'+Z'}}
# Add nodes so Godot can generate every mesh, without displaying them all together.
gltf['nodes'] += [{'mesh':i,'name':meshes[i]['name']} for i in range(1,21)]
gltf['scenes'][0]['nodes'] = list(range(21))
raw = json.dumps(gltf,separators=(',',':')).encode(); raw += b' ' * (-len(raw)%4)
binary.extend(b'\0' * (-len(binary)%4))
out = ROOT / 'assets/armies/rtk14/models/infantry-poses.glb'
out.write_bytes(struct.pack('<III',1179937895,2,12+8+len(raw)+8+len(binary)) + struct.pack('<II',len(raw),1313821514) + raw + struct.pack('<II',len(binary),5130562) + binary)
print(f'INFANTRY_POSES {len(bind)} native bones; idle + 8 march + 12 combat frames; {len(vertices)//3} triangles per frame')
