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

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument('--smd', type=Path, default=ROOT / 'tools/army-source-cache/soldier-rig.smd')
parser.add_argument('--kind', choices=['infantry', 'archer'], default='infantry')
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
if args.kind == 'archer':
    # Remove the native spear draw triangles, retaining the soldier and weights.
    keep = [i for base in range(0, len(vertices), 3)
            if not any(any(b == 22 and w > .5 for b, w in weights[j]) for j in range(base, base+3))
            for i in range(base, base+3)]
    vertices, normals, uv, weights = ([seq[i] for i in keep] for seq in [vertices, normals, uv, weights])
vertices = np.asarray(vertices); normals = np.asarray(normals)
inverse = {i: np.linalg.inv(matrix) for i, matrix in bind.items()}

def aim_rotation(source, target):
    """Rotate a recovered world-space bone axis onto a posed limb direction."""
    a = source / np.linalg.norm(source)
    b = target / np.linalg.norm(target)
    cross = np.cross(a, b)
    cosine = float(np.clip(a @ b, -1, 1))
    if cosine < -0.999999:
        axis = np.cross(a, np.array([0., 1., 0.]))
        axis /= np.linalg.norm(axis)
        return 2 * np.outer(axis, axis) - np.eye(3)
    skew = np.array([[0, -cross[2], cross[1]], [cross[2], 0, -cross[0]], [-cross[1], cross[0], 0]])
    return np.eye(3) + skew + skew @ skew / (1 + cosine)

def grip_arm(pose, upper, elbow, wrist, target, side):
    shoulder = (pose[parents[upper]] @ locals[upper])[:3, 3]
    lengths = [np.linalg.norm(bind[b][:3, 3] - bind[a][:3, 3])
               for a, b in [(upper, elbow), (elbow, wrist)]]
    direction = target - shoulder
    distance = np.linalg.norm(direction)
    assert abs(lengths[0] - lengths[1]) < distance < sum(lengths), 'Grip beyond arm reach'
    direction /= distance
    pole = np.array([side, -1., -0.25])
    pole -= direction * (pole @ direction)
    pole /= np.linalg.norm(pole)
    along = (lengths[0]**2 - lengths[1]**2 + distance**2) / (2 * distance)
    joint = shoulder + direction * along + pole * math.sqrt(max(0, lengths[0]**2 - along**2))
    for bone, end, origin in [(upper, elbow, shoulder), (elbow, wrist, joint)]:
        destination = joint if bone == upper else target
        matrix = bind[bone].copy()
        matrix[:3, :3] = aim_rotation(bind[end][:3, 3] - bind[bone][:3, 3], destination - origin) @ bind[bone][:3, :3]
        matrix[:3, 3] = origin
        pose[bone] = matrix
    matrix = bind[wrist].copy()
    matrix[:3, :3] = rotate('y', -side * math.pi / 2) @ bind[wrist][:3, :3]
    matrix[:3, 3] = target
    pose[wrist] = matrix

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
color_id = None
if args.kind == 'archer':
    colors = []
    for vertex, links in zip(vertices, weights):
        bone = max(links,key=lambda row: row[1])[0]
        color = [1.,1.,1.,1.]
        if bone in (3,4,15,16,17,18): color = [.12,.32,.52,1.]
        elif bone in (1,2,9,10): color = [.38,.27,.15,1.]
        elif bone in (5,6,7,8): color = [.31,.22,.13,1.]
        elif bone == 12 and vertex[1] > 163: color = [.12,.32,.52,1.]
        # glTF COLOR_0 is linear. Storing display-space blue/brown directly made
        # the uniforms pastel and the leather cream after the game lighting.
        colors.append([c/12.92 if c <= .04045 else ((c+.055)/1.055)**2.4 for c in color[:3]]+[1.])
meshes = []
for frame in range(29):
    breathing = frame >= 21
    fighting = 9 <= frame < 21
    bob = lean = sway = 0.0
    if breathing:
        # Idle loop: torso rise/fall, weight shift and a slow weapon sway so a
        # standing formation still has limb motion instead of one frozen pose.
        phase = (frame - 21) / 8 * math.tau
        sway = math.sin(phase) * 0.18
        lean = math.sin(phase) * 0.05
        bob = math.sin(phase * 2.0)
    else:
        phase = ((frame - 9) / 12 if fighting else (frame - 1) / 8) * math.tau
    swing = 0.0 if (frame == 0 or breathing) else math.sin(phase) * (0.12 if fighting else 0.3)
    pose, transforms = {}, {}
    adjustments = {3:('x',swing),4:('x',-swing),5:('x',max(0,-swing)*0.5),6:('x',max(0,swing)*0.5)}
    reach = math.sin(phase) * 2.5 if frame != 0 else 0.0
    grip_height = 120.0 + (bob * 0.5 if breathing else 0.0)
    if breathing:
        adjustments.update({1:('z',lean),9:('y',math.sin((frame - 21) / 8 * math.tau)*0.09),
                            3:('x',sway),4:('x',-sway),5:('x',sway*0.5),6:('x',-sway*0.5)})
    if fighting:
        # Grounded spear thrust: recover, prepare, extend, then recover.
        t = (frame - 9) / 12
        thrust = -0.12 * t / 0.2 if t < 0.2 else -0.12 + 0.77 * (t - 0.2) / 0.25 if t < 0.45 else 0.65 * (1 - (t - 0.45) / 0.55)
        adjustments.update({9:('x',thrust*0.40)})
        reach = thrust * 28.0
    for bone in locals:
        matrix = pose[parents[bone]] @ locals[bone] if parents[bone] >= 0 else locals[bone].copy()
        if bone in adjustments:
            axis, angle = adjustments[bone]
            matrix[:3,:3] = rotate(axis,angle) @ matrix[:3,:3]
        if breathing and bone == 1:
            matrix[:3,3] = matrix[:3,3] + np.array([0.0, bob * 3.0, 0.0])
        pose[bone] = matrix
    # Both hands grip the same shaft. Solve elbows instead of translating the
    # weapon independently of the arms (which left the hands visibly frozen).
    grip_arm(pose, 15, 17, 19, np.array([-6., grip_height, 22. + reach]), 1.)
    grip_arm(pose, 16, 18, 20, np.array([-6., grip_height, -6. + reach]), -1.)
    if args.kind == 'archer':
        draw = (min((frame-9)/12/.6, 1.) if (frame-9)/12 < .7 else max(0., (1.-(frame-9)/12)/.3)) if fighting else .15
        grip_arm(pose, 15, 17, 19, np.array([-6., 125., 30.]), 1.)
        grip_arm(pose, 16, 18, 20, np.array([-6., 125., 30.-draw*30.]), -1.)
    for bone in (21, 22):
        pose[bone] = pose[parents[bone]] @ locals[bone]
    pose[22][:3, :3] = rotate('y', math.pi / 2) @ bind[22][:3, :3]
    pose[22][:3, 3] = np.array([-6., grip_height, 2. + reach])
    for bone in pose:
        transforms[bone] = pose[bone] @ inverse[bone]
    moved, moved_normals = [], []
    for vertex, normal, links in zip(vertices,normals,weights):
        matrix = sum((transforms[bone] * weight for bone, weight in links), np.zeros((4,4)))
        # The skeleton already stands chest-toward +Z; map headings use +Z, so no
        # extra yaw is applied (rotating here used to point the body backwards).
        facing = np.eye(3)
        moved.append(facing @ (matrix @ np.append(vertex,1))[:3] * 0.01)
        direction = facing @ matrix[:3,:3] @ normal
        moved_normals.append(direction / max(np.linalg.norm(direction),1e-8))
    assert np.isfinite(moved).all(), 'Invalid posed vertex'
    if args.kind == 'infantry':
        assert np.asarray(moved)[:,2].max() > 1.4, 'Spear must point along normalized +Z forward'
    else:
        # Project-authored bow and moving string, sharing the native body atlas.
        bow_uv = []
        def segment(a, b, width):
            a, b = np.array(a), np.array(b)
            axis = (b-a)/np.linalg.norm(b-a)
            side = np.array([1.,0.,0.]); side -= axis*(axis@side);side /= np.linalg.norm(side)
            other = np.cross(axis,side)
            for i in range(6):
                n1 = side*math.cos(i*math.tau/6)+other*math.sin(i*math.tau/6)
                n2 = side*math.cos((i+1)*math.tau/6)+other*math.sin((i+1)*math.tau/6)
                for point,normal,u,v in [(a+n1*width,n1,0,0),(b+n1*width,n1,0,1),(b+n2*width,n2,1,1),(a+n1*width,n1,0,0),(b+n2*width,n2,1,1),(a+n2*width,n2,1,0)]:
                    moved.append(point*.01); moved_normals.append(normal)
                    bow_uv.append([.55+u*.38,.08+v*.30])
        bow = [np.array([-6., 125.+56.*t, 30.+14.*(t*t)-4.*math.sin(t*math.pi)]) for t in np.linspace(-1.,1.,17)]
        for a,b in zip(bow,bow[1:]): segment(a,b,1.8)
        pull = np.array([-6.,125.,30.-draw*30.])
        segment(bow[0],pull,.35); segment(pull,bow[-1],.35)
        if frame == 0:
            from PIL import Image
            texture = Image.open(ROOT/'assets/armies/rtk14/textures/24b4dfb4.png').convert('RGB')
            wood = Image.open(ROOT/'assets/armies/rtk14/textures/74da3a1d.png').convert('RGB')
            atlas = Image.new('RGB',(1024,512)); atlas.paste(texture.resize((512,512)),(0,0));atlas.paste(wood,(512,0))
            atlas.save(ROOT/'assets/armies/rtk14/textures/archer-atlas.png')
            archer_uv = [[u*.5,v] for u,v in uv] + bow_uv
            uv_id = add(archer_uv,'VEC2')
            color_id = add(colors + [[1.,1.,1.,1.]]*len(bow_uv),'VEC4')
    pos_id = add(moved,'VEC3'); normal_id = add(moved_normals,'VEC3')
    name = 'idle' if frame == 0 else (f'idle_{frame-21}' if breathing else (f'combat_{frame-9}' if fighting else f'march_{frame-1}'))
    attributes = {'POSITION':pos_id,'NORMAL':normal_id,'TEXCOORD_0':uv_id}
    if color_id is not None: attributes['COLOR_0'] = color_id
    meshes.append({'name':name, 'primitives':[{'attributes':attributes,'material':0}]})
gltf = {'asset':{'version':'2.0','generator':'RTK14 native weights; procedural infantry poses'},
        'scene':0,'scenes':[{'nodes':[0]}], 'nodes':[{'mesh':0,'name':'infantry_idle'}],
        'meshes':meshes,'materials':[{'name':'native_infantry','doubleSided':True,
        'pbrMetallicRoughness':{'baseColorTexture':{'index':0},'metallicFactor':0,'roughnessFactor':0.9}}],
        'images':[{'uri':'../textures/24b4dfb4.png'}],'textures':[{'source':0}],
        'bufferViews':views,'accessors':accessors,'buffers':[{'byteLength':len(binary)}],
        'extras':{'source_model':'d3c18f06','native_bones':len(bind),'animation':'procedural_baked_8_frame_idle_8_frame_march_12_frame_spear_thrust', 'forward_axis':'+Z'}}
# Add nodes so Godot can generate every mesh, without displaying them all together.
gltf['nodes'] += [{'mesh':i,'name':meshes[i]['name']} for i in range(1,len(meshes))]
gltf['scenes'][0]['nodes'] = list(range(len(meshes)))
if args.kind == 'archer':
    gltf['images'][0]['uri'] = '../textures/archer-atlas.png'
    gltf['extras']['animation'] = 'project-authored draw release and recovery; native infantry body'
raw = json.dumps(gltf,separators=(',',':')).encode(); raw += b' ' * (-len(raw)%4)
binary.extend(b'\0' * (-len(binary)%4))
out = ROOT / f'assets/armies/rtk14/models/{args.kind}-poses.glb'
out.write_bytes(struct.pack('<III',1179937895,2,12+8+len(raw)+8+len(binary)) + struct.pack('<II',len(raw),1313821514) + raw + struct.pack('<II',len(binary),5130562) + binary)
print(f'INFANTRY_POSES {len(bind)} native bones; idle + 8 idle-breath + 8 march + 12 combat frames; {len(vertices)//3} triangles per frame')
